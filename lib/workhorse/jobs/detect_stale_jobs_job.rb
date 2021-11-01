module Workhorse::Jobs
  # This job picks up jobs that remained `locked` or `started` (running) for
  # more than a certain amount of time. If any of these jobs are found, an
  # exception is thrown (which may cause a notification if you configured
  # `on_exception` accordingly).
  #
  # The thresholds are obtained from the configuration options
  # {Workhorse.stale_detection_locked_to_started_threshold
  # config.stale_detection_locked_to_started_threshold} and
  # {Workhorse.stale_detection_run_time_threshold
  # config.stale_detection_run_time_threshold}.
  class DetectStaleJobsJob
    # @private
    def initialize
      @locked_to_started_threshold = Workhorse.stale_detection_locked_to_started_threshold
      @run_time_threshold          = Workhorse.stale_detection_run_time_threshold
    end

    # @private
    def perform
      messages = []

      # Detect jobs that are locked for too long #
      if @locked_to_started_threshold != 0
        rel = Workhorse::DbJob.locked
        rel = rel.where('locked_at < ?', @locked_to_started_threshold.seconds.ago)
        ids = rel.pluck(:id)

        unless ids.empty?
          messages << "Detected #{ids.size} jobs that were locked more than "\
                      "#{@locked_to_started_threshold}s ago and might be stale: #{ids.inspect}."
        end
      end

      # Detect jobs that are running for too long #
      if @run_time_threshold != 0
        rel = Workhorse::DbJob.started
        rel = rel.where('started_at < ?', @run_time_threshold.seconds.ago)
        ids = rel.pluck(:id)

        unless ids.empty?
          messages << "Detected #{ids.size} jobs that are running for longer than "\
                      "#{@run_time_threshold}s ago and might be stale: #{ids.inspect}."
        end
      end

      if messages.any?
        fail messages.join(' ')
      end
    end
  end
end
