module Workhorse
  # Abstraction layer of a simple thread pool implementation used by the worker.
  class Pool
    attr_reader :mutex

    def initialize(size)
      @size = size
      @executor = Concurrent::ThreadPoolExecutor.new(
        min_threads:     0,
        max_threads:     @size,
        max_queue:       0,
        fallback_policy: :abort,
        auto_terminate:  false
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
          yield
        ensure
          active_threads.decrement
          @on_idle.try(:call)
        end
      end
    end

    # Returns the number of idle threads.
    def idle
      @size - @active_threads.value
    end

    # Waits until the pool is shut down. This will wait forever unless you
    # eventually call shutdown (either before calling `wait` or after it in
    # another thread).
    def wait
      # Here we use a loop-sleep combination instead of using
      # ThreadPoolExecutor's `wait_for_termination`. See issue #21 for more
      # information.
      loop do
        break if @executor.shutdown?
        sleep 0.1
      end
    end

    # Shuts down the pool and waits for termination.
    def shutdown
      @executor.shutdown
      wait
    end
  end
end
