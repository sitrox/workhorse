require 'minitest/autorun'
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

class WorkhorseTest < ActiveSupport::TestCase
  def setup
    Workhorse::DbJob.delete_all
  end

  protected

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

  def with_retries(max = 50, interval: 0.1, &_block)
    runs = 0

    loop do
      return yield
    rescue Minitest::Assertion => e
      fail if runs > max
      sleep interval
      runs += 1
    end
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
