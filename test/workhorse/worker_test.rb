require 'test_helper'

class Workhorse::WorkerTest < WorkhorseTest
  # Guards the interleaving that deadlocks the worker if #shutdown holds the
  # mutex while waiting for the poller thread: that thread may be in #perform
  # waiting for the same mutex, having just committed the lock on a job.
  def test_shutdown_while_the_poller_posts_a_job
    job = Workhorse.enqueue BasicJob.new(sleep_time: 0)
    w = Workhorse::Worker.new(polling_interval: 60, pool_size: 1)

    # As the poller would have, in a transaction that has already committed.
    job.mark_locked!(w.id)

    at_perform = Concurrent::Event.new
    posted = Concurrent::Event.new

    w.poller.define_singleton_method(:poll) do
      next if @posted_once

      @posted_once = true
      at_perform.set
      # Give the shutdown below time to get as far as waiting for this thread.
      Kernel.sleep 0.3
      worker.perform(job.id)
      posted.set
    end

    w.start

    assert at_perform.wait(5), 'poller did not reach the job posting'

    Timeout.timeout(15) do
      w.shutdown
    end

    assert posted.wait(5), 'poller thread never returned from #perform'

    job.reload

    assert_equal 'waiting', job.state
    assert_nil job.locked_at
    assert_nil job.locked_by
  end

  # #shutdown promises that running jobs have finished once it returns. Both
  # TERM and INT are sent by the daemon's stop, so a repeat call has to keep
  # that promise too rather than returning while the first one is still
  # waiting for the pool.
  def test_a_repeated_shutdown_waits_for_the_running_job
    job = Workhorse.enqueue BasicJob.new(sleep_time: 2)
    w = Workhorse::Worker.new(polling_interval: 0.2, pool_size: 1)
    w.start

    with_retries(60, interval: 0.05) { assert_equal 'started', job.reload.state }

    states = Concurrent::Array.new
    first = Thread.new { w.shutdown }
    sleep 0.3
    second = Thread.new do
      w.shutdown
      states << job.reload.state
    end

    Timeout.timeout(15) { second.join }

    assert_equal ['succeeded'], states.to_a,
                 'a repeated shutdown must not return while a job is still running'
    assert_equal :shutdown, w.state
  ensure
    first&.join
  end

  def test_shutdown_of_a_worker_that_was_never_started
    w = Workhorse::Worker.new(polling_interval: 60)

    Timeout.timeout(5) { w.shutdown }

    assert_equal :initialized, w.state
  end

  # A job that another worker already reset - or that never got locked - must
  # be left alone rather than reset a second time.
  def test_a_job_that_is_no_longer_locked_is_not_released
    job = Workhorse.enqueue BasicJob.new(sleep_time: 0)
    w = Workhorse::Worker.new(polling_interval: 60, pool_size: 1)
    w.start
    w.shutdown

    job.update_columns(state: 'succeeded')

    w.send(:release, job.id)

    assert_equal 'succeeded', job.reload.state
  end

  def test_idle
    with_worker(pool_size: 5, polling_interval: 0.2) do |w|
      assert_equal 5, w.idle

      sleep 0.05
      Workhorse.enqueue BasicJob.new(sleep_time: 0.2)

      sleep 0.25
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

  def test_soft_restart_when_idle
    with_worker(pool_size: 2, polling_interval: 0.2) do |w|
      assert w.accepting_jobs?

      Process.kill 'USR1', Process.pid

      with_retries { assert_equal :shutdown, w.state }
      assert File.exist?(Workhorse::Worker.shutdown_file_for(Process.pid))
    end
  ensure
    FileUtils.rm_f Workhorse::Worker.shutdown_file_for(Process.pid)
  end

  def test_soft_restart_when_busy_waits_for_job
    with_worker(pool_size: 1, polling_interval: 0.2) do |w|
      Workhorse.enqueue BasicJob.new(sleep_time: 0.5)
      with_retries { assert_equal 'started', Workhorse::DbJob.first.state }

      Process.kill 'USR1', Process.pid
      sleep 0.1

      # Still running but not accepting jobs
      w.assert_state! :running
      assert_not w.accepting_jobs?

      # Wait for job to finish and worker to shut down
      with_retries { assert_equal :shutdown, w.state }
    end
  ensure
    FileUtils.rm_f Workhorse::Worker.shutdown_file_for(Process.pid)
  end

  def test_soft_restart_prevents_new_job_pickup
    with_worker(pool_size: 1, polling_interval: 0.2) do |w|
      Workhorse.enqueue BasicJob.new(sleep_time: 0.4)
      with_retries { assert_equal 'started', Workhorse::DbJob.first.state }

      Process.kill 'USR1', Process.pid
      sleep 0.1

      # Enqueue another job while soft restart is pending
      Workhorse.enqueue BasicJob.new(sleep_time: 0.1)

      # Wait for worker to shut down
      with_retries { assert_equal :shutdown, w.state }

      jobs = Workhorse::DbJob.order(:id).to_a
      assert_equal 'succeeded', jobs[0].state
      assert_equal 'waiting', jobs[1].state # Not picked up due to soft restart
    end
  ensure
    FileUtils.rm_f Workhorse::Worker.shutdown_file_for(Process.pid)
  end

  def test_soft_restart_double_signal
    with_worker(pool_size: 1, polling_interval: 0.2) do |w|
      Workhorse.enqueue BasicJob.new(sleep_time: 0.5)
      with_retries { assert_equal 'started', Workhorse::DbJob.first.state }

      # Send USR1 twice in rapid succession
      Process.kill 'USR1', Process.pid
      Process.kill 'USR1', Process.pid
      sleep 0.1

      assert_not w.accepting_jobs?

      # Worker should still shut down cleanly (no double-shutdown crash)
      with_retries { assert_equal :shutdown, w.state }
      assert File.exist?(Workhorse::Worker.shutdown_file_for(Process.pid))
    end
  ensure
    FileUtils.rm_f Workhorse::Worker.shutdown_file_for(Process.pid)
  end

  def test_soft_restart_ignored_during_shutdown
    with_worker(pool_size: 1, polling_interval: 0.2) do |w|
      Process.kill 'TERM', Process.pid
      with_retries { assert_equal :shutdown, w.state }

      # Sending USR1 during shutdown should not crash or create shutdown file
      Process.kill 'USR1', Process.pid
      sleep 0.1

      assert_not File.exist?(Workhorse::Worker.shutdown_file_for(Process.pid))
    end
  ensure
    FileUtils.rm_f Workhorse::Worker.shutdown_file_for(Process.pid)
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

  def test_queue_not_parallel
    Workhorse::DbJob.delete_all
    Workhorse.enqueue BasicJob.new(sleep_time: 0.2), queue: :q1
    Workhorse.enqueue BasicJob.new(sleep_time: 0.2), queue: :q1

    work 0.2, polling_interval: 0.2
    jobs = Workhorse::DbJob.all.to_a
    assert_equal 'succeeded', jobs[0].state
    assert_equal 'waiting',   jobs[1].state
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
    sleep 0.1
    Workhorse.enqueue BasicJob.new(some_param: 5, sleep_time: 0), priority: 3
    Workhorse.enqueue BasicJob.new(some_param: 3, sleep_time: 0), priority: 2
    Workhorse.enqueue BasicJob.new(some_param: 2, sleep_time: 0), priority: 1
    Workhorse.enqueue BasicJob.new(some_param: 1, sleep_time: 0), priority: 0

    BasicJob.results.clear
    work 1, pool_size: 1, polling_interval: 0.1
    assert_equal (1..6).to_a, BasicJob.results
  end

  def test_polling_interval
    assert Workhorse::Worker.new(polling_interval: 1)
    assert Workhorse::Worker.new(polling_interval: 1.1)
    err = assert_raises do
      Workhorse::Worker.new(polling_interval: 1.12)
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

  def test_controlled_shutdown
    Workhorse.max_worker_memory_mb = 100
    with_daemon do
      pid = with_retries do
        pid = daemon.workers.first.pid
        assert_process(pid)
        pid
      end

      10.times do
        Workhorse.enqueue BasicJob.new(sleep_time: 0.1)

        with_retries do
          assert_equal 'succeeded', Workhorse::DbJob.first.state
          Workhorse::DbJob.delete_all
        end
      end

      Workhorse.enqueue MemHungryJob.new

      with_retries do
        assert_equal 'succeeded', Workhorse::DbJob.first.state

        assert File.exist?("tmp/pids/workhorse.#{pid}.shutdown")
        assert_not_process pid
      end

      capture_stderr { daemon.watch }

      with_retries do
        assert_not File.exist?("tmp/pids/workhorse.#{pid}.shutdown")
      end
    end
  ensure
    Workhorse.max_worker_memory_mb = 0
  end

  def test_heartbeat_file_for
    assert_equal(
      Rails.root.join('tmp', 'pids', 'workhorse.3.heartbeat').to_s,
      Workhorse::Worker.heartbeat_file_for(3).to_s
    )
  end

  def test_heartbeat_noop_without_daemon_id
    ENV.delete('WORKHORSE_DAEMON_WORKER_ID')
    path = Workhorse::Worker.heartbeat_file_for('42')
    FileUtils.rm_f(path)

    Workhorse::Worker.new.heartbeat!

    assert_not File.exist?(path), 'heartbeat must not be touched without a daemon id'
  ensure
    FileUtils.rm_f(path)
  end

  def test_heartbeat_touches_file
    ENV['WORKHORSE_DAEMON_WORKER_ID'] = '42'
    path = Workhorse::Worker.heartbeat_file_for('42')
    FileUtils.rm_f(path)

    Workhorse::Worker.new.heartbeat!

    assert File.exist?(path), 'heartbeat file expected to be touched'
  ensure
    ENV.delete('WORKHORSE_DAEMON_WORKER_ID')
    FileUtils.rm_f(path)
  end

  def test_poll_touches_heartbeat
    ENV['WORKHORSE_DAEMON_WORKER_ID'] = '42'
    path = Workhorse::Worker.heartbeat_file_for('42')
    FileUtils.rm_f(path)

    with_worker(pool_size: 1, polling_interval: 0.1) do
      with_retries do
        assert File.exist?(path), 'expected a successful poll to touch the heartbeat file'
      end
    end
  ensure
    ENV.delete('WORKHORSE_DAEMON_WORKER_ID')
    FileUtils.rm_f(path)
  end

  private

  def assert_process(pid)
    assert process?(pid), "Process #{pid} expected to be running"
  end

  def assert_not_process(pid)
    assert_not process?(pid), "Process #{pid} expected to be stopped"
  end

  def enqueue_in_multiple_queues
    Workhorse.enqueue BasicJob.new(some_param: nil)
    Workhorse.enqueue BasicJob.new(some_param: :q1), queue: :q1
    Workhorse.enqueue BasicJob.new(some_param: :q2), queue: :q2
  end
end
