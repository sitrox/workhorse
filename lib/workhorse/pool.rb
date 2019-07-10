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
      @on_idle = nil
    end

    def on_idle(&block)
      @on_idle = block
    end

    # Posts a new work unit to the pool.
    def post
      mutex.synchronize do
        if idle.zero?
          fail 'All threads are busy.'
        end

        active_threads = @active_threads

        active_threads.increment

        @executor.post do
          begin
            yield
          ensure
            active_threads.decrement
            @on_idle.try(:call)
          end
        end
      end
    end

    # Returns the number of idle threads.
    def idle
      @size - @active_threads.value
    end

    def wait
      @executor.wait_for_termination
    end

    # Shuts down the pool and waits for termination.
    def shutdown
      @executor.shutdown
      wait
    end
  end
end
