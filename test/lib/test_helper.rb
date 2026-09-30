require 'minitest/autorun'
require 'active_record'
require 'active_job'
require 'pry'
require 'benchmark'
require 'concurrent'
require 'jobs'

# The adapter to run the test suite against. Workhorse has to work with each of
# them, so each is covered by CI.
DB_ADAPTER = ENV.fetch('DB_ADAPTER', 'mysql2')

case DB_ADAPTER
when 'mysql2'
  require 'mysql2'
when 'trilogy'
  require 'trilogy'
when 'oracle_enhanced'
  require 'active_record/connection_adapters/oracle_enhanced_adapter'
else
  fail "Unsupported DB_ADAPTER #{DB_ADAPTER.inspect}, use 'mysql2', 'trilogy' or 'oracle_enhanced'."
end

# Whether the suite is running against Oracle. Used where the schema or an
# assertion cannot be written the same way for both families.
DB_ORACLE = DB_ADAPTER == 'oracle_enhanced'

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

  # Holds workhorse's global lock on a connection of its own, so that the code
  # under test sees it as taken by another worker.
  def with_global_lock_held
    connection = ActiveRecord::Base.connection_pool.checkout
    connection.select_value(acquire_global_lock_sql)
    yield
  ensure
    if connection
      connection.select_value(release_global_lock_sql)
      ActiveRecord::Base.connection_pool.checkin(connection)
    end
  end

  # Mirrors what Workhorse::Poller#with_global_lock emits, so that the lock the
  # code under test tries to take is the same one.
  def acquire_global_lock_sql
    return <<~SQL.strip if DB_ORACLE
      SELECT DBMS_LOCK.REQUEST(#{Workhorse::Poller::ORACLE_LOCK_HANDLE}, #{Workhorse::Poller::ORACLE_LOCK_MODE}, 1)
      FROM DUAL
    SQL

    return "SELECT GET_LOCK(CONCAT(DATABASE(), '_workhorse'), 1)"
  end

  def release_global_lock_sql
    return "SELECT DBMS_LOCK.RELEASE(#{Workhorse::Poller::ORACLE_LOCK_HANDLE}) FROM DUAL" if DB_ORACLE

    return "SELECT RELEASE_LOCK(CONCAT(DATABASE(), '_workhorse'))"
  end

  def clear_locks_and_db_threads!
    # Releases the locks held by *this* connection, which is all a fresh run
    # needs. It used to kill the queries of every other connection as well, to
    # clear one left behind by a crashed run - but KILL QUERY only aborts a
    # query and does not release a named lock, which is held by the connection
    # rather than the statement, so it never achieved that. What it did
    # achieve was killing queries belonging to the current run, surfacing as
    # spurious "Lost connection to server during query" failures. Should a
    # crashed run ever leave a lock behind, kill its *connection*, which does
    # release it.
    if DB_ORACLE
      # Oracle has no "release everything" call, but workhorse takes exactly
      # one handle. RELEASE reports a status rather than raising when the lock
      # is not held, so this needs no guard.
      Workhorse::DbJob.connection.execute(
        "SELECT DBMS_LOCK.RELEASE(#{Workhorse::Poller::ORACLE_LOCK_HANDLE}) FROM DUAL"
      )
    else
      Workhorse::DbJob.connection.execute('SELECT RELEASE_ALL_LOCKS()')
    end
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

# On Oracle the "database" is a service name rather than a schema, and the
# schema is the user the suite connects as.
ActiveRecord::Base.establish_connection(
  adapter:  DB_ADAPTER,
  database: ENV.fetch('DB_NAME', nil) || (DB_ORACLE ? 'FREEPDB1' : 'workhorse'),
  username: ENV.fetch('DB_USERNAME', nil) || (DB_ORACLE ? 'workhorse' : 'root'),
  password: ENV.fetch('DB_PASSWORD', nil) || (DB_ORACLE ? 'workhorse' : ''),
  host:     ENV.fetch('DB_HOST', nil) || '127.0.0.1',
  port:     ENV.fetch('DB_PORT', nil) || (DB_ORACLE ? 1521 : 3306),
  pool:     10
)

require 'db_schema'
require 'workhorse'
