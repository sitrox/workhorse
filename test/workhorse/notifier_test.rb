require 'test_helper'

class Workhorse::NotifierTest < WorkhorseTest
  def setup
    super
    @notifier = Workhorse.notifier
    FileUtils.rm_f(wake_path)
  end

  def teardown
    Workhorse.notifier = @notifier
    FileUtils.rm_f(wake_path)
  end

  def test_default_notifier_is_none
    assert_instance_of Workhorse::Notifiers::None, Workhorse.notifier
    assert_nil Workhorse.notifier.token
  end

  def test_notifier_can_be_selected_by_symbol
    Workhorse.notifier = :file
    assert_instance_of Workhorse::Notifiers::FileSystem, Workhorse.notifier

    Workhorse.notifier = :redis
    assert_instance_of Workhorse::Notifiers::Redis, Workhorse.notifier

    Workhorse.notifier = :none
    assert_instance_of Workhorse::Notifiers::None, Workhorse.notifier
  end

  def test_unknown_notifier_is_rejected
    assert_raises ArgumentError do
      Workhorse.notifier = :carrier_pigeon
    end
  end

  def test_file_notifier_token_changes_on_notify
    notifier = file_notifier

    assert_nil notifier.token

    notifier.notify
    first = notifier.token

    refute_nil first
    assert_equal first, notifier.token

    sleep 0.01
    notifier.notify

    refute_equal first, notifier.token
  end

  def test_file_notifier_creates_its_directory
    path = File.join(Dir.mktmpdir, 'deeply', 'nested', 'workhorse.wake')
    notifier = Workhorse::Notifiers::FileSystem.new(path: path)

    notifier.notify

    assert File.exist?(path)
  end

  # A job must still be enqueued when it cannot be announced.
  def test_file_notifier_swallows_errors
    notifier = Workhorse::Notifiers::FileSystem.new(path: '/proc/nonexistent/workhorse.wake')

    assert_nothing_raised { notifier.notify }
    assert_nil notifier.token
  end

  def test_enqueueing_notifies
    Workhorse.notifier = file_notifier

    assert_nil Workhorse.notifier.token

    Workhorse.enqueue BasicJob.new(sleep_time: 0)

    refute_nil Workhorse.notifier.token
  end

  def test_enqueueing_does_not_notify_for_jobs_that_are_not_due
    Workhorse.notifier = file_notifier

    Workhorse.enqueue BasicJob.new(sleep_time: 0), perform_at: Time.now + 60

    assert_nil Workhorse.notifier.token
  end

  # Notifying before the commit would wake a worker that cannot see the row
  # yet, sending it back to sleep for a whole polling interval.
  def test_notification_happens_after_commit
    Workhorse.notifier = file_notifier

    ActiveRecord::Base.transaction do
      Workhorse.enqueue BasicJob.new(sleep_time: 0)

      assert_nil Workhorse.notifier.token, 'must not notify before the commit'
    end

    refute_nil Workhorse.notifier.token, 'must notify after the commit'
  end

  def test_worker_starts_an_announced_job_ahead_of_its_polling_interval
    Workhorse.notifier = file_notifier

    log = capture_log do |logger|
      with_worker(polling_interval: 60, pool_size: 1, auto_terminate: false, logger: logger) do
        wait_for_first_poll(logger)

        Workhorse.enqueue BasicJob.new(sleep_time: 0)

        with_retries(30) do
          assert_equal 1, Workhorse::DbJob.succeeded.count
        end
      end
    end

    assert_match(/Job was announced/, log)
  end

  def test_worker_without_a_notifier_waits_out_its_polling_interval
    with_worker(polling_interval: 60, pool_size: 1, auto_terminate: false) do
      sleep 0.3

      Workhorse.enqueue BasicJob.new(sleep_time: 0)
      sleep 1

      assert_equal 1, Workhorse::DbJob.waiting.count
    end
  end

  def test_redis_notifier_publishes_and_counts
    redis = FakeRedis.new
    notifier = Workhorse::Notifiers::Redis.new(client: redis, channel: 'test:jobs')

    notifier.notify(queue: :mailer)

    assert_equal [['test:jobs', 'mailer']], redis.published

    notifier.start
    begin
      with_retries(50, interval: 0.02) do
        assert_equal 0, notifier.token
      end

      redis.deliver('test:jobs', 'mailer')

      with_retries(50, interval: 0.02) do
        assert_equal 1, notifier.token
      end
    ensure
      notifier.stop
    end
  end

  def test_redis_notifier_swallows_publish_errors
    notifier = Workhorse::Notifiers::Redis.new(client: FakeRedis.new(fail_publish: true), channel: 'test:jobs')

    assert_nothing_raised { notifier.notify(queue: :mailer) }
  end

  def test_redis_notifier_requires_a_client
    Workhorse.notification_redis = nil
    notifier = Workhorse::Notifiers::Redis.new

    assert_raises RuntimeError do
      notifier.client
    end
  end

  private

  def wake_path
    return File.join(Dir.tmpdir, 'workhorse_test.wake')
  end

  def file_notifier
    return Workhorse::Notifiers::FileSystem.new(path: wake_path)
  end

  # Waits until the worker has completed the poll it performs on startup, so
  # that a job enqueued afterwards can only be found through a notification.
  def wait_for_first_poll(logger)
    with_retries(50, interval: 0.05) do
      assert_match(/Polling DB for jobs/, logger.instance_variable_get(:@logdev).dev.string)
    end
  end

  # Minimal stand-in for a Redis client, so that the notifier's logic can be
  # tested without a server. `subscribe` blocks the way the real one does.
  class FakeRedis
    attr_reader :published

    def initialize(fail_publish: false)
      @published = []
      @fail_publish = fail_publish
      @queue = Queue.new
    end

    def publish(channel, message)
      fail 'Connection refused' if @fail_publish

      @published << [channel, message]
    end

    def deliver(channel, message)
      @queue << [channel, message]
    end

    def dup
      return self
    end

    def subscribe(_channel)
      on = Callbacks.new
      yield on

      loop do
        channel, message = @queue.pop
        on.call(channel, message)
      end
    end

    class Callbacks
      def message(&block)
        @block = block
      end

      def call(channel, message)
        @block&.call(channel, message)
      end
    end
  end
end
