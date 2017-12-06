module Workhorse
  class Worker
    attr_reader :queues
    attr_reader :state
    attr_reader :pool_size
    attr_reader :polling_interval
    attr_reader :mutex

    def initialize(queues: [], pool_size: nil, polling_interval: 5, auto_terminate: true)
      @queues = queues
      @pool_size = pool_size || queues.size + 1
      @polling_interval = polling_interval
      @auto_terminate = auto_terminate
      @state = :initialized

      @mutex = Mutex.new
      @pool = Concurrent::ThreadPoolExecutor.new(
        min_threads: 0,
        max_threads: @pool_size,
        max_queue: 1, # TODO: 0 does not seem to work for some reason
        fallback_policy: :abort,
        auto_terminate: false
      )
      @poller = Workhorse::Poller.new(self)
    end

    def id
      @id ||= "#{Socket.gethostname}.#{Process.pid}.#{SecureRandom.hex(3)}"
    end

    def start
      mutex.synchronize do
        assert_state! :initialized
        @state = :running
        @poller.start

        trap_termination if @auto_terminate
      end
    end

    def assert_state!(state)
      fail "Expected worker to be in state #{state} but current state is #{self.state}." unless self.state == state
    end

    def shutdown
      mutex.synchronize do
        assert_state! :running
        @state = :shutdown

        @poller.shutdown
        @pool.shutdown
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

        @pool.post do
          Workhorse::Performer.new(db_job).perform
        end
      end
    end

    private

    def trap_termination
      Signal.trap('TERM') do
        puts "\nCaught TERM, shutting worker down..."
        shutdown
      end

      Signal.trap('INT') do
        puts "\nCaught INT, shutting worker down..."
        shutdown
      end
    end
  end
end
