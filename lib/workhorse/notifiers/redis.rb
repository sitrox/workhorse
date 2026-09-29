module Workhorse
  module Notifiers
    # Notifier that announces an enqueued job over a Redis pub/sub channel,
    # for deployments whose workers do not share a filesystem with the
    # application.
    #
    # Redis is a soft dependency: it is not declared in the gemspec and is only
    # required when this notifier is selected. Configure the client and,
    # optionally, the channel:
    #
    # ```ruby
    # Workhorse.setup do |config|
    #   config.notifier = :redis
    #   config.notification_redis = Redis.new(url: ENV['REDIS_URL'])
    # end
    # ```
    #
    # A subscriber thread per worker process keeps a counter, which pollers
    # read through {#token}. Delivery is best-effort in both directions: a
    # publish that fails and a subscription that drops both cost latency only,
    # as polling still picks the job up.
    class Redis < Base
      # Default channel jobs are announced on.
      DEFAULT_CHANNEL = 'workhorse:jobs'.freeze

      # Seconds to wait before subscribing again after a failure.
      RECONNECT_DELAY = 1

      # @param client [Object, nil] Redis client. Defaults to
      #   {Workhorse.notification_redis}.
      # @param channel [String, nil] Channel to use. Defaults to
      #   {Workhorse.notification_channel} or {DEFAULT_CHANNEL}.
      def initialize(client: nil, channel: nil)
        super()
        @configured_client = client
        @channel = channel
        @counter = Concurrent::AtomicFixnum.new(0)
        @subscribers = 0
        @mutex = Mutex.new
      end

      # Resolved when used rather than when constructed, so that
      # {Workhorse.notification_channel} can be set in any order relative to
      # {Workhorse.notifier=} - up to the point a worker starts, as the
      # subscriber thread captures the channel it was started with.
      #
      # @return [String] Channel that is published to and subscribed on
      def channel
        return @channel || Workhorse.notification_channel || DEFAULT_CHANNEL
      end

      # @return [Object] The configured Redis client
      # @raise [RuntimeError] If no client has been configured
      def client
        return @client if @client

        # Built under the mutex: #notify runs on every enqueueing thread, and
        # two of them racing here would each build one and orphan the loser.
        @mutex.synchronize { @client ||= build_client }

        return @client
      end

      # Returns the configured source of clients: either a client, or a
      # callable returning one.
      #
      # @return [Object]
      # @raise [RuntimeError] If nothing has been configured
      # @private
      def client_source
        return @configured_client || Workhorse.notification_redis \
          || fail('Workhorse.notification_redis must be set to a Redis client, or to something ' \
                  'callable returning one, to use the :redis notifier.')
      end

      # Publishes the queue name on the configured channel.
      #
      # @param queue [String, Symbol, nil] Queue the job was enqueued into
      # @return [void]
      def notify(queue: nil)
        client.publish(channel, queue.to_s)
      rescue StandardError => e
        # Best-effort by contract, see Workhorse::Notifiers::Base#notify.
        Workhorse.debug_log("Notification failed: #{e.class}: #{e.message}")
      end

      # Starts the subscriber thread, unless one is already running for this
      # process.
      #
      # @return [void]
      def start
        @mutex.synchronize do
          @subscribers += 1
          @thread = start_subscriber unless @thread&.alive?
        end

        return
      end

      # Stops the subscriber thread once the last worker in this process has
      # stopped.
      #
      # @return [void]
      def stop
        @mutex.synchronize do
          @subscribers -= 1 if @subscribers > 0
          next unless @subscribers.zero?

          @thread&.kill
          @thread = nil
          @subscriber_failed = false
        end

        return
      end

      # @return [Integer] Number of notifications received in this process
      def token
        return @counter.value
      end

      private

      # Subscribes on a thread of its own, reconnecting after a dropped
      # connection.
      #
      # @return [Thread]
      def start_subscriber
        counter = @counter
        chan = channel

        return Thread.new do
          client = nil

          loop do
            # Kept across iterations and replaced only once the connection it
            # holds has failed, so an outage does not build one client per
            # second and drop each unclosed.
            client ||= subscriber_client

            client.subscribe(chan) do |on|
              on.message { |_channel, _message| counter.increment }
            end

            @subscriber_failed = false
          rescue StandardError => e
            report_subscriber_failure(e)
            client = close(client)
            Kernel.sleep RECONNECT_DELAY
          end
        end
      end

      # Reports a failed subscription. Retrying is silent after the first
      # report: a broker that is down produces one of these per
      # {RECONNECT_DELAY}, and a misconfigured notifier would otherwise retry
      # forever without anyone hearing about it.
      #
      # @param exception [Exception]
      # @return [void]
      def report_subscriber_failure(exception)
        message = "Notification subscriber failed: #{exception.class}: #{exception.message}"
        Workhorse.debug_log(message)

        return if @subscriber_failed

        @subscriber_failed = true

        begin
          Workhorse.on_exception.call(exception)
        rescue Exception => e
          # A reporter that is itself unreachable must not unwind the retry
          # loop and leave the process without a subscriber for good.
          Workhorse.debug_log("on_exception failed: #{e.class}: #{e.message}")
        end

        return
      end

      # Closes a client, tolerating one that cannot be closed.
      #
      # @param client [Object, nil]
      # @return [nil]
      def close(client)
        client.close if client.respond_to?(:close)

        return nil
      rescue StandardError => e
        Workhorse.debug_log("Closing the subscriber client failed: #{e.class}: #{e.message}")

        return nil
      end

      # @return [Object] A newly built client
      def build_client
        source = client_source

        return source.respond_to?(:call) ? source.call : source
      end

      # Returns the client to subscribe with. A subscribed connection cannot
      # be used for anything else, so this must not be the client that
      # {#notify} publishes on.
      #
      # Configure {Workhorse.notification_redis} with something callable to
      # get a connection of its own here. Given a client instead, this falls
      # back to `dup`, which in redis-rb is a shallow copy that may share the
      # underlying connection.
      #
      # @return [Object]
      def subscriber_client
        source = client_source

        return source.respond_to?(:call) ? source.call : source.dup
      end
    end
  end
end
