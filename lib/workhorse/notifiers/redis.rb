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

      # @return [String] Channel that is published to and subscribed on
      attr_reader :channel

      # @param client [Object, nil] Redis client. Defaults to
      #   {Workhorse.notification_redis}.
      # @param channel [String, nil] Channel to use. Defaults to
      #   {Workhorse.notification_channel} or {DEFAULT_CHANNEL}.
      def initialize(client: nil, channel: nil)
        super()
        @client = client
        @channel = channel || Workhorse.notification_channel || DEFAULT_CHANNEL
        @counter = Concurrent::AtomicFixnum.new(0)
        @subscribers = 0
        @mutex = Mutex.new
      end

      # @return [Object] The configured Redis client
      # @raise [RuntimeError] If no client has been configured
      def client
        @client ||= Workhorse.notification_redis \
          || fail('Workhorse.notification_redis must be set to a Redis client to use the :redis notifier.')
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
          @thread ||= start_subscriber
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
        end

        return
      end

      # @return [Integer] Number of notifications received in this process
      def token
        return @counter.value
      end

      private

      # Subscribes on a thread of its own, reconnecting after a dropped
      # connection. Uses a separate client, as a subscribed connection cannot
      # be used for anything else.
      #
      # @return [Thread]
      def start_subscriber
        counter = @counter
        chan = channel

        return Thread.new do
          loop do
            subscriber_client.subscribe(chan) do |on|
              on.message { |_channel, _message| counter.increment }
            end
          rescue StandardError => e
            Workhorse.debug_log("Notification subscriber failed: #{e.class}: #{e.message}")
            Kernel.sleep 1
          end
        end
      end

      # @return [Object] A client of its own for the subscription
      def subscriber_client
        return client.dup
      end
    end
  end
end
