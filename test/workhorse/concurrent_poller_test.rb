require 'test_helper'

# This test tries to reproduce various issues that arise when multiple pollers
# poll concurrently. All of these problems seem to be fixed when setting
#
#   isolation: :read_committed
#
# in the transaction opened in Poller#poll. It is left to determine why this is
# needed and if this is the correct solution.
#
# See GitHub issue #21 for a complete description.
class Workhorse::ConcurrentPollerTest < WorkhorseTest
  # TODO: Remove this again
  def self.test_order
    :alpha
  end

  def test_0
    threads = []

    ActiveRecord::Base.transaction do
      Workhorse.enqueue BasicJob.new

      threads << mock_poll

      Workhorse.enqueue BasicJob.new

      threads << mock_poll

      Workhorse.enqueue BasicJob.new
    end
  ensure
    threads.each(&:join)
  end

  def test_1
    threads = []

    ActiveRecord::Base.transaction do
      Workhorse.enqueue BasicJob.new

      2.times do
        threads << mock_poll
      end
    end
  ensure
    threads.each(&:join)
  end

  def test_2
    threads = []

    ActiveRecord::Base.transaction do
      Workhorse.enqueue BasicJob.new

      2.times do
        threads << mock_poll
      end

      Workhorse.enqueue BasicJob.new
    end
  ensure
    threads.each(&:join)
  end

  # ActiveRecord::Deadlocked: Mysql2::Error: Deadlock found when trying to get
  # lock; try restarting transaction: UPDATE `jobs` SET `state` = 'locked',
  # `locked_by` = 'dummy', `locked_at` = '2019-08-12 15:14:03', `updated_at` =
  # '2019-08-12 15:14:03' WHERE `jobs`.`id` = 1
  def test_3
    threads = []

    ActiveRecord::Base.transaction do
      6.times do
        threads << mock_poll
      end

      23.times do |i|
        Workhorse.enqueue BasicJob.new, queue: i
        sleep 0.1
        threads << mock_poll
        sleep 0.1
      end

      # 6.times do
      #   threads << mock_poll
      # end
    end
  ensure
    threads.each(&:join)
  end

  # ActiveRecord::Deadlocked: Mysql2::Error: Deadlock found when trying to get
  # lock; try restarting transaction: INSERT INTO `jobs` (`queue`, `handler`,
  # `priority`, `perform_at`, `created_at`, `updated_at`) VALUES ('queue_49',
  # o:FailingTestJob\0', 0, '2019-08-12 16:10:02', '2019-08-12 16:10:02',
  # '2019-08-12 16:10:02')
  #
  # TODO: The exception also seems to happen when just polling and not
  # performing. This has yet to be reproduced using this test.
  def test_with_separate_tx
    threads = []

    10.times do
      threads << Thread.new do
        work 5, polling_interval: 0.1
      end
    end

    200.times do |i|
      # Exception only happens when jobs are enqueued in separate transactions
      Workhorse::DbJob.transaction do
        # Exception only happens when using separate queues or at least when
        # using multiple queues
        Workhorse.enqueue FailingTestJob.new, queue: "queue_#{i}"
      end
    end
  ensure
    threads.each(&:join)
  end

  def n_test_jonas
    threads = []

    w1 = Workhorse::Worker.new
    w2 = Workhorse::Worker.new

    3.times do
      threads << Thread.new { w1.poller.send(:poll) }
      threads << Thread.new { w2.poller.send(:poll) }
    end
    Workhorse.enqueue FailingTestJob.new, queue: SecureRandom.hex
    sleep 0.1
    3.times do
      threads << Thread.new { w2.poller.send(:poll) }
      threads << Thread.new { w1.poller.send(:poll) }
    end
    sleep 0.1
    Workhorse.enqueue FailingTestJob.new, queue: SecureRandom.hex



    # threads << Thread.new do
    #   work 5, polling_interval: 0.1
    # end
    #
    #
    # Workhorse.enqueue FailingTestJob.new, queue: "queue_1"
    #
    # threads << mock_poll
    # threads << mock_poll
    # threads << mock_poll
    # threads << mock_poll
    # threads << mock_poll
    #
    # Workhorse.enqueue FailingTestJob.new, queue: "queue_2"
    # threads << mock_poll
    # threads << mock_poll
    # Workhorse.enqueue FailingTestJob.new, queue: "queue_3"
    # threads << mock_poll
    # Workhorse.enqueue FailingTestJob.new, queue: "queue_4"
    # Workhorse.enqueue FailingTestJob.new, queue: "queue_5"
    # Workhorse.enqueue FailingTestJob.new, queue: "queue_5"
    #
    # threads << mock_poll
    #
    #
    # # 10.times do
    # #   threads << Thread.new do
    # #     work 5, polling_interval: 0.1
    # #   end
    # # end
    #
    # # 200.times do |i|
    # #   # Exception only happens when jobs are enqueued in separate transactions
    # #   Workhorse::DbJob.transaction do
    # #     # Exception only happens when using separate queues or at least when
    # #     # using multiple queues
    # #     Workhorse.enqueue FailingTestJob.new, queue: "queue_#{i}"
    # #   end
    # # end
  ensure
    threads.each(&:join)
  end
end
