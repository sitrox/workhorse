require 'test_helper'

class Workhorse::ScheduleTest < WorkhorseTest
  def setup
    super
    Workhorse::Schedules.reset!
    Workhorse::Schedule.delete_all
    @on_job_expired = Workhorse.on_job_expired
    @on_job_late = Workhorse.on_job_late
  end

  def teardown
    Workhorse::Schedules.reset!
    Workhorse::Schedule.delete_all
    Workhorse.on_job_expired = @on_job_expired
    Workhorse.on_job_late = @on_job_late
  end

  # ---------------------------------------------------------------
  # Registry
  # ---------------------------------------------------------------

  def test_registering_a_schedule
    define_schedule 'cleanup', cron: '10 0 * * *'

    definition = Workhorse::Schedules['cleanup']

    assert_equal 'cleanup', definition.key
    assert_equal 'BasicJob', definition.job
    assert_equal :run_once, definition.catch_up
  end

  def test_duplicate_keys_are_rejected
    define_schedule 'cleanup', cron: '10 0 * * *'

    assert_raises ArgumentError do
      define_schedule 'cleanup', cron: '20 0 * * *'
    end
  end

  def test_invalid_cron_is_rejected
    error = assert_raises ArgumentError do
      define_schedule 'broken', cron: 'not a cron'
    end

    assert_match(/not a valid cron expression/, error.message)
  end

  def test_invalid_catch_up_policy_is_rejected
    assert_raises ArgumentError do
      define_schedule 'broken', cron: '* * * * *', catch_up: :whenever
    end
  end

  # Without a grace period, :skip cannot tell an occurrence that is a moment
  # late from one that is a day late and would drop every one of them.
  def test_skip_without_grace_is_rejected
    error = assert_raises ArgumentError do
      define_schedule 'digest', cron: '0 8 * * *', catch_up: :skip
    end

    assert_match(/requires a grace period/, error.message)
  end

  # ---------------------------------------------------------------
  # Reconciliation
  # ---------------------------------------------------------------

  def test_reconcile_inserts_without_firing_immediately
    now = Time.new(2026, 9, 28, 10, 0, 0)
    define_schedule 'nightly', cron: '0 3 * * *'

    Workhorse::Schedule.reconcile!(now)

    schedule = Workhorse::Schedule.sole

    assert_equal 'nightly', schedule.key
    assert_operator schedule.next_at, :>, now
    assert_empty Workhorse::Schedule.due(now)
  end

  def test_reconcile_recomputes_when_the_cron_changes
    now = Time.new(2026, 9, 28, 10, 0, 0)
    define_schedule 'nightly', cron: '0 3 * * *'
    Workhorse::Schedule.reconcile!(now)
    before = Workhorse::Schedule.sole.next_at

    Workhorse::Schedules.reset!
    define_schedule 'nightly', cron: '0 4 * * *'
    Workhorse::Schedule.reconcile!(now)

    schedule = Workhorse::Schedule.sole

    assert_equal '0 4 * * *', schedule.cron
    refute_equal before, schedule.next_at
  end

  def test_reconcile_recomputes_when_the_timezone_changes
    now = Time.new(2026, 9, 28, 10, 0, 0)
    define_schedule 'nightly', cron: '0 3 * * *'
    Workhorse::Schedule.reconcile!(now)
    before = Workhorse::Schedule.sole.next_at

    Workhorse::Schedules.reset!
    define_schedule 'nightly', cron: '0 3 * * *', timezone: 'Asia/Tokyo'
    Workhorse::Schedule.reconcile!(now)

    schedule = Workhorse::Schedule.sole

    assert_equal 'Asia/Tokyo', schedule.timezone
    refute_equal before, schedule.next_at
  end

  # Reconciliation must not push an unchanged schedule's occurrence forward,
  # or restarting workers often enough would keep it from ever being due.
  def test_reconcile_leaves_an_unchanged_schedule_alone
    now = Time.new(2026, 9, 28, 10, 0, 0)
    define_schedule 'nightly', cron: '0 3 * * *'
    Workhorse::Schedule.reconcile!(now)
    before = Workhorse::Schedule.sole.next_at

    Workhorse::Schedule.reconcile!(now + 3600)

    assert_equal before, Workhorse::Schedule.sole.next_at
  end

  # Removal is deliberately not immediate, see
  # test_reconcile_keeps_a_schedule_another_version_still_declares.
  def test_reconcile_keeps_a_schedule_that_was_just_removed
    define_schedule 'a', cron: '0 3 * * *'
    define_schedule 'b', cron: '0 4 * * *'
    Workhorse::Schedule.reconcile!

    assert_equal %w[a b], Workhorse::Schedule.order(:key).pluck(:key)

    Workhorse::Schedules.reset!
    define_schedule 'a', cron: '0 3 * * *'
    Workhorse::Schedule.reconcile!

    assert_equal %w[a b], Workhorse::Schedule.order(:key).pluck(:key)
  end

  def test_reconcile_deletes_every_schedule_once_none_is_declared
    define_schedule 'a', cron: '0 3 * * *'
    Workhorse::Schedule.reconcile!
    Workhorse::Schedule.update_all(updated_at: Time.now - (2 * 24 * 60 * 60))

    Workhorse::Schedules.reset!
    Workhorse::Schedule.reconcile!

    assert_equal 0, Workhorse::Schedule.count
  end

  # ---------------------------------------------------------------
  # Catch-up policies
  # ---------------------------------------------------------------

  def test_nothing_is_due_before_the_occurrence
    now = Time.new(2026, 9, 28, 10, 0, 0)
    schedule = persisted_schedule('every_ten', cron: '*/10 * * * *', next_at: now + 300)

    occurrences, = schedule.pending_occurrences(now)

    assert_empty occurrences
  end

  # The point of the whole design: an occurrence that passed while nothing was
  # running is still there to be found.
  def test_an_occurrence_missed_during_an_outage_is_not_lost
    now = Time.new(2026, 9, 28, 10, 0, 0)
    schedule = persisted_schedule('nightly', cron: '0 3 * * *', next_at: Time.new(2026, 9, 28, 3, 0, 0))

    occurrences, next_at = schedule.pending_occurrences(now)

    assert_equal [Time.new(2026, 9, 28, 3, 0, 0)], occurrences
    assert_equal Time.new(2026, 9, 29, 3, 0, 0), next_at
  end

  def test_run_once_collapses_missed_occurrences
    now = Time.new(2026, 9, 28, 10, 0, 0)
    schedule = persisted_schedule(
      'every_ten', cron: '*/10 * * * *', catch_up: :run_once, next_at: now - 3600
    )

    occurrences, next_at = schedule.pending_occurrences(now)

    assert_equal 1, occurrences.size
    assert_equal Time.new(2026, 9, 28, 10, 0, 0), occurrences.first
    assert_operator next_at, :>, now
  end

  def test_run_materializes_every_missed_occurrence_up_to_the_cap
    now = Time.new(2026, 9, 28, 10, 0, 0)
    schedule = persisted_schedule(
      'every_ten', cron: '*/10 * * * *', catch_up: :run, next_at: now - 3600
    )

    occurrences, = schedule.pending_occurrences(now)

    assert_equal 7, occurrences.size
    assert_equal occurrences.sort, occurrences
  end

  def test_run_is_capped_by_max_catch_up
    now = Time.new(2026, 9, 28, 10, 0, 0)
    schedule = persisted_schedule(
      'every_minute', cron: '* * * * *', catch_up: :run, max_catch_up: 3, next_at: now - 3600
    )

    occurrences, = schedule.pending_occurrences(now)

    assert_equal 3, occurrences.size
    # The most recent ones, not the oldest.
    assert_equal Time.new(2026, 9, 28, 10, 0, 0), occurrences.last
  end

  def test_skip_runs_an_occurrence_that_is_within_grace
    now = Time.new(2026, 9, 28, 8, 5, 0)
    schedule = persisted_schedule(
      'digest', cron: '0 8 * * *', catch_up: :skip, grace: 15 * 60,
      next_at: Time.new(2026, 9, 28, 8, 0, 0)
    )

    occurrences, = schedule.pending_occurrences(now)

    assert_equal [Time.new(2026, 9, 28, 8, 0, 0)], occurrences
  end

  def test_skip_drops_an_occurrence_that_is_past_grace
    now = Time.new(2026, 9, 28, 14, 0, 0)
    schedule = persisted_schedule(
      'digest', cron: '0 8 * * *', catch_up: :skip, grace: 15 * 60,
      next_at: Time.new(2026, 9, 28, 8, 0, 0)
    )

    occurrences, next_at = schedule.pending_occurrences(now)

    assert_empty occurrences
    # Dropped, but the schedule still moves on to tomorrow.
    assert_equal Time.new(2026, 9, 29, 8, 0, 0), next_at
  end

  # Europe/Zurich moves from 02:00 to 03:00 on 2027-03-28, so an 02:30
  # schedule has no occurrence that day.
  def test_daylight_saving_spring_forward_skips_the_missing_hour
    schedule = persisted_schedule(
      'nightly', cron: '30 2 * * *', timezone: 'Europe/Zurich',
      next_at: Time.new(2027, 3, 27, 2, 30, 0)
    )

    days = 3.times.map do
      _occurrences, next_at = schedule.pending_occurrences(schedule.next_at)
      schedule.update!(next_at: next_at)
      next_at.in_time_zone('Europe/Zurich').day
    end

    # 02:30 does not exist on the 28th in this zone, so the schedule has no
    # occurrence that day and goes straight from the 27th to the 29th.
    refute_includes days, 28
    assert_equal [29, 30, 31], days
  end

  # ---------------------------------------------------------------
  # Claiming
  # ---------------------------------------------------------------

  def test_only_one_claim_of_the_same_occurrence_succeeds
    schedule = persisted_schedule('nightly', cron: '0 3 * * *', next_at: Time.now - 60)
    other = Workhorse::Schedule.find(schedule.id)

    assert schedule.claim!(Time.now + 3600)
    refute other.claim!(Time.now + 7200), 'a stale claim must not succeed'
  end

  # ---------------------------------------------------------------
  # Enqueuing
  # ---------------------------------------------------------------

  # perform_at carries the occurrence rather than the current time, which is
  # what makes the lateness of that occurrence measurable afterwards.
  def test_enqueue_records_the_intended_time
    occurrence = Time.now.round - 300
    schedule = persisted_schedule('nightly', cron: '0 3 * * *', next_at: occurrence)

    db_job = schedule.enqueue!(occurrence)

    assert_equal occurrence, db_job.perform_at
    assert_equal 'BasicJob (nightly)', db_job.description
    assert_equal db_job.id, schedule.reload.last_job_id
    assert_equal occurrence, schedule.last_occurrence
  end

  def test_enqueue_applies_max_lateness_and_expiry
    occurrence = Time.now.round - 300
    schedule = persisted_schedule(
      'nightly', cron: '0 3 * * *', next_at: occurrence,
      max_lateness: 60, expires_after: 900
    )

    db_job = schedule.enqueue!(occurrence)

    assert_equal 60, db_job.max_lateness
    assert_equal occurrence + 900, db_job.expires_at
  end

  def test_enqueue_works_for_active_job_classes
    occurrence = Time.now.round
    schedule = persisted_schedule(
      'aj', cron: '0 3 * * *', next_at: occurrence, job: 'ScheduledActiveJob', priority: 5
    )

    db_job = schedule.enqueue!(occurrence)

    assert_equal 5, db_job.priority
    assert_equal occurrence, db_job.perform_at
  end

  def test_enqueue_works_for_rails_ops_operations
    occurrence = Time.now.round
    schedule = persisted_schedule(
      'op', cron: '0 3 * * *', next_at: occurrence, job: 'DummyRailsOpsOp', params: {}
    )

    db_job = schedule.enqueue!(occurrence)

    assert_equal occurrence, db_job.perform_at
  end

  def test_enqueue_passes_params
    occurrence = Time.now.round
    schedule = persisted_schedule(
      'nightly', cron: '0 3 * * *', next_at: occurrence, params: { some_param: 'x', sleep_time: 0 }
    )

    db_job = schedule.enqueue!(occurrence)

    job = Marshal.load(db_job.handler) # rubocop:disable Security/MarshalLoad

    assert_equal 'x', job.instance_variable_get(:@some_param)
  end

  # ---------------------------------------------------------------
  # Poller integration
  # ---------------------------------------------------------------

  def test_a_worker_materializes_and_performs_a_due_schedule
    define_schedule 'due_now', cron: '* * * * *'
    Workhorse::Schedule.reconcile!
    Workhorse::Schedule.sole.update!(next_at: Time.now - 60)

    work 2, polling_interval: 0.2, pool_size: 1

    assert_equal 1, Workhorse::DbJob.succeeded.count
    assert_operator Workhorse::Schedule.sole.next_at, :>, Time.now
  end

  def test_a_disabled_schedule_is_not_materialized
    define_schedule 'due_now', cron: '* * * * *'
    Workhorse::Schedule.reconcile!
    Workhorse::Schedule.sole.update!(next_at: Time.now - 60, enabled: false)

    work 1, polling_interval: 0.2, pool_size: 1

    assert_equal 0, Workhorse::DbJob.count
  end

  # A schedule whose job class cannot be resolved must not stop the others,
  # nor take the worker down.
  def test_a_failing_schedule_does_not_stop_the_others
    define_schedule 'broken', cron: '* * * * *', job: 'ThisClassDoesNotExist'
    define_schedule 'fine', cron: '* * * * *'
    Workhorse::Schedule.reconcile!
    Workhorse::Schedule.update_all(next_at: Time.now - 60)

    exceptions = []
    with_exception_handler ->(e) { exceptions << e } do
      work 2, polling_interval: 0.2, pool_size: 1
    end

    assert_equal 1, Workhorse::DbJob.succeeded.count
    assert exceptions.any? { |e| e.is_a?(NameError) }, "expected a NameError, got #{exceptions.map(&:class)}"
  end

  # An occurrence must not be consumed unless the job for it exists. Were the
  # claim to commit on its own, a schedule whose enqueuing always fails would
  # advance past every occurrence while DetectLateSchedulesJob stayed green.
  def test_a_claim_is_rolled_back_when_enqueuing_fails
    define_schedule 'due_now', cron: '* * * * *', job: 'ThisClassDoesNotExist'
    Workhorse::Schedule.reconcile!
    schedule = Workhorse::Schedule.sole
    schedule.update!(next_at: Time.now - 60)
    before = schedule.reload.next_at

    with_exception_handler ->(_e) {} do
      work 1, polling_interval: 0.2, pool_size: 1
    end

    assert_equal 0, Workhorse::DbJob.count
    assert_equal before, schedule.reload.next_at, 'the occurrence must still be pending'
  end

  # Declaring schedules without the table must not take the workers down, only
  # keep the schedules from running.
  def test_a_missing_schedules_table_does_not_shut_the_worker_down
    define_schedule 'due_now', cron: '* * * * *'

    with_renamed_schedules_table do
      log = capture_log do |logger|
        with_worker(polling_interval: 0.2, pool_size: 1, auto_terminate: false, logger: logger) do |w|
          job = Workhorse.enqueue BasicJob.new(sleep_time: 0)

          with_retries { assert_equal 'succeeded', job.reload.state }

          assert_equal :running, w.state
        end
      end

      assert_match(/workhorse_schedules table does not exist/, log)
    end
  end

  # A rolling deployment runs both versions at once. Were a row deleted as
  # soon as one of them did not declare it, the two would delete each other's
  # schedules and reset the occurrences they were waiting for.
  def test_reconcile_keeps_a_schedule_another_version_still_declares
    define_schedule 'only_in_the_old_version', cron: '0 3 * * *'
    Workhorse::Schedule.reconcile!
    before = Workhorse::Schedule.sole.next_at

    # The other version, which does not know this schedule, starts up.
    Workhorse::Schedules.reset!
    define_schedule 'only_in_the_new_version', cron: '0 4 * * *'
    Workhorse::Schedule.reconcile!

    assert_equal %w[only_in_the_new_version only_in_the_old_version],
                 Workhorse::Schedule.order(:key).pluck(:key)
    assert_equal before, Workhorse::Schedule.find_by(key: 'only_in_the_old_version').next_at
  end

  def test_reconcile_deletes_a_schedule_nothing_has_declared_for_a_day
    define_schedule 'gone', cron: '0 3 * * *'
    Workhorse::Schedule.reconcile!
    Workhorse::Schedule.sole.update_columns(updated_at: Time.now - (2 * 24 * 60 * 60))

    Workhorse::Schedules.reset!
    Workhorse::Schedule.reconcile!

    assert_equal 0, Workhorse::Schedule.count
  end

  # An orphaned row is waiting to be cleaned up and nothing materializes it,
  # so reporting it as overdue would be a false alarm.
  def test_detect_late_schedules_ignores_rows_without_a_declaration
    persisted_schedule('known', cron: '0 3 * * *', next_at: Time.now + 3600)
    Workhorse::Schedule.create!(key: 'orphan', cron: '0 3 * * *', next_at: Time.now - 3600)

    assert_nothing_raised do
      Workhorse::Jobs::DetectLateSchedulesJob.new(threshold: 60).perform
    end
  end

  # ---------------------------------------------------------------
  # Expiry
  # ---------------------------------------------------------------

  def test_a_job_past_its_deadline_is_expired_instead_of_performed
    expired = []
    Workhorse.on_job_expired = proc { |db_job| expired << db_job.id }

    job = Workhorse.enqueue BasicJob.new(sleep_time: 0), expires_at: Time.now - 60

    work 1, polling_interval: 0.2, pool_size: 1

    assert_equal 'expired', job.reload.state
    assert_nil job.started_at
    assert_equal [job.id], expired
  end

  def test_a_job_within_its_deadline_is_performed
    job = Workhorse.enqueue BasicJob.new(sleep_time: 0), expires_at: Time.now + 3600

    work 2, polling_interval: 0.2, pool_size: 1

    assert_equal 'succeeded', job.reload.state
  end

  def test_a_raising_expiry_callback_does_not_take_the_worker_down
    Workhorse.on_job_expired = proc { fail 'callback is broken' }

    job = Workhorse.enqueue BasicJob.new(sleep_time: 0), expires_at: Time.now - 60
    other = nil

    exceptions = []
    with_exception_handler ->(e) { exceptions << e } do
      with_worker(polling_interval: 0.2, pool_size: 1, auto_terminate: false) do |w|
        with_retries { assert_equal 'expired', job.reload.state }

        other = Workhorse.enqueue BasicJob.new(sleep_time: 0)
        with_retries { assert_equal 'succeeded', other.reload.state }

        assert_equal :running, w.state
      end
    end

    assert(exceptions.any? { |e| e.message == 'callback is broken' })
  end

  # ---------------------------------------------------------------
  # Lateness
  # ---------------------------------------------------------------

  def test_a_late_job_reports_its_lateness
    late = []
    Workhorse.on_job_late = proc { |db_job, lateness| late << [db_job.id, lateness] }

    job = Workhorse.enqueue BasicJob.new(sleep_time: 0), perform_at: Time.now - 300, max_lateness: 60

    work 2, polling_interval: 0.2, pool_size: 1

    assert_equal 'succeeded', job.reload.state
    assert_equal 1, late.size
    assert_equal job.id, late.first.first
    assert_operator late.first.last, :>=, 300
  end

  def test_a_punctual_job_reports_nothing
    late = []
    Workhorse.on_job_late = proc { |db_job, lateness| late << [db_job.id, lateness] }

    job = Workhorse.enqueue BasicJob.new(sleep_time: 0), perform_at: Time.now, max_lateness: 3600

    work 2, polling_interval: 0.2, pool_size: 1

    assert_equal 'succeeded', job.reload.state
    assert_empty late
  end

  def test_a_raising_lateness_callback_does_not_fail_the_job
    Workhorse.on_job_late = proc { fail 'callback is broken' }

    job = Workhorse.enqueue BasicJob.new(sleep_time: 0), perform_at: Time.now - 300, max_lateness: 60

    exceptions = []
    with_exception_handler ->(e) { exceptions << e } do
      work 2, polling_interval: 0.2, pool_size: 1
    end

    assert_equal 'succeeded', job.reload.state
    assert(exceptions.any? { |e| e.message == 'callback is broken' })
  end

  # ---------------------------------------------------------------
  # Detection job
  # ---------------------------------------------------------------

  def test_detect_late_schedules_passes_when_up_to_date
    persisted_schedule('nightly', cron: '0 3 * * *', next_at: Time.now + 3600)

    assert_nothing_raised do
      Workhorse::Jobs::DetectLateSchedulesJob.new.perform
    end
  end

  def test_detect_late_schedules_fails_when_overdue
    persisted_schedule('nightly', cron: '0 3 * * *', next_at: Time.now - 3600)

    error = assert_raises RuntimeError do
      Workhorse::Jobs::DetectLateSchedulesJob.new(threshold: 60).perform
    end

    assert_match(/"nightly"/, error.message)
    assert_match(/not being materialized/, error.message)
  end

  def test_detect_late_schedules_ignores_disabled_schedules
    persisted_schedule('nightly', cron: '0 3 * * *', next_at: Time.now - 3600).update!(enabled: false)

    assert_nothing_raised do
      Workhorse::Jobs::DetectLateSchedulesJob.new(threshold: 60).perform
    end
  end

  private

  def define_schedule(key, job: 'BasicJob', **options)
    Workhorse.schedules do
      schedule key, job: job, params: { sleep_time: 0 }, **options
    end
  end

  # Registers a schedule and puts its row in place, bypassing reconciliation
  # so that `next_at` can be set to whatever the case under test needs.
  def persisted_schedule(key, cron:, next_at:, timezone: nil, **options)
    define_schedule(key, cron: cron, timezone: timezone, **options)

    return Workhorse::Schedule.create!(
      key: key, cron: cron, timezone: timezone, next_at: next_at
    )
  end

  # Hides the schedules table for the duration of the block, standing in for
  # an installation that declares schedules but has not run the migration.
  def with_renamed_schedules_table
    connection = ActiveRecord::Base.connection
    connection.rename_table :workhorse_schedules, :workhorse_schedules_hidden
    Workhorse::Schedule.reset_column_information
    yield
  ensure
    connection.rename_table :workhorse_schedules_hidden, :workhorse_schedules
    Workhorse::Schedule.reset_column_information
  end

  def with_exception_handler(handler)
    previous = Workhorse.on_exception
    Workhorse.on_exception = handler
    yield
  ensure
    Workhorse.on_exception = previous
  end
end
