require 'test_helper'

class Workhorse::WorkerTest < WorkhorseTest
  def test_idle
    w = Workhorse::Worker.new(pool_size: 5)
    w.start
    assert_equal 5, w.idle

    Workhorse::Enqueuer.enqueue BasicJob.new

    sleep 0.5
    assert_equal 4, w.idle

    sleep 1
    assert_equal 5, w.idle
  end

  def test_start_and_shutdown
    w = Workhorse::Worker.new
    w.start
    w.assert_state! :running

    assert_raises RuntimeError do
      w.start
    end

    w.shutdown
    w.shutdown # Should be ignored

    Workhorse::Enqueuer.enqueue BasicJob.new
  end

  def test_perform
    w = Workhorse::Worker.new polling_interval: 1
    Workhorse::Enqueuer.enqueue BasicJob.new
    assert_equal 'waiting', Workhorse::DbJob.first.state

    w.start
    sleep 2
    w.shutdown

    assert_equal 'succeeded', Workhorse::DbJob.first.state
  end

  def test_params
    BasicJob.results.clear

    Workhorse::Enqueuer.enqueue BasicJob.new(some_param: 5)
    w = Workhorse::Worker.new polling_interval: 1
    w.start
    sleep 2
    w.shutdown

    assert_equal 'succeeded', Workhorse::DbJob.first.state

    assert_equal 1, BasicJob.results.count
    assert_equal 5, BasicJob.results.first
  end

  def test_term
    w = Workhorse::Worker.new
    w.start
    Process.kill 'TERM', Process.pid
    sleep 1
    w.assert_state! :shutdown
  end

  def test_int
    w = Workhorse::Worker.new
    w.start
    Process.kill 'INT', Process.pid
    sleep 1
    w.assert_state! :shutdown
  end

  def test_no_queues
    enqueue_in_multiple_queues
    work 3, queues: [nil, :q1]

    jobs = Workhorse::DbJob.all.to_a
    assert_equal 'succeeded', jobs[0].state
    assert_equal 'succeeded', jobs[1].state
    assert_equal 'waiting',   jobs[2].state
  end

  def test_queues_with_nil
    enqueue_in_multiple_queues
    work 3, queues: [nil, :q1]

    jobs = Workhorse::DbJob.all.to_a
    assert_equal 'succeeded', jobs[0].state
    assert_equal 'succeeded', jobs[1].state
    assert_equal 'waiting',   jobs[2].state
  end

  def test_queues_without_nil
    enqueue_in_multiple_queues
    work 3, queues: %i[q1 q2]

    jobs = Workhorse::DbJob.all.to_a
    assert_equal 'waiting',   jobs[0].state
    assert_equal 'succeeded', jobs[1].state
    assert_equal 'succeeded', jobs[2].state
  end

  private

  def enqueue_in_multiple_queues
    Workhorse::Enqueuer.enqueue BasicJob.new(some_param: nil)
    Workhorse::Enqueuer.enqueue BasicJob.new(some_param: :q1), queue: :q1
    Workhorse::Enqueuer.enqueue BasicJob.new(some_param: :q2), queue: :q2
  end
end
