class CreatePushEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :push_events do |t|
      t.string :github_event_id, null: false
      t.bigint :repository_github_id, null: false
      t.bigint :push_id, null: false
      t.string :ref, null: false
      t.string :head, null: false
      t.string :before, null: false
      t.datetime :github_created_at
      t.jsonb :raw_payload, null: false, default: {}
      t.references :actor, null: true, foreign_key: true
      t.references :repository, null: true, foreign_key: true

      t.timestamps
    end

    add_index :push_events, :github_event_id, unique: true
    add_index :push_events, :repository_github_id
    add_index :push_events, :push_id
    add_index :push_events, :github_created_at
    add_index :push_events, %i[repository_github_id github_created_at]
    add_check_constraint(
      :push_events,
      "jsonb_typeof(raw_payload) = 'object'",
      name: "push_events_raw_payload_is_object"
    )
  end
end
