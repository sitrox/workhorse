require 'test_helper'

class Workhorse::WorkerTest < ActiveSupport::TestCase
  def setup
    Workhorse::DbJob.delete_all
  end

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
end
