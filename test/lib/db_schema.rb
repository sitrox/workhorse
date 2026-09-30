ActiveRecord::Schema.define do
  self.verbose = false

  # Prefix lengths for the indexes on string columns. MySQL needs them, as the
  # default `utf8mb4` charset puts a full `varchar(255)` past the maximum key
  # length; Oracle indexes the whole column and rejects the option.
  state_length = DB_ORACLE ? {} : { length: { state: 191 } }
  queue_length = DB_ORACLE ? {} : { length: 191 }
  key_length   = DB_ORACLE ? {} : { length: 191 }

  create_table :jobs, force: true do |t|
    t.string :state, null: false, default: 'waiting'
    t.string :queue, null: true

    # Binary rather than text, matching the generated migration: the handler is
    # a `Marshal.dump`, and a text column is character data - on Oracle a CLOB,
    # whose character set conversion would corrupt it.
    t.binary :handler, null: false, limit: 4_294_967_295

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

  # The index names are given explicitly because the ones Rails would derive
  # exceed the 30 characters Oracle allows before 12.2.
  add_index :jobs, :queue, **queue_length
  add_index :jobs, %i[state perform_at], name: 'idx_jobs_state_perform_at', **state_length
  add_index :jobs, %i[state priority created_at], name: 'idx_jobs_state_prio_created', **state_length
  add_index :jobs, %i[state expires_at], name: 'idx_jobs_state_expires_at', **state_length
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

  add_index :workhorse_schedules, :key, unique: true, name: 'idx_wh_schedules_key', **key_length
  add_index :workhorse_schedules, %i[enabled next_at], name: 'idx_wh_schedules_due'
end
