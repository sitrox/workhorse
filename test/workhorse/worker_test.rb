require 'test_helper'

class Workhorse::WorkerTest < WorkhorseTest
  def test_idle
    with_worker(pool_size: 5, polling_interval: 0.2) do |w|
      assert_equal 5, w.idle

      sleep 0.1
      Workhorse.enqueue BasicJob.new(sleep_time: 0.2)

      sleep 0.2
      assert_equal 4, w.idle

      sleep 0.2
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
    with_worker(polling_interval: 0.2) do
      sleep 0.1
      Workhorse.enqueue BasicJob.new(sleep_time: 0.1)
      assert_equal 'waiting', Workhorse::DbJob.first.state

      sleep 0.3
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
    with_worker(polling_interval: 0.2) do |w|
      Process.kill 'TERM', Process.pid
      sleep 0.2
      w.assert_state! :shutdown
    end
  end

  def test_int
    with_worker(polling_interval: 0.2) do |w|
      Process.kill 'INT', Process.pid
      sleep 0.2
      w.assert_state! :shutdown
    end
  end

  def test_no_queues
    enqueue_in_multiple_queues
    work 0.2, polling_interval: 0.2

    jobs = Workhorse::DbJob.order(queue: :asc).to_a
    assert_equal 'succeeded', jobs[0].state
    assert_equal 'succeeded', jobs[1].state
    assert_equal 'succeeded', jobs[2].state
  end

  def test_nil_queue
    enqueue_in_multiple_queues
    work 0.2, queues: [nil], polling_interval: 0.2

    jobs = Workhorse::DbJob.order(queue: :asc).to_a
    assert_equal 'succeeded', jobs[0].state
    assert_equal 'waiting',   jobs[1].state
    assert_equal 'waiting',   jobs[2].state
  end

  def test_queues_with_nil
    enqueue_in_multiple_queues
    work 0.2, queues: [nil, :q1], polling_interval: 0.2

    jobs = Workhorse::DbJob.order(queue: :asc).to_a
    assert_equal 'succeeded', jobs[0].state
    assert_equal 'succeeded', jobs[1].state
    assert_equal 'waiting',   jobs[2].state
  end

  def test_queues_without_nil
    enqueue_in_multiple_queues
    work 0.2, queues: %i[q1 q2], polling_interval: 0.2

    jobs = Workhorse::DbJob.order(queue: :asc).to_a
    assert_equal 'waiting',   jobs[0].state
    assert_equal 'succeeded', jobs[1].state
    assert_equal 'succeeded', jobs[2].state
  end

  def test_multiple_queued_same_queue
    # One queue
    Workhorse.enqueue BasicJob.new(sleep_time: 0.2), queue: :q1
    Workhorse.enqueue BasicJob.new(sleep_time: 0.2), queue: :q1

    work 0.2, polling_interval: 0.2

    jobs = Workhorse::DbJob.all.to_a
    assert_equal 'succeeded', jobs[0].state
    assert_equal 'waiting',   jobs[1].state

    # Two queues
    Workhorse::DbJob.delete_all
    Workhorse.enqueue BasicJob.new(sleep_time: 0.2), queue: :q1
    Workhorse.enqueue BasicJob.new(sleep_time: 0.2), queue: :q1
    Workhorse.enqueue BasicJob.new(sleep_time: 0.2), queue: :q2
    Workhorse.enqueue BasicJob.new(sleep_time: 0.2), queue: :q2

    work 0.2, polling_interval: 0.2

    jobs = Workhorse::DbJob.order(queue: :asc).to_a
    assert_equal 'succeeded', jobs[0].state
    assert_equal 'waiting',   jobs[1].state
    assert_equal 'succeeded', jobs[2].state
    assert_equal 'waiting',   jobs[3].state
  end

  def test_order_with_priorities
    Workhorse.enqueue BasicJob.new(some_param: 6, sleep_time: 0), priority: 4
    Workhorse.enqueue BasicJob.new(some_param: 4, sleep_time: 0), priority: 3
    Workhorse.enqueue BasicJob.new(some_param: 5, sleep_time: 0), priority: 3
    Workhorse.enqueue BasicJob.new(some_param: 3, sleep_time: 0), priority: 2
    Workhorse.enqueue BasicJob.new(some_param: 2, sleep_time: 0), priority: 1
    Workhorse.enqueue BasicJob.new(some_param: 1, sleep_time: 0), priority: 0

    BasicJob.results.clear
    work 1.3, pool_size: 1, polling_interval: 0.2
    assert_equal (1..6).to_a, BasicJob.results
  end

  def test_polling_interval
    w = Workhorse::Worker.new(polling_interval: 1)
    w = Workhorse::Worker.new(polling_interval: 1.1)
    err = assert_raises do
      w = Workhorse::Worker.new(polling_interval: 1.12)
    end
    assert_equal 'Polling interval must be a multiple of 0.1.', err.message
  end

  def test_perform_at
    Workhorse.enqueue BasicJob.new(sleep_time: 0), perform_at: Time.now
    Workhorse.enqueue BasicJob.new(sleep_time: 0), perform_at: Time.now + 600
    work 0.1, polling_interval: 0.1

    jobs = Workhorse::DbJob.all.to_a
    assert_equal 'succeeded', jobs[0].state
    assert_equal 'waiting',   jobs[1].state
  end

  private

  def enqueue_in_multiple_queues
    Workhorse.enqueue BasicJob.new(some_param: nil)
    Workhorse.enqueue BasicJob.new(some_param: :q1), queue: :q1
    Workhorse.enqueue BasicJob.new(some_param: :q2), queue: :q2
  end
end
