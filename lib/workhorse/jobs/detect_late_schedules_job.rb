module Workhorse::Jobs
  # Job that detects schedules nothing is materialising.
  #
  # This is the one check that can catch silence. {Workhorse.on_job_expired}
  # and {Workhorse.on_job_late} are precise but can only fire for a job that
  # exists; if no worker is polling, or the global lock is stuck, occurrences
  # stop being materialised altogether and no callback can report it. A
  # schedule whose `next_at` lies well in the past is the evidence of that.
  #
  # Schedule this regularly, the same way as
  # {Workhorse::Jobs::DetectStaleJobsJob}. Note that it is itself performed by
  # a worker, so it reports a stall only while at least one worker still runs
  # - use it alongside external monitoring, not instead of it.
  #
  # @example Schedule with the default threshold
  #   Workhorse.schedules do
  #     schedule 'detect_late_schedules',
  #              job:  'Workhorse::Jobs::DetectLateSchedulesJob',
  #              cron: '*/30 * * * *'
  #   end
  class DetectLateSchedulesJob
    # Creates a new late schedule detection job.
    #
    # @param threshold [Integer] Number of seconds a schedule's next
    #   occurrence may lie in the past before it is reported.
    # @param keys [Array<String>, nil] If given, only check these schedules.
    #   If `nil` (default), all of them are checked.
    def initialize(threshold: 15 * 60, keys: nil)
      @threshold = threshold
      @keys      = keys
    end

    # Executes the detection.
    #
    # @return [void]
    # @raise [RuntimeError] If schedules are found that are overdue
    def perform
      rel = Workhorse::Schedule.where(enabled: true)
      rel = rel.where(key: @keys) if @keys
      rel = rel.where(Workhorse::Schedule.arel_table[:next_at].lt(@threshold.seconds.ago))

      overdue = rel.pluck(:key, :next_at)

      return if overdue.empty?

      descriptions = overdue.map do |key, next_at|
        "#{key.inspect} (due #{next_at}, #{(Time.now - next_at).round}s ago)"
      end

      fail "The next occurrence of #{overdue.size} schedule(s) is more than #{@threshold}s in the past, " \
           'which means they are not being materialized. Check that at least one worker is polling and ' \
           "that the global lock is obtainable. Affected: #{descriptions.join(', ')}."
    end
  end
end
