require "rails_helper"

RSpec.describe "Persistence schema", type: :model do
  let(:connection) { ActiveRecord::Base.connection }

  it "defines all required non-null columns" do
    expected_columns = {
      "actors" => %w[github_id api_url raw_payload created_at updated_at],
      "repositories" => %w[github_id api_url raw_payload created_at updated_at],
      "push_events" => %w[
        github_event_id repository_github_id push_id ref head before raw_payload created_at updated_at
      ]
    }

    expected_columns.each do |table, column_names|
      columns = connection.columns(table).index_by(&:name)

      column_names.each do |column_name|
        expect(columns.fetch(column_name).null).to be(false), "#{table}.#{column_name} should be NOT NULL"
      end
    end
  end

  it "defines all required unique and query indexes" do
    expected_indexes = {
      "actors" => {
        ["github_id"] => true
      },
      "repositories" => {
        ["github_id"] => true
      },
      "push_events" => {
        ["github_event_id"] => true,
        ["repository_github_id"] => false,
        ["push_id"] => false,
        ["github_created_at"] => false,
        ["actor_id"] => false,
        ["repository_id"] => false,
        %w[repository_github_id github_created_at] => false
      }
    }

    expected_indexes.each do |table, expected|
      indexes = connection.indexes(table).index_by(&:columns)

      expected.each do |columns, unique|
        expect(indexes.fetch(columns).unique).to be(unique), "#{table}(#{columns.join(', ')}) index mismatch"
      end
    end
  end

  it "defines JSON object check constraints for every raw payload" do
    expected_constraints = {
      "actors" => "actors_raw_payload_is_object",
      "repositories" => "repositories_raw_payload_is_object",
      "push_events" => "push_events_raw_payload_is_object"
    }

    expected_constraints.each do |table, constraint_name|
      names = connection.check_constraints(table).map(&:name)

      expect(names).to include(constraint_name)
    end
  end

  it "defines actor and repository foreign keys on push events" do
    foreign_keys = connection.foreign_keys("push_events").index_by(&:to_table)

    expect(foreign_keys.fetch("actors").column).to eq("actor_id")
    expect(foreign_keys.fetch("repositories").column).to eq("repository_id")
  end
end
