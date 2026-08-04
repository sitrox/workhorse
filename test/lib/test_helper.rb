require 'minitest/autorun'
require 'active_record'
require 'active_job'
require 'pry'
require 'benchmark'
require 'concurrent'
require 'jobs'

# The adapter to run the test suite against. Both MySQL / MariaDB adapters are
# supported, as workhorse has to work with either of them.
DB_ADAPTER = ENV.fetch('DB_ADAPTER', 'mysql2')

case DB_ADAPTER
when 'mysql2'
  require 'mysql2'
when 'trilogy'
  require 'trilogy'
else
  fail "Unsupported DB_ADAPTER #{DB_ADAPTER.inspect}, use 'mysql2' or 'trilogy'."
end

class MockRailsEnv < String
  def production?
    self == 'production'
  end

  def test?
    self == 'test'
  end

  def development?
    self == 'development'
  end
end

class Rails
  def self.root
    Pathname.new(File.expand_path(File.join(File.dirname(__FILE__), '../../')))
  end

  def self.env
    MockRailsEnv.new('production')
  end
end

class WorkhorseTest < ActiveSupport::TestCase
  def setup
    remove_pids!
    clear_locks_and_db_threads!
    Workhorse.silence_watcher = true
    Workhorse::DbJob.delete_all
  end

  protected

  attr_reader :daemon

  # Temporarily replaces the method `method` on `object` with one that always
  # returns `value`, for the duration of the given block.
  #
  # This is implemented by hand rather than using minitest's `stub`, as
  # `minitest/mock` is not available in every minitest version this gem is
  # tested against.
  def with_return_value(object, method, value)
    object.define_singleton_method(method) { |*, **| value }
    yield
  ensure
    object.singleton_class.send(:remove_method, method)
  end

  def clear_locks_and_db_threads!
    Workhorse::DbJob.connection.execute('SELECT RELEASE_ALL_LOCKS()')

    # Use `select_values` rather than `execute`, as the latter does not return a
    # result set on every adapter.
    pids = Workhorse::DbJob.connection.select_values(<<~SQL.squish)
      SELECT ID FROM INFORMATION_SCHEMA.PROCESSLIST WHERE ID != CONNECTION_ID()
    SQL

    begin
      pids.each { |pid| Workhorse::DbJob.connection.execute("KILL QUERY #{pid}") }
    rescue ActiveRecord::StatementInvalid
      # Ignore
    end

    Workhorse::DbJob.connection.execute('SELECT RELEASE_ALL_LOCKS()')
  end

  def remove_pids!
    Dir[Rails.root.join('tmp', 'pids', '*')].each do |file|
      FileUtils.rm file
    end
  end

  def kill(pid)
    signals = %w[TERM INT]

    loop do
      begin
        signals.each { |signal| Process.kill(signal, pid) }
      rescue Errno::ESRCH
        break
      end

      sleep 0.5
    end
  end

  def wait_for_process_exit(pid, timeout: 5)
    deadline = Time.now + timeout
    loop do
      Process.getpgid(pid)
      if Time.now > deadline
        fail "Process #{pid} did not exit within #{timeout} seconds"
      end

      sleep 0.01
      Thread.pass # Give detach threads a chance to reap zombies
    rescue Errno::ESRCH
      return # Process is fully gone from process table
    end
  end

  def capture_log(level: :debug)
    io = StringIO.new
    logger = Logger.new(io, level: level)
    yield logger
    io.close
    return io.string
  end

  def work(time = 2, options = {})
    options[:pool_size] ||= 5
    options[:polling_interval] ||= 1
    options[:auto_terminate] = options.fetch(:auto_terminate, false)

    with_worker(options) do
      sleep time
    end
  end

  def work_until(max: 50, interval: 0.1, **options, &block)
    options[:auto_terminate] = options.fetch(:auto_terminate, false)

    w = Workhorse::Worker.new(**options)
    w.start
    return with_retries(max, interval: interval, &block)
  ensure
    w.shutdown
  end

  def with_worker(options = {})
    w = Workhorse::Worker.new(**options)
    w.start
    begin
      yield(w)
    ensure
      w.shutdown
    end
  end

  def with_daemon(workers = 1, &_block)
    @daemon = Workhorse::Daemon.new(pidfile: 'tmp/pids/test%s.pid') do |d|
      workers.times do |i|
        d.worker "Test Worker #{i}" do
          Workhorse::Worker.start_and_wait(
            pool_size:        1,
            polling_interval: 0.1
          )
        end
      end
    end
    daemon.start(quiet: true)
    yield @daemon
  ensure
    daemon.stop(quiet: true)
  end

  def with_retries(max = 50, interval: 0.1, &_block)
    runs = 0

    loop do
      return yield
    rescue Minitest::Assertion
      fail if runs > max
      sleep interval
      runs += 1
    end
  end

  def process?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::EPERM, Errno::ESRCH
    false
  end

  def capture_stderr
    old = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = old
  end
end

ActiveRecord::Base.establish_connection(
  adapter:  DB_ADAPTER,
  database: ENV.fetch('DB_NAME', nil) || 'workhorse',
  username: ENV.fetch('DB_USERNAME', nil) || 'root',
  password: ENV.fetch('DB_PASSWORD', nil) || '',
  host:     ENV.fetch('DB_HOST', nil) || '127.0.0.1',
  port:     ENV.fetch('DB_PORT', nil) || 3306,
  pool:     10
)

require 'db_schema'
require 'workhorse'
