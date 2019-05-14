require 'test_helper'

class Workhorse::PollerTest < WorkhorseTest
  def test_interruptable_sleep
    w = Workhorse::Worker.new(polling_interval: 60)
    w.start
    sleep 0.1

    Timeout.timeout(0.15) do
      w.shutdown
    end
  end

  def test_valid_queues
    w = Workhorse::Worker.new(polling_interval: 60)

    Workhorse.enqueue BasicJob.new(sleep_time: 2), queue: :q1
    Workhorse.enqueue BasicJob.new(sleep_time: 2), queue: :q1
    Workhorse.enqueue BasicJob.new(sleep_time: 2), queue: :q2
    Workhorse.enqueue BasicJob.new(sleep_time: 2), queue: :q2

    assert_equal %w[q1 q2], w.poller.send(:valid_queues)

    first_job = Workhorse::DbJob.first
    first_job.mark_locked!(42)

    assert_equal %w[q2], w.poller.send(:valid_queues)

    first_job.mark_started!

    assert_equal %w[q2], w.poller.send(:valid_queues)

    first_job.mark_succeeded!

    assert_equal %w[q1 q2], w.poller.send(:valid_queues)

    last_job = Workhorse::DbJob.last
    last_job.mark_locked!(42)

    assert_equal %w[q1], w.poller.send(:valid_queues)

    begin
      fail 'Some exception'
    rescue => e
      last_job.mark_failed!(e)
    end

    assert_equal %w[q1 q2], w.poller.send(:valid_queues)
  end

  def test_no_queues
    w = Workhorse::Worker.new(polling_interval: 60)
    assert_equal [], w.poller.send(:valid_queues)
  end

  def test_nil_queues
    w = Workhorse::Worker.new(pool_size: 2, polling_interval: 60)

    3.times do
      Workhorse.enqueue BasicJob.new(sleep_time: 2)
    end
    jobs = Workhorse::DbJob.all

    assert_equal [nil], w.poller.send(:valid_queues)

    jobs[0].mark_locked!(42)

    assert_equal [nil], w.poller.send(:valid_queues)
  end

  def test_with_instant_repolling
    Workhorse::DbJob.delete_all

    3.times do
      Workhorse.enqueue BasicJob.new(sleep_time: 0)
    end

    assert_equal 3, Workhorse::DbJob.where(state: :waiting).count

    log = capture_log do |logger|
      work 2, instant_repolling: true, polling_interval: 5, pool_size: 1, logger: logger
    end

    assert_repolling_logged 3, log
    assert_equal 3, Workhorse::DbJob.where(state: :succeeded).count
  end

  def test_no_instant_repoll_if_poll_since
    Workhorse::DbJob.delete_all
    Workhorse.enqueue BasicJob.new(sleep_time: 1)

    log = capture_log do |logger|
      work 1.5, instant_repolling: true, polling_interval: 0.5, pool_size: 1, logger: logger
    end

    assert_repolling_logged 0, log
    assert_equal 1, Workhorse::DbJob.where(state: :succeeded).count
  end

  def test_without_instant_repolling
    Workhorse::DbJob.delete_all

    3.times do
      Workhorse.enqueue BasicJob.new(sleep_time: 0)
    end

    log = capture_log do |logger|
      work 0.5, instant_repolling: false, polling_interval: 5, pool_size: 1, logger: logger
    end

    assert_repolling_logged 0, log
    assert_equal 1, Workhorse::DbJob.where(state: :succeeded).count
  end

  private

  def assert_repolling_logged(count, log)
    assert_equal count, log.scan(/Aborting next sleep to perform instant repoll/m).size
  end
end
