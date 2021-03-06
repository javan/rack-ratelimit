require 'logger'
require 'time'

module Rack
  # = Ratelimit
  #
  # * Run multiple rate limiters in a single app
  # * Scope each rate limit to certain requests: API, files, GET vs POST, etc.
  # * Apply each rate limit by request characteristics: IP, subdomain, OAuth2 token, etc.
  # * Flexible time window to limit burst traffic vs hourly or daily traffic:
  #     100 requests per 10 sec, 500 req/minute, 10000 req/hour, etc.
  # * Fast, low-overhead implementation using counters per time window:
  #     timeslice = window * ceiling(current time / window)
  #     store.incr(timeslice)
  class Ratelimit
    # Takes a block that classifies requests for rate limiting. Given a
    # Rack env, return a string such as IP address, API token, etc. If the
    # block returns nil, the request won't be rate-limited. If a block is
    # not given, all requests get the same limits.
    #
    # Required configuration:
    #   rate: an array of [max requests, period in seconds]: [500, 5.minutes]
    # and one of
    #   cache: a Dalli::Client instance
    #   redis: a Redis instance
    #   counter: Your own custom counter. Must respond to
    #     `#increment(classification_string, end_of_time_window_timestamp)`
    #     and return the counter value after increment.
    #
    # Optional configuration:
    #   name: name of the rate limiter. Defaults to 'HTTP'. Used in messages.
    #   status: HTTP response code. Defaults to 429.
    #   conditions: array of procs that take a rack env, all of which must
    #     return true to rate-limit the request.
    #   exceptions: array of procs that take a rack env, any of which may
    #     return true to exclude the request from rate limiting.
    #   logger: responds to #info(message). If provided, the rate limiter
    #     logs the first request that hits the rate limit, but none of the
    #     subsequently blocked requests.
    #   error_message: the message returned in the response body when the rate
    #     limit is exceeded. Defaults to "<name> rate limit exceeded. Please
    #     wait <period> seconds then retry your request."
    #
    # Example:
    #
    # Rate-limit bursts of POST/PUT/DELETE by IP address, return 503:
    #   use(Rack::Ratelimit, name: 'POST',
    #     exceptions: ->(env) { env['REQUEST_METHOD'] == 'GET' },
    #     rate:   [50, 10.seconds],
    #     status: 503,
    #     cache:  Dalli::Client.new,
    #     logger: Rails.logger) { |env| Rack::Request.new(env).ip }
    #
    # Rate-limit API traffic by user (set by Rack::Auth::Basic):
    #   use(Rack::Ratelimit, name: 'API',
    #     conditions: ->(env) { env['REMOTE_USER'] },
    #     rate:   [1000, 1.hour],
    #     redis:  Redis.new(ratelimit_redis_config),
    #     logger: Rails.logger) { |env| env['REMOTE_USER'] }
    def initialize(app, options, &classifier)
      @app, @classifier = app, classifier
      @classifier ||= lambda { |env| :request }

      @name = options.fetch(:name, 'HTTP')
      @max, @period = options.fetch(:rate)
      @status = options.fetch(:status, 429)

      @counter =
        if counter = options[:counter]
          raise ArgumentError, 'Counter must respond to #increment' unless counter.respond_to?(:increment)
          counter
        elsif cache = options[:cache]
          MemcachedCounter.new(cache, @name, @period)
        elsif redis = options[:redis]
          RedisCounter.new(redis, @name, @period)
        else
          raise ArgumentError, ':cache, :redis, or :counter is required'
        end

      @logger = options[:logger]
      @error_message = options.fetch(:error_message, "#{@name} rate limit exceeded. Please wait #{@period} seconds then retry your request.")

      @conditions = Array(options[:conditions])
      @exceptions = Array(options[:exceptions])
    end

    # Add a condition that must be met before applying the rate limit.
    # Pass a block or a proc argument that takes a Rack env and returns
    # true if the request should be limited.
    def condition(predicate = nil, &block)
      @conditions << predicate if predicate
      @conditions << block if block_given?
    end

    # Add an exception that excludes requests from the rate limit.
    # Pass a block or a proc argument that takes a Rack env and returns
    # true if the request should be excluded from rate limiting.
    def exception(predicate = nil, &block)
      @exceptions << predicate if predicate
      @exceptions << block if block_given?
    end

    # Apply the rate limiter if none of the exceptions apply and all the
    # conditions are met.
    def apply_rate_limit?(env)
      @exceptions.none? { |e| e.call(env) } && @conditions.all? { |c| c.call(env) }
    end

    # Give subclasses an opportunity to specialize classification.
    def classify(env)
      @classifier.call env
    end

    # Handle a Rack request:
    #   * Check whether the rate limit applies to the request.
    #   * Classify the request by IP, API token, etc.
    #   * Calculate the end of the current time window.
    #   * Increment the counter for this classification and time window.
    #   * If count exceeds limit, return a 429 response.
    #   * If it's the first request that exceeds the limit, log it.
    #   * If the count doesn't exceed the limit, pass through the request.
    def call(env)
      if apply_rate_limit?(env) && classification = classify(env)

        # Marks the end of the current rate-limiting window.
        timestamp = @period * (Time.now.to_f / @period).ceil
        time = Time.at(timestamp).utc.xmlschema

        # Increment the request counter.
        count = @counter.increment(classification, timestamp)
        remaining = @max - count + 1

        json = %({"name":"#{@name}","period":#{@period},"limit":#{@max},"remaining":#{remaining},"until":"#{time}"})

        # If exceeded, return a 429 Rate Limit Exceeded response.
        if remaining <= 0
          # Only log the first hit that exceeds the limit.
          if @logger && remaining == 0
            @logger.info '%s: %s exceeded %d request limit for %s' % [@name, classification, @max, time]
          end

          [ @status,
            { 'X-Ratelimit' => json, 'Retry-After' => @period.to_s },
            [@error_message] ]

        # Otherwise, pass through then add some informational headers.
        else
          @app.call(env).tap do |status, headers, body|
            headers['X-Ratelimit'] = [headers['X-Ratelimit'], json].compact.join("\n")
          end
        end
      else
        @app.call(env)
      end
    end

    class MemcachedCounter
      def initialize(cache, name, period)
        @cache, @name, @period = cache, name, period
      end

      # Increment the request counter and return the current count.
      def increment(classification, timestamp)
        key = 'rack-ratelimit/%s/%s/%i' % [@name, classification, timestamp]

        # Try to increment the counter if it's present.
        if count = @cache.incr(key, 1)
          count.to_i

        # If not, add the counter and set expiry.
        elsif @cache.add(key, 1, @period, :raw => true)
          1

        # If adding failed, someone else added it concurrently. Increment.
        else
          @cache.incr(key, 1).to_i
        end
      end
    end

    class RedisCounter
      def initialize(redis, name, period)
        @redis, @name, @period = redis, name, period
      end

      # Increment the request counter and return the current count.
      def increment(classification, timestamp)
        key = 'rack-ratelimit/%s/%s/%i' % [@name, classification, timestamp]

        # Returns [count, expire_ok] response for each multi command.
        # Return the first, the count.
        @redis.multi do |redis|
          redis.incr key
          redis.expire key, @period
        end.first
      end
    end
  end
end
