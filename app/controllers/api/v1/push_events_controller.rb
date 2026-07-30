module Api
  module V1
    class PushEventsController < ApplicationController
      DEFAULT_PER_PAGE = 20
      MAX_PER_PAGE = 100

      def index
        page = positive_integer(params[:page], default: 1)
        per_page = [positive_integer(params[:per_page], default: DEFAULT_PER_PAGE), MAX_PER_PAGE].min
        scope = PushEvent.includes(:actor, :repository)
          .order(Arel.sql("github_created_at DESC NULLS LAST, id DESC"))
        scope = scope.where(github_event_id: params[:github_event_id]) if params[:github_event_id].present?
        total_count = scope.count
        push_events = scope.offset((page - 1) * per_page).limit(per_page)

        render json: {
          push_events: push_events.map { |event| PushEventSerializer.new(event).collection },
          pagination: {
            page:,
            per_page:,
            total_count:,
            total_pages: (total_count.to_f / per_page).ceil
          }
        }
      end

      def show
        push_event = PushEvent.includes(:actor, :repository).find(params[:id])

        render json: PushEventSerializer.new(push_event).detail
      rescue ActiveRecord::RecordNotFound
        render json: {error: "PushEvent not found"}, status: :not_found
      end

      private

      def positive_integer(value, default:)
        parsed = Integer(value, exception: false)
        parsed&.positive? ? parsed : default
      end
    end
  end
end
