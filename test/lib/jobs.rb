class BasicJob
  def perform
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
