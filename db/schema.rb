# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2026_07_30_010200) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "actors", force: :cascade do |t|
    t.bigint "github_id", null: false
    t.string "login"
    t.string "api_url", null: false
    t.jsonb "raw_payload", default: {}, null: false
    t.datetime "enriched_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["github_id"], name: "index_actors_on_github_id", unique: true
    t.check_constraint "jsonb_typeof(raw_payload) = 'object'::text", name: "actors_raw_payload_is_object"
  end

  create_table "push_events", force: :cascade do |t|
    t.string "github_event_id", null: false
    t.bigint "repository_github_id", null: false
    t.bigint "push_id", null: false
    t.string "ref", null: false
    t.string "head", null: false
    t.string "before", null: false
    t.datetime "github_created_at"
    t.jsonb "raw_payload", default: {}, null: false
    t.bigint "actor_id"
    t.bigint "repository_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["actor_id"], name: "index_push_events_on_actor_id"
    t.index ["github_created_at"], name: "index_push_events_on_github_created_at"
    t.index ["github_event_id"], name: "index_push_events_on_github_event_id", unique: true
    t.index ["push_id"], name: "index_push_events_on_push_id"
    t.index ["repository_github_id", "github_created_at"], name: "idx_on_repository_github_id_github_created_at_0f48420060"
    t.index ["repository_github_id"], name: "index_push_events_on_repository_github_id"
    t.index ["repository_id"], name: "index_push_events_on_repository_id"
    t.check_constraint "jsonb_typeof(raw_payload) = 'object'::text", name: "push_events_raw_payload_is_object"
  end

  create_table "repositories", force: :cascade do |t|
    t.bigint "github_id", null: false
    t.string "name"
    t.string "api_url", null: false
    t.jsonb "raw_payload", default: {}, null: false
    t.datetime "enriched_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["github_id"], name: "index_repositories_on_github_id", unique: true
    t.check_constraint "jsonb_typeof(raw_payload) = 'object'::text", name: "repositories_raw_payload_is_object"
  end

  add_foreign_key "push_events", "actors"
  add_foreign_key "push_events", "repositories"
end
