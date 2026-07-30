class HealthController < ApplicationController
  def show
    ActiveRecord::Base.connection.select_value("SELECT 1")

    render json: { status: "ok", rails: "ok", database: "ok" }
  rescue ActiveRecord::ActiveRecordError => error
    Rails.logger.error(
      "health.database_unreachable error_class=#{error.class.name} message=#{error.message.inspect}"
    )

    render(
      json: { status: "unavailable", rails: "ok", database: "unreachable" },
      status: :service_unavailable
    )
  end
end
