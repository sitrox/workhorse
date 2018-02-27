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
end
