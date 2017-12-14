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

    w = Workhorse::Worker.new(options)
    w.start
    sleep time
    w.shutdown
  end
end

ActiveRecord::Base.logger = Logger.new('debug.log')
ActiveRecord::Base.establish_connection adapter: 'mysql2', database: 'workhorse', username: 'travis', password: '', pool: 10, host: :localhost

require 'db_schema'
require 'workhorse'
