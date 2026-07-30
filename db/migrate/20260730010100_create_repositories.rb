class CreateRepositories < ActiveRecord::Migration[8.0]
  def change
    create_table :repositories do |t|
      t.bigint :github_id, null: false
      t.string :name
      t.string :api_url, null: false
      t.jsonb :raw_payload, null: false, default: {}
      t.datetime :enriched_at

      t.timestamps
    end

    add_index :repositories, :github_id, unique: true
    add_check_constraint(
      :repositories,
      "jsonb_typeof(raw_payload) = 'object'",
      name: "repositories_raw_payload_is_object"
    )
  end
end
