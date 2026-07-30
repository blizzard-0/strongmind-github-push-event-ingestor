require "rails_helper"
require "rake"

RSpec.describe "github:ingest" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("github:ingest")
  end

  before do
    Rake::Task["github:ingest"].reenable
  end

  def ingestion_result(success:, error: nil)
    Github::IngestionResult.new(
      run_id: "run-task",
      fetched_count: 2,
      push_event_count: 1,
      non_push_count: 1,
      created_count: success ? 1 : 0,
      duplicate_count: 0,
      malformed_count: 0,
      failed_count: 0,
      actor_enriched_count: success ? 1 : 0,
      repository_enriched_count: success ? 1 : 0,
      enrichment_reused_count: 0,
      enrichment_skipped_count: 0,
      enrichment_failed_count: 0,
      rate_limited: false,
      rate_limit_remaining: nil,
      rate_limit_reset_at: nil,
      started_at: Time.utc(2026, 7, 30, 12),
      completed_at: Time.utc(2026, 7, 30, 12, 0, 1),
      elapsed_seconds: 1.0,
      success:,
      error:
    )
  end

  it "exits successfully and prints an understandable completion summary" do
    result = ingestion_result(success: true)
    allow(Github::PushEventIngestor).to receive(:new).and_return(instance_double(
      Github::PushEventIngestor,
      call: result
    ))

    expect { Rake::Task["github:ingest"].invoke }
      .to output(
        include(
          "github ingestion completed",
          '"run_id":"run-task"',
          '"created_count":1',
          '"success":true'
        )
      ).to_stdout
  end

  it "exits non-zero and reports an unrecoverable collection failure" do
    failure = Github::Errors::PermanentHttpFailure.new("unavailable", status: 403)
    result = ingestion_result(success: false, error: failure)
    allow(Github::PushEventIngestor).to receive(:new).and_return(instance_double(
      Github::PushEventIngestor,
      call: result
    ))

    expect { Rake::Task["github:ingest"].invoke }
      .to output(include("github ingestion completed", '"success":false')).to_stdout
      .and output(include("github ingestion failed", failure.class.name)).to_stderr
      .and raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
  end
end
