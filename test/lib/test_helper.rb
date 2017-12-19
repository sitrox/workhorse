require 'minitest/autorun'
require 'active_record'
require 'mysql2'
require 'benchmark'
require 'jobs'

class WorkhorseTest < ActiveSupport::TestCase
  def setup
    Workhorse::DbJob.delete_all
  end

  protected

  def work(time = 2, options = {})
    options[:pool_size] ||= 5
    options[:polling_interval] ||= 1

    with_worker(options) do
      sleep time
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

ActiveRecord::Base.establish_connection adapter: 'mysql2', database: 'workhorse', username: 'travis', password: '', pool: 10, host: :localhost

require 'db_schema'
require 'workhorse'
