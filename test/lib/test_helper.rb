require 'minitest/autorun'
require 'active_record'
require 'mysql2'
require 'benchmark'

require 'basic_job'
ActiveRecord::Base.logger = Logger.new('debug.log')
ActiveRecord::Base.establish_connection adapter: 'mysql2', database: 'workhorse', username: 'travis', password: '', pool: 10, host: :localhost

require 'db_schema'
require 'workhorse'
