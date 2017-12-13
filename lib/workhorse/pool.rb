module Workhorse
  # Abstraction layer of a simple thread pool implementation used by the worker.
  class Pool
    attr_reader :mutex

    def initialize(size)
      @size = size
      @executor = Concurrent::ThreadPoolExecutor.new(
        min_threads: 0,
        max_threads: @size,
        max_queue: 0,
        fallback_policy: :abort,
        auto_terminate: false
      )
      @mutex = Mutex.new
      @active_threads = Concurrent::AtomicFixnum.new(0)
    end

    # Posts a new work unit to the pool.
    def post(&block)
      mutex.synchronize do
        if @active_threads.value >= @size
          fail 'All threads are busy.'
        end

        active_threads = @active_threads

        active_threads.increment

        @executor.post do
          begin
            block.call
          ensure
            active_threads.decrement
          end
        end
      end
    end

    # Returns the number of idle threads.
    def idle
      @size - @active_threads.value
    end

    # Shuts down the pool
    def shutdown
      @executor.shutdown
      @executor.wait_for_termination
    end
  end
end
