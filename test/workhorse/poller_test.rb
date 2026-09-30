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

    assert_equal %w[q1 q2], valid_queues_of(w)

    first_job = Workhorse::DbJob.first
    first_job.mark_locked!(42)

    assert_equal %w[q2], valid_queues_of(w)

    first_job.mark_started!

    assert_equal %w[q2], valid_queues_of(w)

    first_job.mark_succeeded!

    assert_equal %w[q1 q2], valid_queues_of(w)

    last_job = Workhorse::DbJob.last
    last_job.mark_locked!(42)

    assert_equal %w[q1], valid_queues_of(w)

    begin
      fail 'Some exception'
    rescue StandardError => e
      last_job.mark_failed!(e)
    end

    assert_equal %w[q1 q2], valid_queues_of(w)
  end

  def test_valid_queues_2
    w = Workhorse::Worker.new(polling_interval: 60)

    assert_equal [], valid_queues_of(w)

    Workhorse.enqueue BasicJob.new(sleep_time: 2), queue: nil

    assert_equal [nil], valid_queues_of(w)

    a_job = Workhorse.enqueue BasicJob.new(sleep_time: 2), queue: :a

    assert_equal [nil, 'a'], valid_queues_of(w)

    a_job.update_attribute :state, :locked

    assert_equal [nil], valid_queues_of(w)
  end

  def test_no_queues
    w = Workhorse::Worker.new(polling_interval: 60)
    assert_equal [], valid_queues_of(w)
  end

  # Not every adapter returns a result set from `execute`: the Oracle enhanced
  # adapter, for instance, returns `true` for queries, both before and after
  # version 7.0.0. Querying the valid queues must therefore not rely on the
  # return value of `execute`.
  def test_valid_queues_without_usable_execute
    w = Workhorse::Worker.new(polling_interval: 60)

    Workhorse.enqueue BasicJob.new(sleep_time: 2), queue: nil
    Workhorse.enqueue BasicJob.new(sleep_time: 2), queue: :a

    with_return_value(Workhorse::DbJob.connection, :execute, true) do
      assert_equal [nil, 'a'], valid_queues_of(w)
    end
  end

  def test_nil_queues
    w = Workhorse::Worker.new(pool_size: 2, polling_interval: 60)

    3.times do
      Workhorse.enqueue BasicJob.new(sleep_time: 2)
    end
    jobs = Workhorse::DbJob.all

    assert_equal [nil], valid_queues_of(w)

    jobs[0].mark_locked!(42)

    assert_equal [nil], valid_queues_of(w)
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
    # Create 50 jobs
    50.times do |i|
      Workhorse.enqueue BasicJob.new(some_param: i, sleep_time: 0)
    end

    # Create 10 worker processes that work until all 100 jobs have succeeded,
    # and for at least 3s, so that each is still polling while the second
    # batch comes in. Not for a fixed time: every poll holds the global lock
    # throughout, so the workers take turns, and 3s got through as few as 25
    # of the 100 jobs on a loaded CI runner, and 61 on Oracle. What is tested
    # is that none is taken twice and every worker gets a turn, not how fast.
    10.times do
      Process.fork do
        started = Time.now

        with_worker(pool_size: 1, polling_interval: 0.1, auto_terminate: false) do
          loop do
            elapsed = Time.now - started
            break if elapsed >= 3 && Workhorse::DbJob.succeeded.count >= 100
            break if elapsed >= 60

            sleep 0.1
          end
        end
      ensure
        # Exit without running the at_exit handlers of the test process: one
        # of them is Minitest's, which joins threads this fork did not
        # inherit and hangs the child, leaving waitall below waiting forever.
        # In an ensure, as a child that raised must not run them either.
        exit!(0)
      end
    end

    # Create additional 50 jobs that are scheduled while the workers are
    # already polling (to make sure those are picked up as well)
    50.times do
      sleep 0.02
      Workhorse.enqueue BasicJob.new(sleep_time: 0)
    end

    # Wait for all forked processes to finish
    Process.waitall

    total = Workhorse::DbJob.count
    succeeded = Workhorse::DbJob.succeeded.count
    # In a transaction, as Oracle commits a FOR UPDATE outside of one before
    # its rows are fetched and then fails with "fetch out of sequence".
    used_workers = Workhorse::DbJob.transaction do
      Workhorse::DbJob.lock.pluck(:locked_by).uniq.size
    end

    # Make sure there are 100 jobs, all jobs have succeeded and that all of the
    # workers have had their turn.
    assert_equal 100, total
    assert_equal 100, succeeded
    assert_equal 10,  used_workers
  end

  # A poll that finds the global lock taken waits at least as long as it asked
  # to before giving up. Below half a second is what the poller asks for with
  # a short polling interval, and what MySQL and Oracle, which take the timeout
  # as whole seconds, used to round down to not waiting at all.
  def test_contended_global_lock_waits_for_its_timeout
    poller = Workhorse::Worker.new(polling_interval: 0.3).poller
    ran = false

    elapsed = with_global_lock_held do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      poller.send(:with_global_lock, timeout: 0.3, count_failures: false) { ran = true }
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    end

    assert_not ran
    assert_operator elapsed, :>=, 0.25
  end

  def test_connection_loss
    # rubocop: disable-next Style/GlobalVars
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

  def test_clean_stuck_jobs_locked
    [true, false].each do |clean|
      Workhorse::DbJob.delete_all

      Workhorse.clean_stuck_jobs = clean
      with_daemon do
        Workhorse.enqueue BasicJob.new(sleep_time: 5)

        # Waited for rather than slept on: until a worker has taken the job,
        # locked_by is empty and the cleanup, which matches on the host in it,
        # cannot recognise the job as one of its own.
        with_retries do
          assert_equal 'started', Workhorse::DbJob.first.state
        end

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
      end
    ensure
      Workhorse.clean_stuck_jobs = false
    end
  end

  def test_clean_stuck_jobs_running
    [true, false].each do |clean|
      Workhorse::DbJob.delete_all

      Workhorse.clean_stuck_jobs = clean
      with_daemon do
        Workhorse.enqueue BasicJob.new(sleep_time: 5)

        with_retries do
          assert_equal 'started', Workhorse::DbJob.first.state
        end

        kill_deamon_workers

        assert_equal 'started', Workhorse::DbJob.first.state

        work_until do
          Workhorse::DbJob.first.tap do |job|
            if clean
              assert_equal 'failed', job.state
              assert_match(/started by PID #{daemon.workers.first.pid}/, job.last_error)
              assert_match(/on host #{Socket.gethostname}/, job.last_error)
            else
              assert_equal 'started', job.state
            end
          end
        end
      end
    ensure
      Workhorse.clean_stuck_jobs = false
    end
  end

  private

  # The worker's valid queues, the queueless one first. Sorted here, as they
  # come from a SELECT DISTINCT without ORDER BY: MySQL happens to return NULL
  # first, Oracle does not, and the poller does not depend on the order.
  def valid_queues_of(worker)
    return worker.poller.send(:valid_queues).sort_by { |queue| [queue.nil? ? 0 : 1, queue.to_s] }
  end

  def kill_deamon_workers
    pids = daemon.workers.map(&:pid)
    pids.each do |pid|
      Process.kill 'KILL', pid
      # Wait for zombies to be reaped by Process.detach threads
      # This is necessary because Process.getpgid succeeds for zombie processes
      wait_for_process_exit(pid)
    end
  end

  def setup
    Workhorse::DbJob.delete_all
  end

  def assert_repolling_logged(count, log)
    assert_equal count, log.scan(/Aborting next sleep to perform instant repoll/m).size
  end
end
