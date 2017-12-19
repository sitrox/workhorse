require 'test_helper'

class Workhorse::WorkerTest < WorkhorseTest
  def test_idle
    with_worker(pool_size: 5, polling_interval: 1) do |w|
      assert_equal 5, w.idle

      sleep 0.5
      Workhorse.enqueue BasicJob.new(sleep_time: 1)

      sleep 1
      assert_equal 4, w.idle

      sleep 1
      assert_equal 5, w.idle
    end
  end

  def test_start_and_shutdown
    with_worker do |w|
      w.assert_state! :running

      assert_raises RuntimeError do
        w.start
      end

      w.shutdown
      w.shutdown # Should be ignored
    end
  end

  def test_perform
    with_worker(polling_interval: 1) do
      sleep 0.1
      Workhorse.enqueue BasicJob.new(sleep_time: 0.1)
      assert_equal 'waiting', Workhorse::DbJob.first.state

      sleep 1
    end

    assert_equal 'succeeded', Workhorse::DbJob.first.state
  end

  def test_params
    BasicJob.results.clear

    Workhorse.enqueue BasicJob.new(some_param: 5, sleep_time: 0)
    work 0.5

    assert_equal 'succeeded', Workhorse::DbJob.first.state

    assert_equal 1, BasicJob.results.count
    assert_equal 5, BasicJob.results.first
  end

  def test_term
    with_worker do |w|
      Process.kill 'TERM', Process.pid
      sleep 1
      w.assert_state! :shutdown
    end
  end

  def test_int
    with_worker do |w|
      Process.kill 'INT', Process.pid
      sleep 1
      w.assert_state! :shutdown
    end
  end

  def test_no_queues
    enqueue_in_multiple_queues
    work 1

    jobs = Workhorse::DbJob.order(queue: :asc).to_a
    assert_equal 'succeeded', jobs[0].state
    assert_equal 'succeeded', jobs[1].state
    assert_equal 'succeeded', jobs[2].state
  end

  def test_nil_queue
    enqueue_in_multiple_queues
    work 1, queues: [nil]

    jobs = Workhorse::DbJob.order(queue: :asc).to_a
    assert_equal 'succeeded', jobs[0].state
    assert_equal 'waiting',   jobs[1].state
    assert_equal 'waiting',   jobs[2].state
  end

  def test_queues_with_nil
    enqueue_in_multiple_queues
    work 1, queues: [nil, :q1]

    jobs = Workhorse::DbJob.order(queue: :asc).to_a
    assert_equal 'succeeded', jobs[0].state
    assert_equal 'succeeded', jobs[1].state
    assert_equal 'waiting',   jobs[2].state
  end

  def test_queues_without_nil
    enqueue_in_multiple_queues
    work 1, queues: %i[q1 q2]

    jobs = Workhorse::DbJob.order(queue: :asc).to_a
    assert_equal 'waiting',   jobs[0].state
    assert_equal 'succeeded', jobs[1].state
    assert_equal 'succeeded', jobs[2].state
  end

  def test_order_with_priorities
    Workhorse.enqueue BasicJob.new(some_param: 6, sleep_time: 0), priority: 4
    Workhorse.enqueue BasicJob.new(some_param: 4, sleep_time: 0), priority: 3
    Workhorse.enqueue BasicJob.new(some_param: 5, sleep_time: 0), priority: 3
    Workhorse.enqueue BasicJob.new(some_param: 3, sleep_time: 0), priority: 2
    Workhorse.enqueue BasicJob.new(some_param: 2, sleep_time: 0), priority: 1
    Workhorse.enqueue BasicJob.new(some_param: 1, sleep_time: 0), priority: 0

    BasicJob.results.clear
    work 6.5, pool_size: 1
    assert_equal (1..6).to_a, BasicJob.results
  end

  private

  def enqueue_in_multiple_queues
    Workhorse.enqueue BasicJob.new(some_param: nil)
    Workhorse.enqueue BasicJob.new(some_param: :q1), queue: :q1
    Workhorse.enqueue BasicJob.new(some_param: :q2), queue: :q2
  end
end
