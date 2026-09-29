require 'test_helper'

class Workhorse::DaemonTest < WorkhorseTest
  # A worker that ignores TERM used to leave `stop` - and whatever is waiting
  # on it, a deployment usually - looping forever.
  def test_stop_kills_a_worker_that_ignores_term
    previous = Workhorse.shutdown_timeout
    Workhorse.shutdown_timeout = 2

    daemon = Workhorse::Daemon.new(pidfile: 'tmp/pids/stubborn%s.pid') do |d|
      d.worker 'Stubborn' do
        Signal.trap('TERM') { nil }
        Signal.trap('INT') { nil }
        # A bare sleep returns as soon as a handler runs, so it has to be
        # re-entered to actually ignore the signal.
        loop { sleep 1 }
      end
    end

    daemon.start(quiet: true)
    pid = daemon.workers.first.pid

    with_retries(50, interval: 0.1) { assert process?(pid) }

    capture_stderr do
      Timeout.timeout(30) { daemon.stop(quiet: true) }
    end

    wait_for_process_exit(pid)

    refute process?(pid)
  ensure
    Workhorse.shutdown_timeout = previous
    FileUtils.rm_f Dir['tmp/pids/stubborn*.pid']
  end

  def setup
    remove_pids!
  end

  def test_watch_all_ok
    with_daemon 2 do
      assert_watch_output
    end
  end

  def test_watch_starting_stale_pid
    with_daemon 2 do
      # Kill first worker
      Process.kill 'KILL', daemon.workers.first.pid

      # Short sleep to let the `KILL` propagate
      sleep 0.2

      # Watch
      assert_watch_output(
        'Worker #1 (Test Worker 0): Starting (stale pid file)',
        "Worker #2 (Test Worker 1): Already started (PID #{daemon.workers.second.pid})"
      )
    end
  end

  def test_watch_starting_missing_pid
    with_daemon 2 do
      # Kill first worker
      kill daemon.workers.first.pid
      FileUtils.rm 'tmp/pids/test1.pid'

      # Watch
      assert_watch_output(
        'Worker #1 (Test Worker 0): Starting',
        "Worker #2 (Test Worker 1): Already started (PID #{daemon.workers.second.pid})"
      )
    end
  end

  def test_watch_controlled_shutdown
    with_daemon 2 do
      # Kill first worker
      kill daemon.workers.first.pid
      FileUtils.touch "tmp/pids/workhorse.#{daemon.workers.first.pid}.shutdown"

      # Watch
      assert_watch_output
    end

    assert_not File.exist?("tmp/pids/workhorse.#{daemon.workers.first.pid}.shutdown")
  end

  def test_watch_mixed
    # Worker 0: Kill, remove PID
    # Worker 1: Kill, keep PID
    # Worker 2: Keep
    # Worker 3: Controlled shutdown
    with_daemon 4 do
      # Worker 0: Kill, remove PID
      kill daemon.workers[0].pid
      FileUtils.rm 'tmp/pids/test1.pid'

      # Worker 1: Kill, keep PID
      kill daemon.workers[1].pid

      # Worker 3: Controlled shutdown
      kill daemon.workers[3].pid
      FileUtils.touch "tmp/pids/workhorse.#{daemon.workers.first.pid}.shutdown"

      # Watch
      assert_watch_output(
        'Worker #1 (Test Worker 0): Starting',
        'Worker #2 (Test Worker 1): Starting (stale pid file)',
        "Worker #3 (Test Worker 2): Already started (PID #{daemon.workers[2].pid})",
        'Worker #4 (Test Worker 3): Starting (stale pid file)'
      )
    end

    assert_not File.exist?("tmp/pids/workhorse.#{daemon.workers.first.pid}.shutdown")
  end

  def test_soft_restart_returns_immediately
    with_daemon 2 do
      # Give workers time to fully start and register signal handlers
      sleep 0.5

      result = nil
      elapsed = Benchmark.measure { result = daemon.soft_restart }.real
      assert_equal 0, result
      assert elapsed < 0.1, "soft_restart should return immediately, took #{elapsed}s"

      # Wait for shutdown to complete before test cleanup
      daemon.workers.each do |w|
        with_retries(150) { assert_not process?(w.pid) }
      end
    end
  end

  def test_soft_restart_creates_shutdown_files_and_watch_restarts
    with_daemon 2 do
      old_pids = daemon.workers.map(&:pid)

      # Give workers time to fully start and register signal handlers
      sleep 0.5

      daemon.soft_restart

      # Wait for each worker to create shutdown file and exit
      old_pids.each do |pid|
        with_retries(100) do
          assert File.exist?("tmp/pids/workhorse.#{pid}.shutdown"),
                 "Shutdown file for PID #{pid} should exist. Files: #{Dir['tmp/pids/*'].join(', ')}"
        end
        with_retries(100) do
          assert_not process?(pid), "Process #{pid} should have exited"
        end
      end

      # Watch should restart them and clean up shutdown files
      capture_stderr { daemon.watch }

      with_retries do
        old_pids.each do |pid|
          assert_not File.exist?("tmp/pids/workhorse.#{pid}.shutdown"),
                     "Shutdown file for PID #{pid} should be cleaned up"
        end

        # Workers should be running again with different PIDs
        assert_equal 0, daemon.status(quiet: true)
        new_pids = daemon.workers.map(&:pid)
        assert_empty(old_pids & new_pids, 'New workers should have different PIDs than old workers')
      end
    end
  end

  def test_soft_restart_with_dead_worker
    with_daemon 2 do
      # Give workers time to fully start and register signal handlers
      sleep 0.5

      # Kill first worker so it's dead when we try to soft_restart
      Process.kill 'KILL', daemon.workers.first.pid
      with_retries { assert_not process?(daemon.workers.first.pid) }

      # soft_restart returns 0 because read_pid detects the dead worker as
      # inactive and skips it (the ESRCH rescue is never reached)
      result = daemon.soft_restart
      assert_equal 0, result

      # Second worker should still soft-restart successfully
      with_retries(150) { assert_not process?(daemon.workers.second.pid) }
    end
  end

  private

  def assert_watch_output(*expected_lines)
    silence_watcher_was = Workhorse.silence_watcher
    Workhorse.silence_watcher = false
    assert_equal expected_lines, capture_stderr { daemon.watch }.lines.map(&:chomp)
  ensure
    Workhorse.silence_watcher = silence_watcher_was
  end
end
