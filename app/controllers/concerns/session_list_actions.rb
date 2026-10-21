# typed: true
# frozen_string_literal: true

# M7: list your live sessions and end the others (ASVS 5.0 7.5.2; GitHub's
# per-session revoke; Stripe's "sign out all other sessions"). Shared by the
# merchant and operator consoles. Ending a session is sensitive, so both
# writes need a fresh step-up even though no permission names them (as
# me#password does). The current session is ended by sign-out, not here.
# The including controller provides current_user, current_session, audit!
# and idle_timeout (declared in sorbet/rbi/shims/concerns.rbi).
module SessionListActions
  extend ActiveSupport::Concern
  extend T::Sig
  extend T::Helpers

  requires_ancestor { ActionController::Base }

  included do
    before_action :require_step_up!, only: %i[destroy revoke_others]
    allow_unauthorized only: %i[index destroy revoke_others]
  end

  sig { void }
  def index
    rows = live_sessions.order(last_active_at: :desc)
    render json: { "data" => rows.map { |row| SessionSerializer.call(row, current: current_session) } }
  end

  sig { void }
  def destroy
    row = live_sessions.find(params[:id]) # someone else's session is a 404, like any other record
    if row.id == current_session.id
      raise ApiError.new(type: ApiError::Type::InvalidRequest, http_status: 409, code: "invalid_state", param: "id",
                         message: "Sign out to end this session")
    end

    row.revoke!
    audit!("session.revoked", target: row)
    head :no_content
  end

  sig { void }
  def revoke_others
    revoked = live_sessions.where.not(id: current_session.id)
                           .update_all(revoked_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    audit!("session.revoked_others", metadata: { "count" => revoked })
    SecurityMailer.sessions_revoked(current_user, count: revoked).deliver_later
    render json: { "revoked" => revoked }
  end

  private

  sig { returns(T.untyped) }
  def live_sessions = current_user.sessions.live(idle: idle_timeout)

  sig { void }
  def require_step_up! = (raise ApiError.step_up_required unless current_session.stepped_up?)
end
