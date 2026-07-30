class CreateActors < ActiveRecord::Migration[8.0]
  def change
    create_table :actors do |t|
      t.bigint :github_id, null: false
      t.string :login
      t.string :api_url, null: false
      t.jsonb :raw_payload, null: false, default: {}
      t.datetime :enriched_at

      t.timestamps
    end

    add_index :actors, :github_id, unique: true
    add_check_constraint(
      :actors,
      "jsonb_typeof(raw_payload) = 'object'",
      name: "actors_raw_payload_is_object"
    )
  end
end
