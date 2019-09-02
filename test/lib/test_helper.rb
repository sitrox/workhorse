require 'minitest/autorun'
require 'active_record'
require 'active_job'
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

  def mock_poll
    return Thread.new do
      Workhorse::Poller.new(MockWorker.new).send(:poll)
    end
  end

  def with_worker(options = {})
    w = Workhorse::Worker.new(options)
    w.start
    begin
      yield(w)
    ensure
      w.shutdown
    end
  end
end

class MockWorker
  def initialize(id: :dummy, idle: 5, queues: [])
    @id = id
    @idle = idle
    @queues = queues
  end

  attr_accessor :idle
  attr_accessor :id
  attr_accessor :queues

  def log(text, level = :info)
    puts "[#{level}] #{text}"
  end

  def perform(*args); end
end

ActiveRecord::Base.establish_connection adapter: 'mysql2', database: 'workhorse', username: 'travis', password: '', pool: 30, host: :localhost

require 'db_schema'
require 'workhorse'
