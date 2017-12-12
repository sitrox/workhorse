module Workhorse
  class InstallGenerator < Rails::Generators::Base
    include Rails::Generators::Migration

    source_root File.expand_path('../templates', __FILE__)

    def self.next_migration_number(_dir)
      Time.now.utc.strftime('%Y%m%d%H%M%S')
    end

    def install_migration
      migration_template 'create_table_jobs.rb', 'db/migrate/create_table_jobs.rb'
    end

    def install_daemon_script
      template 'bin/workhorse.rb'
    end
  end
end
