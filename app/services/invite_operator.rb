# typed: true
# frozen_string_literal: true

# Invites a PayHub operator and emails the enrolment link. Shared by
# InvitationsController and OperatorsController so both stay one-line thin.
module InviteOperator
  def self.call(email:, role:, invited_by:)
    unless Operator::ROLES.include?(role)
      raise ApiError.validation("role" => ["must be one of #{Operator::ROLES.join(', ')}"])
    end

    operator, token = Operator.invite!(email: email.to_s, role:, invited_by:)
    OperatorMailer.invite(operator, token).deliver_later
    operator
  rescue ActiveRecord::RecordNotUnique
    raise ApiError.validation("email" => ["already belongs to a PayHub user"])
  end
end
