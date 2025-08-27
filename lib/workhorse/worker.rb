module Workhorse
  class Worker
    LOG_LEVELS = %i[fatal error warn info debug].freeze
    SHUTDOWN_SIGNALS = %w[TERM INT].freeze
    LOG_REOPEN_SIGNAL = 'HUP'.freeze

    attr_reader :queues
    attr_reader :state
    attr_reader :pool_size
    attr_reader :polling_interval
    attr_reader :mutex
    attr_reader :logger
    attr_reader :poller

    # Instantiates and starts a new worker with the given arguments and then
    # waits for its completion (i.e. an interrupt).
    def self.start_and_wait(**args)
      worker = new(**args)
      worker.start
      worker.wait
    end

    # @private
    def self.shutdown_file_for(pid)
      return nil unless defined?(Rails)
      Rails.root.join('tmp', 'pids', "workhorse.#{pid}.shutdown")
    end

    # Instantiates a new worker. The worker is not automatically started.
    #
    # @param queues [Array] The queues you want this worker to process. If an
    #   empty array is given, any queues will be processed. Queues need to be
    #   specified as a symbol. To also process jobs without a queue, supply
    #   `nil` within the array.
    # @param pool_size [Integer] The number of jobs that will be processed
    #   simultaneously. If this parameter is not given, it will be set to the
    #   number of given queues + 1.
    # @param polling_interval [Integer] Interval in seconds the database will
    #   be polled for new jobs. Set this as high as possible to avoid
    #   unnecessary database load. Defaults to 5 minutes.
    # @param auto_terminate [Boolean] Whether to automatically shut down the
    #   worker properly on INT and TERM signals.
    # @param quiet [Boolean] If this is set to `false`, the worker will also log
    #   to STDOUT.
    # @param instant_repolling [Boolean] If this is set to `true`, the worker
    #   immediately re-polls for new jobs when a job execution has finished.
    # @param logger [Logger] An optional logger the worker will append to. This
    #   can be any instance of ruby's `Logger` but is commonly set to
    #   `Rails.logger`.
    def initialize(queues: [], pool_size: nil, polling_interval: 300, auto_terminate: true, quiet: true, instant_repolling: false, logger: nil)
      @queues = queues
      @pool_size = pool_size || (queues.size + 1)
      @polling_interval = polling_interval
      @auto_terminate = auto_terminate
      @state = :initialized
      @quiet = quiet

      @mutex = Mutex.new
      @pool = Pool.new(@pool_size)
      @poller = Workhorse::Poller.new(self, proc { check_memory })
      @logger = logger

      unless (@polling_interval / 0.1).round(2).modulo(1).zero?
        fail 'Polling interval must be a multiple of 0.1.'
      end

      if instant_repolling
        @pool.on_idle { @poller.instant_repoll! }
      end
    end

    def log(text, level = :info)
      text = "[Job worker #{id}] #{text}"
      puts text unless @quiet
      return unless logger
      fail "Log level #{level} is not available. Available are #{LOG_LEVELS.inspect}." unless LOG_LEVELS.include?(level)
      logger.send(level, text.strip)
    end

    def id
      @id ||= "#{hostname}.#{pid}.#{SecureRandom.hex(3)}"
    end

    def pid
      @pid ||= Process.pid
    end

    def hostname
      @hostname ||= Socket.gethostname
    end

    # Starts the worker. This call is not blocking - call {wait} for this
    # purpose.
    def start
      mutex.synchronize do
        assert_state! :initialized
        log 'Starting up'
        @state = :running
        @poller.start
        log 'Started up'

        trap_termination if @auto_terminate
        trap_log_reopen
      end
    end

    def assert_state!(state)
      fail "Expected worker to be in state #{state} but current state is #{self.state}." unless self.state == state
    end

    # Shuts down worker and DB poller. Jobs currently beeing processed are
    # properly finished before this method returns. Subsequent calls to this
    # method are ignored.
    def shutdown
      # This is safe to be checked outside of the mutex as 'shutdown' is the
      # final state this worker can be in.
      return if @state == :shutdown

      # TODO: There is a race-condition with this shutdown:
      #  - If the poller is currently locking a job, it may call
      #    "worker.perform", which in turn tries to synchronize the same mutex.
      mutex.synchronize do
        assert_state! :running

        log 'Shutting down'
        @state = :shutdown

        @poller.shutdown
        @pool.shutdown
        log 'Shut down'
      end
    end

    # Waits until the worker is shut down. This only happens if shutdown gets
    # called - either by another thread or by enabling `auto_terminate` and
    # receiving a respective signal. Use this method to let worker run
    # undefinitely.
    def wait
      @poller.wait
      @pool.wait
    end

    def idle
      @pool.idle
    end

    def perform(db_job_id)
      begin # rubocop:disable Style/RedundantBegin
        mutex.synchronize do
          assert_state! :running
          log "Posting job #{db_job_id} to thread pool"

          @pool.post do
            begin # rubocop:disable Style/RedundantBegin
              Workhorse::Performer.new(db_job_id, self).perform
            rescue Exception => e
              log %(#{e.message}\n#{e.backtrace.join("\n")}), :error
              Workhorse.on_exception.call(e)
            end
          end
        end
      rescue Exception => e
        Workhorse.on_exception.call(e)
      end
    end

    private

    def check_memory
      mem = current_memory_consumption

      unless mem
        log "Could not determine memory consumption of worker with pid #{pid}"
        return false
      end

      max = Workhorse.max_worker_memory_mb
      exceeded = max > 0 && current_memory_consumption > max

      return true unless exceeded

      if defined?(Rails)
        FileUtils.touch self.class.shutdown_file_for(pid)
      end

      log "Worker process #{id.inspect} memory consumption (RSS) of #{mem}MB exceeds "\
          "configured per-worker limit of #{max}MB and is now being shut down. Make sure "\
          'that your worker processes are watched (e.g. using the "watch"-command) for ' \
          'this worker to be restarted automatically.'

      return false
    end

    def current_memory_consumption
      mem = `ps -p #{pid} -o rss=`&.strip
      return nil if mem.blank?
      return mem.to_i / 1024
    end

    def trap_log_reopen
      Signal.trap(LOG_REOPEN_SIGNAL) do
        Thread.new do
          logger.reopen

          if defined?(ActiveRecord::Base) && ActiveRecord::Base.logger && ActiveRecord::Base.logger != logger
            ActiveRecord::Base.logger.reopen
          end
        end.join
      end
    end

    def trap_termination
      SHUTDOWN_SIGNALS.each do |signal|
        Signal.trap(signal) do
          # Start a new thread as certain functionality (such as logging) is not
          # available from within a trap context. As "shutdown" terminates
          # quickly when called multiple times, this does not pose a risk of
          # keeping open a big number of "shutdown threads".
          Thread.new do
            log "\nCaught #{signal}, shutting worker down..."
            shutdown
          end.join
        end
      end
    end
  end
end
