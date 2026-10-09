# typed: true
# frozen_string_literal: true

module Ops
  module Api
    # O-15: the operator audit stream. Every row is visible, merchant and
    # operator alike; the filters hit the Phase 0 indexes.
    class AuditEventsController < BaseController
      requires_permission "ops.audit.read", only: :index

      ACTOR_TYPES = { "operator" => "Operator", "merchant" => "MerchantUser" }.freeze

      def index
        page = Cursor.paginate(filtered, after: params[:cursor].presence, limit: params[:limit]&.to_i)
        render json: { "object" => "list", "data" => page.records.map { |e| row(e) },
                       "has_more" => page.has_more, "next_cursor" => page.next_cursor }
      rescue Cursor::Invalid => e
        raise ApiError.invalid_request(e.message, param: "cursor", code: "invalid_cursor")
      end

      private

      def filtered
        scope = AuditEvent.all
        scope = scope.where(actor_type: actor_type) if params[:actor_type].present?
        if params[:action_prefix].present?
          scope = scope.where("action LIKE ?", "#{ActiveRecord::Base.sanitize_sql_like(params[:action_prefix].to_s)}%")
        end
        scope = scope.where(merchant_id: params[:merchant_id]) if params[:merchant_id].present?
        if params[:on_behalf_of_merchant_id].present?
          scope = scope.where(on_behalf_of_merchant_id: params[:on_behalf_of_merchant_id])
        end
        scope = scope.where(created_at: time_range) if params[:from].present? || params[:to].present?
        scope
      end

      def actor_type
        ACTOR_TYPES.fetch(params[:actor_type].to_s, params[:actor_type].to_s)
      end

      def time_range
        from = params[:from].present? ? Time.iso8601(params[:from].to_s) : Time.at(0)
        to = params[:to].present? ? Time.iso8601(params[:to].to_s) : Time.current
        from..to
      rescue ArgumentError
        raise ApiError.validation("from" => ["must be an ISO8601 timestamp"])
      end

      def row(event)
        { "id" => event.id, "at" => event.created_at.utc.iso8601(3), "actor_type" => event.actor_type,
          "actor" => event.actor_label, "action" => event.action, "result" => event.result,
          "merchant_id" => event.merchant_id, "on_behalf_of_merchant_id" => event.on_behalf_of_merchant_id,
          "target_type" => event.target_type, "target_id" => event.target_id, "ip" => event.ip,
          "metadata" => event.metadata }
      end
    end
  end
end
