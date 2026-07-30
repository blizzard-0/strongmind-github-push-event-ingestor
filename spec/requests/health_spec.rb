require "rails_helper"

RSpec.describe "GET /health", type: :request do
  it "reports that Rails and PostgreSQL are available" do
    get "/health"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq(
      "status" => "ok",
      "rails" => "ok",
      "database" => "ok"
    )
  end

  it "returns service unavailable when PostgreSQL cannot be reached" do
    allow(ActiveRecord::Base).to receive(:connection)
      .and_raise(ActiveRecord::ConnectionNotEstablished, "database unavailable")

    get "/health"

    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body).to eq(
      "status" => "unavailable",
      "rails" => "ok",
      "database" => "unreachable"
    )
  end
end
