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

  def test_valid_queues_2
    w = Workhorse::Worker.new(polling_interval: 60)

    assert_equal [], w.poller.send(:valid_queues)

    Workhorse.enqueue BasicJob.new(sleep_time: 2), queue: nil

    assert_equal [nil], w.poller.send(:valid_queues)

    a_job = Workhorse.enqueue BasicJob.new(sleep_time: 2), queue: :a

    assert_equal [nil, 'a'], w.poller.send(:valid_queues)

    a_job.update_attribute :state, :locked

    assert_equal [nil], w.poller.send(:valid_queues)
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

  def test_without_instant_repolling
    3.times do
      Workhorse.enqueue BasicJob.new(sleep_time: 0)
    end

    log = capture_log do |logger|
      work 0.5, instant_repolling: false, polling_interval: 5, pool_size: 1, logger: logger
    end

    assert_repolling_logged 0, log
    assert_equal 1, Workhorse::DbJob.where(state: :succeeded).count
  end

  def test_already_locked_issue
    # Create 100 jobs
    100.times do |i|
      Workhorse.enqueue BasicJob.new(some_param: i, sleep_time: 0)
    end

    # Create 25 worker processes that work for 10s each
    25.times do
      Process.fork do
        work 10, pool_size: 1, polling_interval: 0.1
      end
    end

    # Create additional 100 jobs that are scheduled while the workers are
    # already polling (to make sure those are picked up as well)
    100.times do
      sleep 0.05
      Workhorse.enqueue BasicJob.new(sleep_time: 0)
    end

    # Wait for all forked processes to finish (should take ~10s)
    Process.waitall

    total = Workhorse::DbJob.count
    succeeded = Workhorse::DbJob.succeeded.count
    used_workers = Workhorse::DbJob.lock.pluck(:locked_by).uniq.size

    # Make sure there are 200 jobs, all jobs have succeeded and that all of the
    # workers have had their turn.
    assert_equal 200, total
    assert_equal 200, succeeded
    assert_equal 25,  used_workers
  end

  # rubocop: disable Style/GlobalVars
  def test_connection_loss
    $thread_conn = nil

    Workhorse.enqueue BasicJob.new(sleep_time: 3)

    t = Thread.new do
      w = Workhorse::Worker.new(pool_size: 5, polling_interval: 0.1)
      w.start

      sleep 0.5

      w.poller.define_singleton_method :poll do
        fail ActiveRecord::StatementInvalid, 'Mysql2::Error: Connection was killed'
      end

      w.wait
    end

    assert_nothing_raised do
      Timeout.timeout(6) do
        t.join
      end
    end

    assert_equal 1, Workhorse::DbJob.succeeded.count
  end
  # rubocop: enable Style/GlobalVars

  private

  def setup
    Workhorse::DbJob.delete_all
  end

  def assert_repolling_logged(count, log)
    assert_equal count, log.scan(/Aborting next sleep to perform instant repoll/m).size
  end
end
