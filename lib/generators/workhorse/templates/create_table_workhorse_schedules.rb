class CreateTableWorkhorseSchedules < ActiveRecord::Migration[7.1]
  def change
    # Schedules are addressed by key; the job class and its options live in
    # the Workhorse.schedules definition rather than here.
    create_table :workhorse_schedules, force: true do |t|
      t.string :key, null: false

      # The cron expression and timezone are kept here so that a change to
      # either is recognised on reconciliation.
      t.string :cron, null: false
      t.string :timezone, null: true

      # Lets a schedule be switched off without a deployment.
      t.boolean :enabled, null: false, default: true

      # The next occurrence that has not been materialised yet.
      t.datetime :next_at, null: false

      t.datetime :last_enqueued_at, null: true
      t.datetime :last_occurrence, null: true
      t.integer :last_job_id, null: true

      t.timestamps null: false
    end

    # The index names are given explicitly because the ones Rails would derive
    # exceed the 30 characters Oracle allows before 12.2.
    if oracle?
      add_index :workhorse_schedules, :key, unique: true, name: 'idx_wh_schedules_key'
    else
      add_index :workhorse_schedules, :key, unique: true, length: 191, name: 'idx_wh_schedules_key'
    end

    add_index :workhorse_schedules, %i[enabled next_at], name: 'idx_wh_schedules_due'
  end

  private

  def oracle?
    ActiveRecord::Base.connection.adapter_name == 'OracleEnhanced'
  end
end
