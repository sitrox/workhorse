module Workhorse::Jobs
  # Job that detects and reports stale jobs in the system.
  # This monitoring job picks up jobs that remained `locked` or `started` (running) for
  # more than a certain amount of time. If any of these jobs are found, an
  # exception is thrown (which may cause a notification if you configured
  # {Workhorse.on_exception} accordingly).
  #
  # The thresholds are obtained from the configuration options
  # {Workhorse.stale_detection_locked_to_started_threshold} and
  # {Workhorse.stale_detection_run_time_threshold}.
  #
  # @example Schedule stale job detection
  #   Workhorse.enqueue(DetectStaleJobsJob.new)
  #
  # @example Configure thresholds
  #   Workhorse.setup do |config|
  #     config.stale_detection_locked_to_started_threshold = 300  # 5 minutes
  #     config.stale_detection_run_time_threshold = 3600         # 1 hour
  #   end
  class DetectStaleJobsJob
    # Creates a new stale job detection job.
    # Reads configuration thresholds at initialization time.
    def initialize
      @locked_to_started_threshold = Workhorse.stale_detection_locked_to_started_threshold
      @run_time_threshold          = Workhorse.stale_detection_run_time_threshold
    end

    # Executes the stale job detection.
    # Checks for jobs that have been locked or running too long and raises
    # an exception if any are found.
    #
    # @return [void]
    # @raise [RuntimeError] If stale jobs are detected
    def perform
      messages = []

      # Detect jobs that are locked for too long #
      if @locked_to_started_threshold != 0
        rel = Workhorse::DbJob.locked
        rel = rel.where('locked_at < ?', @locked_to_started_threshold.seconds.ago)
        ids = rel.pluck(:id)

        unless ids.empty?
          messages << "Detected #{ids.size} jobs that were locked more than " \
                      "#{@locked_to_started_threshold}s ago and might be stale: #{ids.inspect}."
        end
      end

      # Detect jobs that are running for too long #
      if @run_time_threshold != 0
        rel = Workhorse::DbJob.started
        rel = rel.where('started_at < ?', @run_time_threshold.seconds.ago)
        ids = rel.pluck(:id)

        unless ids.empty?
          messages << "Detected #{ids.size} jobs that are running for longer than " \
                      "#{@run_time_threshold}s ago and might be stale: #{ids.inspect}."
        end
      end

      if messages.any?
        fail messages.join(' ')
      end
    end
  end
end
