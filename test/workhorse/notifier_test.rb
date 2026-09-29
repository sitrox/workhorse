require 'test_helper'
require 'tempfile'

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

  def test_notifier_can_be_set_to_nil
    Workhorse.notifier = :file
    Workhorse.notifier = nil

    # Asserted on the stored value: the reader falls back to a None of its
    # own, so it cannot tell a cleared notifier from an unset one.
    assert_instance_of Workhorse::Notifiers::None, Workhorse.instance_variable_get(:@notifier)
  end

  def test_the_file_notifier_defaults_below_the_rails_root
    assert_equal Rails.root.join('tmp', 'pids', 'workhorse.wake').to_s,
                 Workhorse::Notifiers::FileSystem.new.path
  end

  def test_the_redis_notifier_takes_the_configured_client
    redis = FakeRedis.new
    Workhorse.notification_redis = redis
    notifier = Workhorse::Notifiers::Redis.new

    notifier.notify(queue: :mailer)

    assert_equal [[Workhorse::Notifiers::Redis::DEFAULT_CHANNEL, 'mailer']], redis.published
  ensure
    Workhorse.notification_redis = nil
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

  def test_file_notifier_swallows_errors
    Tempfile.create('workhorse') do |file|
      # A regular file cannot be a directory, on any platform.
      notifier = Workhorse::Notifiers::FileSystem.new(path: File.join(file.path, 'workhorse.wake'))

      assert_nothing_raised { notifier.notify }
      assert_nil notifier.token
    end
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
          # Re-announced on every attempt: a single announcement whose poll
          # loses the global lock race would otherwise wait out the interval.
          Workhorse.notifier.notify
          assert_equal 1, Workhorse::DbJob.succeeded.count
        end
      end
    end

    assert_match(/Job was announced/, log)
  end

  def test_worker_without_a_notifier_waits_out_its_polling_interval
    capture_log do |logger|
      with_worker(polling_interval: 60, pool_size: 1, auto_terminate: false, logger: logger) do
        wait_for_first_poll(logger)

        Workhorse.enqueue BasicJob.new(sleep_time: 0)
        sleep 1

        assert_equal 1, Workhorse::DbJob.waiting.count
      end
    end
  end

  # Without this, marking every poll as brought forward - which would
  # silently disable the max_global_lock_fails alarm - goes undetected.
  def test_a_poll_that_waited_out_its_interval_is_not_marked_as_brought_forward
    poller = Workhorse::Worker.new(polling_interval: 0.2, pool_size: 1).poller
    poller.instance_variable_set(:@running, true)

    poller.send(:sleep)

    refute poller.instance_variable_get(:@poll_brought_forward),
           'a poll that waited out its interval is the scheduled one'
  end

  def test_redis_notifier_publishes_and_counts
    redis = FakeRedis.new
    notifier = Workhorse::Notifiers::Redis.new(client: redis, channel: 'test:jobs')

    notifier.notify(queue: :mailer)

    assert_equal [['test:jobs', 'mailer']], redis.published

    notifier.start
    begin
      redis.deliver('test:jobs', 'mailer')

      with_retries(50, interval: 0.02) do
        assert_equal 1, notifier.token
      end
    ensure
      notifier.stop
    end
  end

  # A reporter that is itself unreachable must not leave the process without
  # a subscriber for the rest of its life.
  def test_a_raising_exception_handler_does_not_kill_the_subscriber
    redis = FakeRedis.new(fail_subscribe: 1)
    notifier = Workhorse::Notifiers::Redis.new(client: redis, channel: 'test:jobs')

    with_exception_handler ->(_e) { fail 'reporter is down' } do
      notifier.start

      begin
        redis.deliver('test:jobs', 'mailer')

        with_retries(100, interval: 0.05) { assert_equal 1, notifier.token }
      ensure
        notifier.stop
      end
    end
  end

  # The once-only guard has to re-arm, or only the first outage in a
  # process's whole life is ever reported.
  def test_a_second_outage_is_reported_again
    redis = FakeRedis.new
    notifier = Workhorse::Notifiers::Redis.new(client: redis, channel: 'test:jobs')
    reported = []

    with_exception_handler ->(e) { reported << e.message } do
      notifier.start

      begin
        redis.drop!
        with_retries(100, interval: 0.05) { assert_equal 1, reported.size }

        redis.deliver('test:jobs', 'mailer')
        with_retries(100, interval: 0.05) { assert_equal 1, notifier.token }

        redis.drop!
        with_retries(100, interval: 0.05) { assert_equal 2, reported.size }
      ensure
        notifier.stop
      end
    end
  end

  def test_redis_notifier_swallows_publish_errors
    notifier = Workhorse::Notifiers::Redis.new(client: FakeRedis.new(fail_publish: true), channel: 'test:jobs')

    assert_nothing_raised { notifier.notify(queue: :mailer) }
  end

  # A broken notifier must cost latency, not the worker.
  def test_a_raising_notifier_does_not_take_the_worker_down
    Workhorse.notifier = RaisingNotifier.new

    with_worker(polling_interval: 0.2, pool_size: 1, auto_terminate: false) do |w|
      Workhorse.enqueue BasicJob.new(sleep_time: 0)

      with_retries(30) do
        assert_equal 1, Workhorse::DbJob.succeeded.count
      end

      assert_equal :running, w.state
    end
  end

  # Losing that race is expected when several workers are woken at once.
  def test_lock_failures_of_brought_forward_polls_are_not_counted
    Workhorse.notifier = file_notifier
    w = Workhorse::Worker.new(polling_interval: 60, pool_size: 1)
    poller = w.poller

    poller.instance_variable_set(:@running, true)
    poller.instance_variable_set(:@last_notification, Workhorse.notifier.token)

    Workhorse.notifier.notify
    poller.send(:sleep)

    assert poller.instance_variable_get(:@poll_brought_forward),
           'a poll following an announcement must be marked as brought forward'

    with_global_lock_held do
      poller.send(:poll)
    end

    assert_equal 0, poller.instance_variable_get(:@global_lock_fails)

    poller.instance_variable_set(:@poll_brought_forward, false)

    with_global_lock_held do
      poller.send(:poll)
    end

    assert_equal 1, poller.instance_variable_get(:@global_lock_fails)
  end

  def test_redis_notifier_requires_a_client
    Workhorse.notification_redis = nil
    notifier = Workhorse::Notifiers::Redis.new

    assert_raises RuntimeError do
      notifier.client
    end
  end

  # A worker with no free thread must leave the announcement pending, or the
  # job waits out the whole polling interval once capacity frees up.
  def test_an_announcement_arriving_while_busy_is_not_lost
    Workhorse.notifier = file_notifier

    with_worker(polling_interval: 60, pool_size: 1, auto_terminate: false) do
      blocker = Workhorse.enqueue BasicJob.new(sleep_time: 1)
      with_retries(60, interval: 0.05) { assert_equal 'started', blocker.reload.state }

      job = Workhorse.enqueue BasicJob.new(sleep_time: 0)

      with_retries(60, interval: 0.1) { assert_equal 'succeeded', job.reload.state }
    end
  end

  # Several workers in one process share one subscriber thread; the first to
  # stop must not take it away from the others.
  def test_the_redis_subscriber_survives_until_the_last_worker_stops
    redis = FakeRedis.new
    notifier = Workhorse::Notifiers::Redis.new(client: redis, channel: 'test:jobs')

    notifier.start
    notifier.start
    notifier.stop

    begin
      redis.deliver('test:jobs', 'mailer')

      with_retries(50, interval: 0.02) { assert_equal 1, notifier.token }
    ensure
      notifier.stop
    end
  end

  def test_the_file_notifier_follows_the_configured_path
    Workhorse.notifier = :file
    Workhorse.notification_path = wake_path

    assert_equal wake_path, Workhorse.notifier.path
  ensure
    Workhorse.notification_path = nil
  end

  def test_the_redis_notifier_follows_the_configured_channel
    Workhorse.notifier = :redis
    Workhorse.notification_channel = 'custom:jobs'

    assert_equal 'custom:jobs', Workhorse.notifier.channel
  ensure
    Workhorse.notification_channel = nil
  end

  # A subscribed connection cannot also publish, so the callable has to be
  # asked again for the subscriber rather than the publisher being reused.
  def test_the_redis_notifier_subscribes_on_a_client_of_its_own
    built = []
    notifier = Workhorse::Notifiers::Redis.new(
      client: -> { FakeRedis.new.tap { |r| built << r } }, channel: 'test:jobs'
    )

    notifier.notify(queue: :mailer)
    notifier.start

    begin
      with_retries(50, interval: 0.02) { assert_equal 2, built.size }

      refute_equal built.first.object_id, built.last.object_id
    ensure
      notifier.stop
    end
  end

  def test_the_redis_notifier_builds_a_client_from_a_callable
    built = []
    Workhorse.notification_redis = lambda do
      built << :built
      FakeRedis.new
    end
    notifier = Workhorse::Notifiers::Redis.new

    notifier.notify(queue: :mailer)

    assert_equal [:built], built
  ensure
    Workhorse.notification_redis = nil
  end

  private

  def with_exception_handler(handler)
    previous = Workhorse.on_exception
    Workhorse.on_exception = handler
    yield
  ensure
    Workhorse.on_exception = previous
  end

  def wake_path
    return File.join(Dir.tmpdir, 'workhorse_test.wake')
  end

  # Holds workhorse's global lock on a connection of its own, so that the code
  # under test sees it as taken by another worker.
  def with_global_lock_held
    connection = ActiveRecord::Base.connection_pool.checkout
    connection.select_value("SELECT GET_LOCK(CONCAT(DATABASE(), '_workhorse'), 1)")
    yield
  ensure
    if connection
      connection.select_value("SELECT RELEASE_LOCK(CONCAT(DATABASE(), '_workhorse'))")
      ActiveRecord::Base.connection_pool.checkin(connection)
    end
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

  # Notifier whose token cannot be read, standing in for a broken custom one.
  class RaisingNotifier < Workhorse::Notifiers::Base
    def token
      fail 'notifier is broken'
    end
  end

  # Minimal stand-in for a Redis client, so that the notifier's logic can be
  # tested without a server. `subscribe` blocks the way the real one does.
  class FakeRedis
    attr_reader :published

    def initialize(fail_publish: false, fail_subscribe: 0)
      @published = []
      @fail_publish = fail_publish
      @fail_subscribe = fail_subscribe
      @queue = Queue.new
    end

    def publish(channel, message)
      fail 'Connection refused' if @fail_publish

      @published << [channel, message]
    end

    def deliver(channel, message)
      @queue << [channel, message]
    end

    # Makes the current subscription fail, as a dropped connection would.
    def drop!
      @queue << :drop
    end

    def dup
      return self
    end

    def subscribe(_channel)
      if @fail_subscribe > 0
        @fail_subscribe -= 1
        fail 'Connection refused'
      end

      on = Callbacks.new
      yield on
      on.subscribed!

      loop do
        item = @queue.pop
        fail 'Connection reset' if item == :drop

        on.call(*item)
      end
    end

    class Callbacks
      def message(&block)
        @message = block
      end

      def subscribe(&block)
        @subscribe = block
      end

      def subscribed!
        @subscribe&.call
      end

      def call(channel, message)
        @message&.call(channel, message)
      end
    end
  end
end
