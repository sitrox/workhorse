require 'test_helper'

class Workhorse::EnqueuerTest < ActiveSupport::TestCase
  def setup
    Workhorse::DbJob.delete_all
  end

  def test_basic
    assert_equal 0, Workhorse::DbJob.all.count
    Workhorse::Enqueuer.enqueue BasicJob.new
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
    Workhorse::Enqueuer.enqueue BasicJob.new, queue: :q1
    assert_equal 1, Workhorse::DbJob.all.count

    db_job = Workhorse::DbJob.first
    assert_equal 'q1', db_job.queue
  end

  def test_op
    Workhorse::Enqueuer.enqueue_op DummyRailsOpsOp, { foo: :bar }, queue: :q1

    w = Workhorse::Worker.new(queues: [:q1])
    w.start
    sleep 1.5
    w.shutdown

    assert_equal 'succeeded', Workhorse::DbJob.first.state

    assert_equal [{ foo: :bar }], DummyRailsOpsOp.results
  end
end
