ActiveRecord::Schema.define do
  self.verbose = false

  create_table :jobs, force: true do |t|
    t.string :state, null: false, default: 'waiting'
    t.string :queue, null: true
    t.text :handler, null: false, limit: 4_294_967_295

    t.string :locked_by
    t.datetime :locked_at

    t.datetime :started_at

    t.datetime :succeeded_at
    t.datetime :failed_at
    t.text :last_error, limit: 4_294_967_295

    t.integer :priority, null: false
    t.datetime :perform_at, null: true
    t.datetime :expires_at, null: true
    t.integer :max_lateness, null: true

    t.string :description, null: true

    t.timestamps null: false
  end

  add_index :jobs, :queue, length: 191
  add_index :jobs, %i[state perform_at], length: { state: 191 }, name: 'idx_jobs_state_perform_at'
  add_index :jobs, %i[state priority created_at], length: { state: 191 }, name: 'idx_jobs_state_prio_created'
  add_index :jobs, :perform_at

  create_table :workhorse_schedules, force: true do |t|
    t.string :key, null: false
    t.string :cron, null: false
    t.string :timezone, null: true
    t.boolean :enabled, null: false, default: true
    t.datetime :next_at, null: false
    t.datetime :last_enqueued_at, null: true
    t.datetime :last_occurrence, null: true
    t.integer :last_job_id, null: true

    t.timestamps null: false
  end

  add_index :workhorse_schedules, :key, unique: true, length: 191, name: 'idx_wh_schedules_key'
  add_index :workhorse_schedules, %i[enabled next_at], name: 'idx_wh_schedules_due'
end
