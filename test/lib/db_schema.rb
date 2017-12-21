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

    t.timestamps null: false
  end

  add_index :jobs, :queue, length: 191
  add_index :jobs, :state, length: 191
end
