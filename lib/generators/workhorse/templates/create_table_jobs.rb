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

    # The index names are given explicitly because the ones Rails would derive
    # exceed the 30 characters Oracle allows before 12.2.
    if oracle?
      add_index :jobs, :queue
      add_index :jobs, %i[state perform_at], name: 'idx_jobs_state_perform_at'
      add_index :jobs, %i[state priority created_at], name: 'idx_jobs_state_prio_created'
    else
      add_index :jobs, :queue, length: 191
      add_index :jobs, %i[state perform_at], length: { state: 191 }, name: 'idx_jobs_state_perform_at'
      add_index :jobs, %i[state priority created_at], length: { state: 191 }, name: 'idx_jobs_state_prio_created'
    end
    add_index :jobs, :perform_at
  end

  private

  def oracle?
    ActiveRecord::Base.connection.adapter_name == 'OracleEnhanced'
  end
end
