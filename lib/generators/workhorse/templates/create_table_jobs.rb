class CreateTableJobs < ActiveRecord::Migration[7.1]
  def change
    create_table :jobs, force: true do |t|
      t.string :state, null: false, default: 'waiting'
      t.string :queue, null: true
      t.binary :handler, null: false, limit: 4_294_967_295

      t.string :locked_by
      t.datetime :locked_at

      t.datetime :started_at

      t.datetime :succeeded_at
      t.datetime :failed_at
      t.text :last_error, limit: 4_294_967_295

      t.integer :priority, null: false
      t.datetime :perform_at, null: true

      t.string :description, null: true

      t.timestamps null: false
    end

    if oracle?
      add_index :jobs, :queue
      add_index :jobs, :state
    else
      add_index :jobs, :queue, length: 191
      add_index :jobs, :state, length: 191
    end
    add_index :jobs, :perform_at
  end

  private

  def oracle?
    ActiveRecord::Base.connection.adapter_name == 'OracleEnhanced'
  end
end
