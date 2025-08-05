module Workhorse
  # Thread pool abstraction used by workers for concurrent job execution.
  # Wraps Concurrent::ThreadPoolExecutor to provide a simpler interface
  # and custom behavior for job processing.
  #
  # @example Basic usage
  #   pool = Workhorse::Pool.new(4)
  #   pool.post { puts "Working..." }
  #   pool.shutdown
  class Pool
    # @return [Mutex] Synchronization mutex for thread safety
    attr_reader :mutex
    
    # @return [Concurrent::AtomicFixnum] Thread-safe counter of active threads
    attr_reader :active_threads

    # Creates a new thread pool with the specified size.
    #
    # @param size [Integer] Maximum number of threads in the pool
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

    # Sets a callback to be executed when the pool becomes idle.
    #
    # @yield Block to execute when all threads become idle
    # @return [void]
    def on_idle(&block)
      @on_idle = block
    end

    # Posts a new work unit to the pool for execution.
    #
    # @yield The work block to execute
    # @return [void]
    # @raise [RuntimeError] If all threads are busy
    def post
      mutex.synchronize do
        if idle.zero?
          fail 'All threads are busy.'
        end

        active_threads = @active_threads

        active_threads.increment

        @executor.post do
          begin # rubocop:disable Style/RedundantBegin
            yield
          ensure
            active_threads.decrement
            @on_idle.try(:call)
          end
        end
      end
    end

    # Returns the number of idle threads in the pool.
    #
    # @return [Integer] Number of idle threads
    def idle
      @size - @active_threads.value
    end

    # Waits until the pool is shut down. This will wait forever unless you
    # eventually call {#shutdown} (either before calling `wait` or after it in
    # another thread).
    #
    # @return [void]
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
    # All currently executing jobs will complete before shutdown.
    #
    # @return [void]
    def shutdown
      @executor.shutdown
      wait
    end
  end
end
