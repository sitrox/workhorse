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
    rescue StandardError => e
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

  def test_connection_loss
    # rubocop: disable Style/GlobalVars
    $thread_conn = nil
    # rubocop: enable Style/GlobalVars

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

  def test_clean_stuck_jobs_locked
    [true, false].each do |clean|
      Workhorse::DbJob.delete_all

      Workhorse.clean_stuck_jobs = clean
      start_deamon
      Workhorse.enqueue BasicJob.new(sleep_time: 5)
      sleep 0.2
      kill_deamon_workers

      assert_equal 1, Workhorse::DbJob.count

      Workhorse::DbJob.first.update(
        state:      'locked',
        started_at: nil
      )

      Workhorse::Worker.new.poller.send(:clean_stuck_jobs!) if clean

      assert_equal 1, Workhorse::DbJob.count

      Workhorse::DbJob.first.tap do |job|
        if clean
          assert_equal 'waiting', job.state
          assert_nil job.locked_at
          assert_nil job.locked_by
          assert_nil job.started_at
          assert_nil job.last_error
        else
          assert_equal 'locked', job.state
        end
      end
    ensure
      Workhorse.clean_stuck_jobs = false
    end
  end

  def test_clean_stuck_jobs_running
    [true, false].each do |clean|
      Workhorse::DbJob.delete_all

      Workhorse.clean_stuck_jobs = true
      start_deamon
      Workhorse.enqueue BasicJob.new(sleep_time: 5)
      sleep 0.2
      kill_deamon_workers

      assert_equal 1, Workhorse::DbJob.count
      assert_equal 'started', Workhorse::DbJob.first.state

      work 0.1 if clean

      assert_equal 1, Workhorse::DbJob.count

      Workhorse::DbJob.first.tap do |job|
        if clean
          assert_equal 'failed', job.state
          assert_match(/started by PID #{@daemon.workers.first.pid}/, job.last_error)
          assert_match(/on host #{Socket.gethostname}/, job.last_error)
        else
          assert_equal 'started', job.state
        end
      end
    ensure
      Workhorse.clean_stuck_jobs = false
    end
  end

  private

  def kill_deamon_workers
    @daemon.workers.each do |worker|
      Process.kill 'KILL', worker.pid
    end
  end

  def start_deamon
    @daemon = Workhorse::Daemon.new(pidfile: 'tmp/pids/test%s.pid') do |d|
      d.worker 'Test Worker' do
        Workhorse::Worker.start_and_wait(
          pool_size:        1,
          polling_interval: 0.1
        )
      end
    end
    @daemon.start
  end

  def setup
    Workhorse::DbJob.delete_all
  end

  def assert_repolling_logged(count, log)
    assert_equal count, log.scan(/Aborting next sleep to perform instant repoll/m).size
  end
end
