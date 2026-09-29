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

  # Registry

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

  def test_skip_without_grace_is_rejected
    error = assert_raises ArgumentError do
      define_schedule 'digest', cron: '0 8 * * *', catch_up: :skip
    end

    assert_match(/requires a grace period/, error.message)
  end

  # Reconciliation

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

    Workhorse::Schedules.reset!
    define_schedule 'nightly', cron: '0 3 * * *', timezone: 'Asia/Tokyo'
    Workhorse::Schedule.reconcile!(now)

    schedule = Workhorse::Schedule.sole

    assert_equal 'Asia/Tokyo', schedule.timezone
    assert_equal ActiveSupport::TimeZone['Asia/Tokyo'].local(2026, 9, 29, 3, 0, 0), schedule.next_at
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

  # Catch-up policies

  def test_nothing_is_due_before_the_occurrence
    now = Time.new(2026, 9, 28, 10, 0, 0)
    schedule = persisted_schedule('every_ten', cron: '*/10 * * * *', next_at: now + 300)

    occurrences, = schedule.pending_occurrences(now)

    assert_empty occurrences
  end

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
    assert_equal Time.new(2026, 9, 29, 8, 0, 0), next_at
  end

  # Europe/Zurich moves from 02:00 to 03:00 on 2027-03-28, so an 02:30
  # schedule has no occurrence that day.
  def test_daylight_saving_spring_forward_skips_the_missing_hour
    zone = ActiveSupport::TimeZone['Europe/Zurich']
    schedule = persisted_schedule(
      'nightly', cron: '30 2 * * *', timezone: 'Europe/Zurich',
      next_at: zone.local(2027, 3, 27, 2, 30, 0)
    )

    days = 3.times.map do
      _occurrences, next_at = schedule.pending_occurrences(schedule.next_at)
      schedule.update!(next_at: next_at)
      next_at.in_time_zone('Europe/Zurich').day
    end

    assert_equal [29, 30, 31], days
  end

  # Claiming

  def test_only_one_claim_of_the_same_occurrence_succeeds
    schedule = persisted_schedule('nightly', cron: '0 3 * * *', next_at: Time.now - 60)
    other = Workhorse::Schedule.find(schedule.id)

    assert schedule.claim!(Time.now + 3600)
    refute other.claim!(Time.now + 7200), 'a stale claim must not succeed'
  end

  # Enqueuing

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
    DummyScheduledOp.results.clear
    occurrence = Time.now.round
    schedule = persisted_schedule(
      'op', cron: '0 3 * * *', next_at: occurrence, job: 'DummyScheduledOp', params: { foo: :bar }
    )

    db_job = schedule.enqueue!(occurrence)
    handler = Marshal.load(db_job.handler) # rubocop:disable Security/MarshalLoad

    assert_equal Workhorse::Jobs::RunRailsOp, handler.class
    assert_equal occurrence, db_job.perform_at

    work 2, polling_interval: 0.2, pool_size: 1

    assert_equal 'succeeded', db_job.reload.state
    assert_equal [{ foo: :bar }], DummyScheduledOp.results.to_a
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

  # Poller integration

  def test_a_worker_materializes_and_performs_a_due_schedule
    define_schedule 'due_now', cron: '0 3 * * *'
    Workhorse::Schedule.reconcile!
    Workhorse::Schedule.sole.update!(next_at: yesterday_at_three)

    work 2, polling_interval: 0.2, pool_size: 1

    assert_equal 1, Workhorse::DbJob.succeeded.count
    assert_operator Workhorse::Schedule.sole.next_at, :>, Time.now
  end

  def test_a_disabled_schedule_is_not_materialized
    define_schedule 'due_now', cron: '0 3 * * *'
    Workhorse::Schedule.reconcile!
    Workhorse::Schedule.sole.update!(next_at: yesterday_at_three, enabled: false)

    work 1, polling_interval: 0.2, pool_size: 1

    assert_equal 0, Workhorse::DbJob.count
  end

  def test_a_failing_schedule_does_not_stop_the_others
    define_schedule 'broken', cron: '0 3 * * *', job: 'ThisClassDoesNotExist'
    define_schedule 'fine', cron: '0 3 * * *'
    Workhorse::Schedule.reconcile!
    Workhorse::Schedule.update_all(next_at: yesterday_at_three)

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
    define_schedule 'due_now', cron: '0 3 * * *', job: 'ThisClassDoesNotExist'
    Workhorse::Schedule.reconcile!
    schedule = Workhorse::Schedule.sole
    schedule.update!(next_at: yesterday_at_three)
    before = schedule.reload.next_at

    with_exception_handler ->(_e) {} do
      work 1, polling_interval: 0.2, pool_size: 1
    end

    assert_equal 0, Workhorse::DbJob.count
    assert_equal before, schedule.reload.next_at, 'the occurrence must still be pending'
  end

  def test_a_missing_schedules_table_does_not_shut_the_worker_down
    define_schedule 'due_now', cron: '* * * * *'
    exceptions = []

    with_renamed_schedules_table do
      log = capture_log do |logger|
        with_exception_handler ->(e) { exceptions << e } do
          with_worker(polling_interval: 0.2, pool_size: 1, auto_terminate: false, logger: logger) do |w|
            job = Workhorse.enqueue BasicJob.new(sleep_time: 0)

            with_retries { assert_equal 'succeeded', job.reload.state }

            assert_equal :running, w.state
          end
        end
      end

      assert_match(/workhorse_schedules table does not exist/, log)
    end

    assert exceptions.any? { |e| e.message =~ /workhorse_schedules table does not exist/ },
           'the missing table must be reported, not only logged'
  end

  # A rolling deployment runs both versions at once.
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

  def test_detect_late_schedules_ignores_rows_without_a_declaration
    persisted_schedule('known', cron: '0 3 * * *', next_at: Time.now - 3600)
    Workhorse::Schedule.create!(key: 'orphan', cron: '0 3 * * *', next_at: Time.now - 3600)

    error = assert_raises RuntimeError do
      Workhorse::Jobs::DetectLateSchedulesJob.new(threshold: 60).perform
    end

    assert_match(/"known"/, error.message)
    refute_match(/orphan/, error.message)
  end

  # Expiry

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

  # Lateness

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

  # Detection job

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

  # The expiry sweep is capped per poll, so the deadline has to be enforced by
  # the job selection as well: otherwise a backlog larger than the cap leaves
  # the surplus selectable and performed in the very same poll, past its
  # deadline.
  def test_a_backlog_larger_than_the_expiry_cap_is_still_not_performed
    total = Workhorse::Poller::MAX_EXPIRIES_PER_POLL + 5

    total.times { Workhorse.enqueue BasicJob.new(sleep_time: 0), expires_at: Time.now - 3600 }

    work 2, polling_interval: 0.2, pool_size: 1

    assert_equal 0, Workhorse::DbJob.succeeded.count, 'no job past its deadline may be performed'
    assert_equal total, Workhorse::DbJob.expired.count
  end

  # Capped, and draining in deadline order so that "the rest is expired by
  # the following polls" is not left to the optimiser.
  def test_the_expiry_sweep_is_capped_per_poll_and_takes_the_oldest_first
    surplus = 5
    total = Workhorse::Poller::MAX_EXPIRIES_PER_POLL + surplus

    total.times do |i|
      Workhorse.enqueue BasicJob.new(sleep_time: 0), expires_at: Time.now - ((total - i) * 60)
    end

    newest = Workhorse::DbJob.order(:expires_at).last(surplus).map(&:id)

    Workhorse::Worker.new(polling_interval: 60, pool_size: 1).poller.send(:expire_due_jobs)

    assert_equal Workhorse::Poller::MAX_EXPIRIES_PER_POLL, Workhorse::DbJob.expired.count
    assert_equal newest.sort, Workhorse::DbJob.waiting.pluck(:id).sort
  end

  def test_a_materialized_job_past_its_expiry_is_not_performed
    expired = []
    Workhorse.on_job_expired = proc { |db_job| expired << db_job.id }

    define_schedule 'digest', cron: '0 3 * * *', expires_after: 60
    Workhorse::Schedule.reconcile!
    Workhorse::Schedule.sole.update!(next_at: yesterday_at_three)

    work 2, polling_interval: 0.2, pool_size: 1

    db_job = Workhorse::DbJob.sole

    assert_equal 'expired', db_job.state
    assert_nil db_job.started_at
    assert_equal [db_job.id], expired
  end

  # The row that exists during every rolling deployment. Were the guard to
  # regress, every poll would raise on nil and be swallowed.
  def test_a_schedule_without_a_declaration_is_stepped_over
    define_schedule 'known', cron: '0 3 * * *'
    Workhorse::Schedule.reconcile!
    Workhorse::Schedule.create!(key: 'orphan', cron: '0 3 * * *', next_at: yesterday_at_three)

    exceptions = []
    with_exception_handler ->(e) { exceptions << e } do
      work 1, polling_interval: 0.2, pool_size: 1
    end

    assert_equal 0, Workhorse::DbJob.count
    assert_empty exceptions
  end

  def test_a_permanently_broken_schedule_is_reported_once
    define_schedule 'broken', cron: '0 3 * * *', job: 'ThisClassDoesNotExist'
    Workhorse::Schedule.reconcile!
    Workhorse::Schedule.sole.update!(next_at: yesterday_at_three)

    exceptions = []
    with_exception_handler ->(e) { exceptions << e } do
      work 2, polling_interval: 0.2, pool_size: 1
    end

    assert_equal 1, exceptions.size, "expected one report, got #{exceptions.size}"
  end

  def test_max_catch_up_is_validated
    assert_raises ArgumentError do
      define_schedule 'bad', cron: '* * * * *', catch_up: :run, max_catch_up: nil
    end

    Workhorse::Schedules.reset!

    assert_raises ArgumentError do
      define_schedule 'bad', cron: '* * * * *', catch_up: :run, max_catch_up: 0
    end
  end

  def test_an_occurrence_matching_now_is_recorded_without_its_fraction
    now = Time.at((Time.now.to_i / 60) * 60).utc + 0.4
    schedule = persisted_schedule('every_minute', cron: '* * * * *', next_at: now - 300)

    occurrences, = schedule.pending_occurrences(now)

    assert_equal 0, occurrences.last.usec
  end

  def test_occurrences_can_be_computed_during_the_fall_back_hour
    previous_tz = ENV.fetch('TZ', nil)
    # EtOrbi resolves a Time's zone from the process's, so the moment has to
    # be built while that zone is the ambiguous one.
    ENV['TZ'] = 'Europe/Zurich'

    ambiguous = ActiveSupport::TimeZone['Europe/Zurich'].parse('2026-10-25T02:30:00+02:00').to_time
    schedule = persisted_schedule(
      'nightly', cron: '0 3 * * *', timezone: 'Europe/Zurich', next_at: ambiguous - 3600
    )

    assert_nothing_raised do
      schedule.pending_occurrences(ambiguous)
    end
  ensure
    ENV['TZ'] = previous_tz
  end

  def test_nothing_due_leaves_the_next_occurrence_where_it_is
    future = Time.now + 3600
    schedule = persisted_schedule('nightly', cron: '0 3 * * *', next_at: future)

    occurrences, next_at = schedule.pending_occurrences(Time.now)

    assert_empty occurrences
    assert_equal schedule.next_at, next_at, 'the schedule must not be rewound'
  end

  def test_cleanup_removes_succeeded_and_expired_jobs_by_default
    old = Time.now - (30 * 24 * 60 * 60)
    kept = []
    removed = []

    { 'succeeded' => removed, 'expired' => removed, 'failed' => kept }.each do |state, bucket|
      job = Workhorse.enqueue BasicJob.new(sleep_time: 0)
      job.update_columns(state: state, updated_at: old)
      bucket << job.id
    end

    recent = Workhorse.enqueue BasicJob.new(sleep_time: 0)
    recent.update_columns(state: 'succeeded', updated_at: Time.now)
    kept << recent.id

    Workhorse::Jobs::CleanupSucceededJobs.new.perform

    assert_equal kept.sort, Workhorse::DbJob.pluck(:id).sort
  end

  def test_cleanup_can_be_restricted_to_succeeded_jobs
    old = Time.now - (30 * 24 * 60 * 60)
    expired = Workhorse.enqueue BasicJob.new(sleep_time: 0)
    succeeded = Workhorse.enqueue BasicJob.new(sleep_time: 0)
    expired.update_columns(state: 'expired', updated_at: old)
    succeeded.update_columns(state: 'succeeded', updated_at: old)

    Workhorse::Jobs::CleanupSucceededJobs.new(states: [Workhorse::DbJob::STATE_SUCCEEDED]).perform

    assert_equal [expired.id], Workhorse::DbJob.pluck(:id)
  end

  def test_cleanup_enqueued_before_the_upgrade_still_deletes
    old = Time.now - (30 * 24 * 60 * 60)
    job = Workhorse.enqueue BasicJob.new(sleep_time: 0)
    job.update_columns(state: 'succeeded', updated_at: old)

    cleanup = Workhorse::Jobs::CleanupSucceededJobs.new
    cleanup.remove_instance_variable(:@states)
    cleanup.perform

    assert_equal 0, Workhorse::DbJob.count
  end

  # The guards that let an installation upgrade the gem before the migration.
  def test_a_worker_runs_normally_without_the_expiry_columns
    without_expiry_columns do
      job = Workhorse.enqueue BasicJob.new(sleep_time: 0)

      work 2, polling_interval: 0.2, pool_size: 1

      assert_equal 'succeeded', job.reload.state
    end
  end

  def test_detect_late_schedules_can_be_restricted_to_keys
    persisted_schedule('checked', cron: '0 3 * * *', next_at: Time.now - 3600)
    persisted_schedule('ignored', cron: '0 4 * * *', next_at: Time.now - 3600)

    error = assert_raises RuntimeError do
      Workhorse::Jobs::DetectLateSchedulesJob.new(threshold: 60, keys: ['checked']).perform
    end

    assert_match(/"checked"/, error.message)
    refute_match(/ignored/, error.message)
  end

  # Two workers starting together both insert the same schedule; the loser of
  # the race must carry on rather than fail its whole reconciliation.
  def test_reconcile_tolerates_a_concurrent_insert
    define_schedule 'nightly', cron: '0 3 * * *'
    define_schedule 'other', cron: '0 4 * * *'

    Workhorse::Schedule.create!(key: 'nightly', cron: '0 3 * * *', next_at: Time.now + 3600)

    # As it looks to a worker whose SELECT ran before the other's INSERT.
    with_return_value(Workhorse::Schedule, :find_by, nil) do
      assert_nothing_raised { Workhorse::Schedule.reconcile! }
    end

    assert_equal %w[nightly other], Workhorse::Schedule.order(:key).pluck(:key)
  end

  # The clocks go back on 2026-10-25 in this zone, so 02:30 happens twice in
  # wall-clock terms. The schedule must still produce one occurrence that day.
  def test_daylight_saving_fall_back_does_not_repeat_an_occurrence
    previous_tz = ENV.fetch('TZ', nil)
    ENV['TZ'] = 'Europe/Zurich'
    zone = ActiveSupport::TimeZone['Europe/Zurich']
    schedule = persisted_schedule(
      'nightly', cron: '30 2 * * *', timezone: 'Europe/Zurich', catch_up: :run,
      next_at: zone.parse('2026-10-24T02:30:00').to_time
    )

    occurrences, = schedule.pending_occurrences(zone.parse('2026-10-26T12:00:00').to_time)
    days = occurrences.map { |o| o.in_time_zone(zone).day }

    assert_equal [24, 25, 26], days
    assert_equal days.uniq, days, 'no day may produce two occurrences'
  ensure
    ENV['TZ'] = previous_tz
  end

  # The default policy takes one occurrence per call, so the two instants of
  # the repeated hour arrive in separate calls where the within-call
  # deduplication cannot see them.
  def test_daylight_saving_fall_back_does_not_repeat_for_the_default_policy
    zone = ActiveSupport::TimeZone['Europe/Zurich']
    schedule = persisted_schedule(
      'nightly', cron: '30 2 * * *', timezone: 'Europe/Zurich',
      next_at: zone.parse('2026-10-24T02:30:00').to_time
    )

    fired = step_through(schedule, until_after: zone.parse('2026-10-27T00:00:00').to_time)
    days = fired.map { |o| o.in_time_zone(zone).day }

    assert_equal [24, 25, 26], days
  end

  # An hour holding several occurrences replays all of them, which a single
  # step over the repeat does not cover.
  def test_daylight_saving_fall_back_with_several_occurrences_in_the_hour
    previous_tz = ENV.fetch('TZ', nil)
    ENV['TZ'] = 'Europe/Zurich'
    zone = ActiveSupport::TimeZone['Europe/Zurich']
    schedule = persisted_schedule(
      'twice', cron: '0,30 2 * * *', timezone: 'Europe/Zurich',
      next_at: zone.parse('2026-10-25T02:00:00').to_time
    )

    fired = step_through(schedule, until_after: zone.parse('2026-10-25T23:00:00').to_time)
    locals = fired.map { |o| o.in_time_zone(zone).strftime('%H:%M %Z') }

    assert_equal ['02:00 CEST', '02:30 CEST'], locals
  ensure
    ENV['TZ'] = previous_tz
  end

  # The zone may be given as a trailing token of the expression instead of as
  # an option, and the wall-clock comparison has to read either.
  def test_daylight_saving_fall_back_with_the_zone_inside_the_expression
    previous_tz = ENV.fetch('TZ', nil)
    ENV['TZ'] = 'UTC'
    zone = ActiveSupport::TimeZone['Europe/Zurich']
    schedule = persisted_schedule(
      'nightly', cron:    '30 2 * * * Europe/Zurich',
                 next_at: zone.parse('2026-10-24T02:30:00').to_time
    )

    fired = step_through(schedule, until_after: zone.parse('2026-10-27T00:00:00').to_time)

    assert_equal([24, 25, 26], fired.map { |o| o.in_time_zone(zone).day })
  ensure
    ENV['TZ'] = previous_tz
  end

  # An expression with a wildcard hour ticks on every real instant, so both
  # halves of the repeated hour are genuine and must both be kept.
  def test_daylight_saving_fall_back_keeps_both_ticks_of_an_hourly_schedule
    zone = ActiveSupport::TimeZone['Europe/Zurich']
    schedule = persisted_schedule(
      'hourly', cron: '30 * * * *', timezone: 'Europe/Zurich', catch_up: :run,
      next_at: zone.parse('2026-10-25T00:30:00').to_time
    )

    occurrences, = schedule.pending_occurrences(zone.parse('2026-10-25T05:00:00').to_time)
    locals = occurrences.map { |o| o.in_time_zone(zone).strftime('%H:%M %Z') }

    repeated = locals.select { |l| l.start_with?('02:30') }

    assert_equal ['02:30 CEST', '02:30 CET'], repeated
    assert_equal 6, occurrences.size
  end

  def test_enqueue_uses_the_configured_queue_and_description
    occurrence = Time.now.round
    schedule = persisted_schedule(
      'nightly', cron: '0 3 * * *', next_at: occurrence,
      queue: :reports, description: 'Nightly report'
    )

    db_job = schedule.enqueue!(occurrence)

    assert_equal 'reports', db_job.queue
    assert_equal 'Nightly report', db_job.description
  end

  # ActiveJob defaults its queue_name to "default", so a scheduled ActiveJob
  # lands in a *named* queue even when the schedule names none - and named
  # queues run one job at a time, unlike the nil queue a plain job gets.
  def test_a_scheduled_active_job_lands_in_the_active_job_queue
    occurrence = Time.now.round
    aj = persisted_schedule('aj', cron: '0 3 * * *', next_at: occurrence, job: 'ScheduledActiveJob')
    plain = persisted_schedule('plain', cron: '0 4 * * *', next_at: occurrence)

    assert_equal 'default', aj.enqueue!(occurrence).queue
    assert_nil plain.enqueue!(occurrence).queue
  end

  private

  # Renamed rather than removed: dropping a column silently takes it out of
  # the composite index too, and adding it back does not restore it, leaving
  # every later test querying a differently indexed table.
  def without_expiry_columns
    connection = ActiveRecord::Base.connection
    connection.rename_column :jobs, :expires_at, :expires_at_hidden
    connection.rename_column :jobs, :max_lateness, :max_lateness_hidden
    Workhorse::DbJob.reset_column_information
    yield
  ensure
    connection.rename_column :jobs, :expires_at_hidden, :expires_at
    connection.rename_column :jobs, :max_lateness_hidden, :max_lateness
    Workhorse::DbJob.reset_column_information
  end

  # A real past occurrence of '0 3 * * *'. Seeding with an arbitrary past
  # moment would yield no occurrences at all, as the walk stops at next_at.
  def yesterday_at_three
    return (Time.now - (24 * 60 * 60)).change(hour: 3)
  end

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

  # Materializes occurrence by occurrence the way a worker polling at each
  # next_at does, rather than resolving a backlog in one call.
  def step_through(schedule, until_after:)
    fired = []
    cursor = schedule.next_at

    40.times do
      break if cursor > until_after

      occurrences, next_at = schedule.pending_occurrences(cursor)
      fired.concat(occurrences)
      schedule.update!(next_at: next_at)
      cursor = next_at
    end

    return fired
  end

  def with_exception_handler(handler)
    previous = Workhorse.on_exception
    Workhorse.on_exception = handler
    yield
  ensure
    Workhorse.on_exception = previous
  end
end
