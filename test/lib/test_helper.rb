require 'minitest/autorun'
require 'active_record'
require 'active_job'
require 'pry'
require 'colorize'
require 'mysql2'
require 'benchmark'
require 'jobs'

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

  def with_worker(options = {})
    w = Workhorse::Worker.new(**options)
    w.start
    begin
      yield(w)
    ensure
      w.shutdown
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
