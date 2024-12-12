#require 'minitest/autorun'
require 'active_record'
require 'active_job'
require 'pry'
require 'colorize'
require 'mysql2'
require 'benchmark'
require 'concurrent'
require 'jobs'

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

class WorkhorseTest < Testbench::Test
  abstract

  setup do
    remove_pids!
    Workhorse.silence_watcher = true
    Workhorse::DbJob.delete_all
  end

  protected

  attr_reader :daemon

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

    with_worker(options) do
      sleep time
    end
  end

  def work_until(max: 50, interval: 0.1, **options, &block)
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
    rescue Testbench::AssertionError
      fail if runs > max
      sleep interval
      runs += 1
    end
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
  adapter:  'mysql2',
  database: ENV.fetch('DB_NAME', nil) || 'workhorse',
  username: ENV.fetch('DB_USERNAME', nil) || 'root',
  password: ENV.fetch('DB_PASSWORD', nil) || '',
  host:     ENV.fetch('DB_HOST', nil) || '127.0.0.1',
  pool:     10
)

require 'db_schema'
require 'workhorse'
