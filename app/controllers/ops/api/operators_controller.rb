# typed: true
# frozen_string_literal: true

module Ops
  module Api
    # O-13/O-14: operator management and the access-review export. An admin
    # can never change their own record (design §9), so a staff account cannot
    # escalate or erase itself.
    class OperatorsController < BaseController
      requires_permission "ops.operators.manage", only: %i[index create update destroy]
      requires_permission "ops.access_review.export", only: :access_review

      def index
        last = Session.where(principal_type: "Operator").group(:principal_id).maximum(:created_at)
        render json: { "data" => Operator.order(:created_at).map { |op| row(op, last[op.id]) } }
      end

      def create
        operator = InviteOperator.call(email: params.require(:email), role: params.require(:role).to_s,
                                       invited_by: current_user)
        audit!("operator.invited", target: operator, metadata: { "email" => operator.email, "role" => operator.role })
        render json: row(operator, nil), status: :created
      end

      def update
        operator = Operator.find(params[:id])
        raise self_change if operator.id == current_user.id

        from = operator.role
        operator.update!(role: params.require(:role).to_s)
        audit!("operator.role_changed", target: operator, metadata: { "from" => from, "to" => operator.role })
        render json: row(operator, nil)
      end

      def destroy
        operator = Operator.find(params[:id])
        raise self_change if operator.id == current_user.id

        operator.update!(disabled_at: Time.current)
        operator.sessions.where(revoked_at: nil).find_each(&:revoke!)
        audit!("operator.disabled", target: operator, metadata: { "email" => operator.email })
        render json: row(operator, nil)
      end

      # PCI 7.2.4 covers everyone with access to cardholder-data systems, so the
      # export lists staff AND merchant users.
      def access_review
        operator_last = Session.where(principal_type: "Operator").group(:principal_id).maximum(:created_at)
        member_last = Session.where(principal_type: "MerchantUser").group(:principal_id).maximum(:created_at)

        csv = CSV.generate do |out|
          out << %w[area merchant email role permissions last_sign_in_at created_at disabled_at]
          Operator.order(:created_at).each do |op|
            out << row_for("operator", "", op.email, op.role, op.created_at, op.disabled_at, operator_last[op.id])
          end
          MerchantUser.includes(:merchant).order(:created_at).each do |mu|
            out << row_for("merchant", T.must(mu.merchant).name, mu.email, mu.role, mu.created_at, mu.disabled_at,
                           member_last[mu.id])
          end
        end
        send_data csv, type: "text/csv", filename: "access-review-#{Time.current.utc.to_date}.csv"
      end

      private

      def row(operator, last_sign_in_at)
        { "id" => operator.id, "email" => operator.email, "role" => operator.role,
          "disabled_at" => operator.disabled_at&.utc&.iso8601(3),
          "last_sign_in_at" => last_sign_in_at&.utc&.iso8601(3) }
      end

      def row_for(area, merchant, email, role, created_at, disabled_at, last_sign_in_at)
        permissions = Permissions::CATALOGUE.keys.select { |p| Permissions.granted?(area.to_sym, role, p) }.join(" ")
        CsvSafe.row([area, merchant, email, role, permissions, last_sign_in_at&.utc&.iso8601,
                     created_at.utc.iso8601, disabled_at&.utc&.iso8601])
      end

      def self_change
        ApiError.new(type: ApiError::Type::InvalidRequest, http_status: 409, code: "refused",
                     message: "You cannot change your own operator record")
      end
    end
  end
end
