require 'test_helper'

class Workhorse::DbJobTest < WorkhorseTest
  def test_reset_succeeded
    job = Workhorse.enqueue(BasicJob.new(sleep_time: 0))
    work_until { assert_equal 'succeeded', job.reload.state }
    job.reset!
    assert_clean job.reload
  end

  def test_reset_failed
    job = Workhorse.enqueue FailingTestJob.new
    work 0.5
    job.reload
    assert_equal 'failed', job.state

    job.reset!

    assert_clean job
  end

  def test_reset_locked_unforced
    job = Workhorse.enqueue(BasicJob.new(sleep_time: 0))
    job.mark_locked!(42)

    err = assert_raises do
      job.reset!
    end
    assert_equal %(Job #{job.id} is not in state [:succeeded, :failed] but in state "locked".), err.message
  end

  def test_forced_reset
    job = Workhorse.enqueue(BasicJob.new(sleep_time: 0))
    job.mark_locked!(42)

    assert_nothing_raised do
      job.reset!(true)
    end

    assert_clean job
  end

  private

  def assert_clean(job)
    assert_equal 'waiting', job.state
    assert_nil job.locked_by
    assert_nil job.locked_at
    assert_nil job.started_at
    assert_nil job.failed_at
    assert_nil job.succeeded_at
    assert_nil job.last_error
  end
end
