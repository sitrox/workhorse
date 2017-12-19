require 'test_helper'

class Workhorse::EnqueuerTest < WorkhorseTest
  def test_basic
    assert_equal 0, Workhorse::DbJob.all.count
    Workhorse.enqueue BasicJob.new
    assert_equal 1, Workhorse::DbJob.all.count

    db_job = Workhorse::DbJob.first
    assert_equal 'waiting', db_job.state
    assert_equal Marshal.dump(BasicJob.new), db_job.handler
    assert_nil db_job.locked_by
    assert_nil db_job.queue
    assert_nil db_job.locked_at
    assert_nil db_job.started_at
    assert_nil db_job.last_error
    assert_not_nil db_job.created_at
    assert_not_nil db_job.updated_at
  end

  def test_with_queue
    assert_equal 0, Workhorse::DbJob.all.count
    Workhorse.enqueue BasicJob.new, queue: :q1
    assert_equal 1, Workhorse::DbJob.all.count

    db_job = Workhorse::DbJob.first
    assert_equal 'q1', db_job.queue
    assert_equal 0, db_job.priority
  end

  def test_with_priority
    Workhorse.enqueue BasicJob.new, priority: 1
    assert_equal 1, Workhorse::DbJob.first.priority
  end

  def test_op
    Workhorse.enqueue_op DummyRailsOpsOp, { queue: :q1 }, foo: :bar

    w = Workhorse::Worker.new(queues: [:q1])
    w.start
    sleep 1
    w.shutdown

    assert_equal 'succeeded', Workhorse::DbJob.first.state

    assert_equal [{ foo: :bar }], DummyRailsOpsOp.results
  end

  def test_op_without_params
    Workhorse.enqueue_op DummyRailsOpsOp, queue: :q1
    assert_equal 'q1', Workhorse::DbJob.first.queue
  end

  def test_op_without_params_and_queue
    Workhorse.enqueue_op DummyRailsOpsOp
    assert_nil Workhorse::DbJob.first.queue
  end
end
