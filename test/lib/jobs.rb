class BasicJob
  class_attribute :results
  self.results = Concurrent::Array.new

  def initialize(some_param: nil)
    @some_param = some_param
  end

  def perform
    results << @some_param
    sleep 1
  end
end

class DbConnectionTestJob
  class_attribute :db_connections
  self.db_connections = Concurrent::Array.new

  def perform
    db_connections << ActiveRecord::Base.connection.object_id
  end
end
