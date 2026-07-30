namespace :github do
  desc "Fetch and persist one page of GitHub public PushEvents"
  task ingest: :environment do
    result = Github::PushEventIngestor.new.call
    summary = result.to_summary.to_json

    puts "github ingestion completed #{summary}"
    next if result.success?

    warn "github ingestion failed error=#{result.error&.class&.name}"
    exit 1
  end
end
