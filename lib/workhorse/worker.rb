module Workhorse
  class Worker
    LOG_LEVELS = %i[fatal error warn info debug].freeze
    SHUTDOWN_SIGNALS = %w[TERM INT].freeze

    attr_reader :queues
    attr_reader :state
    attr_reader :pool_size
    attr_reader :polling_interval
    attr_reader :mutex
    attr_accessor :logger

    def initialize(queues: [], pool_size: nil, polling_interval: 5, auto_terminate: true, quiet: true)
      @queues = queues
      @pool_size = pool_size || queues.size + 1
      @polling_interval = polling_interval
      @auto_terminate = auto_terminate
      @state = :initialized
      @quiet = quiet

      @mutex = Mutex.new
      @pool = Concurrent::ThreadPoolExecutor.new(
        min_threads: 0,
        max_threads: @pool_size,
        max_queue: 1, # TODO: 0 does not seem to work for some reason
        fallback_policy: :abort,
        auto_terminate: false
      )
      @poller = Workhorse::Poller.new(self)
      @logger = nil
    end

    def log(text, level = :info)
      text = "[Job worker #{id}] #{text}"
      puts text unless @quiet
      return unless logger
      fail "Log level #{level} is not available. Available are #{LOG_LEVELS.inspect}." unless LOG_LEVELS.include?(level)
      logger.send(level, text.strip)
    end

    def id
      @id ||= "#{Socket.gethostname}.#{Process.pid}.#{SecureRandom.hex(3)}"
    end

    def start
      mutex.synchronize do
        assert_state! :initialized
        log 'Starting up'
        @state = :running
        @poller.start
        log 'Started up'

        trap_termination if @auto_terminate
      end
    end

    def assert_state!(state)
      fail "Expected worker to be in state #{state} but current state is #{self.state}." unless self.state == state
    end

    # Shuts down worker and DB poller. Jobs currently beeing processed are
    # properly finished before this method returns. Subsequent calls to this
    # method are ignored.
    def shutdown
      mutex.synchronize do
        return if @state == :shutdown
        assert_state! :running
        log 'Shutting down'
        @state = :shutdown

        @poller.shutdown
        @pool.shutdown
        log 'Shut down'
      end
    end

    def wait
      @poller.wait
    end

    def remaining_capacity
      @pool.remaining_capacity
    end

    def perform(db_job)
      mutex.synchronize do
        assert_state! :running
        log "Posting job #{db_job.id} to thread pool"

        @pool.post do
          begin
            Workhorse::Performer.new(db_job, self).perform
          rescue => e
            log %(#{e.message}\n#{e.backtrace.join("\n")}), :error
          end
        end
      end
    end

    private

    def trap_termination
      SHUTDOWN_SIGNALS.each do |signal|
        Signal.trap(signal) do
          log "\nCaught #{signal}, shutting worker down..."
          Thread.new do
            shutdown
          end
        end
      end
    end
  end
end
