require 'test_helper'

class Workhorse::DaemonTest < WorkhorseTest
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

  private

  def assert_watch_output(*expected_lines)
    silence_watcher_was = Workhorse.silence_watcher
    Workhorse.silence_watcher = false
    assert_equal expected_lines, capture_stderr { daemon.watch }.lines.map(&:chomp)
  ensure
    Workhorse.silence_watcher = silence_watcher_was
  end
end
