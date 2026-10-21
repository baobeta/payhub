# typed: true
# frozen_string_literal: true

module Dashboard
  module Api
    class InvitationsController < BaseController
      extend T::Sig

      ENROL_COOKIE = :_payhub_dashboard_enrol
      ENROL_TTL = 15.minutes

      skip_before_action :require_session!, only: %i[show accept]
      RESEND_LIMIT = 5 # per invite per 24 hours

      requires_permission "team.manage", only: %i[create resend]
      allow_unauthorized only: %i[show accept] # the token is the credential

      sig { void }
      def create
        role = params.require(:role).to_s
        unless MerchantUser::INVITABLE_ROLES.include?(role)
          raise ApiError.validation("role" => ["must be one of #{MerchantUser::INVITABLE_ROLES.join(', ')}"])
        end

        user, token = MerchantUser.invite!(merchant: live_merchant, email: params.require(:email).to_s, role:,
                                           invited_by: current_user)
        InvitationMailer.invite(user, token).deliver_later
        audit!("team.invited", target: user, metadata: { "email" => user.email, "role" => role })
        notify_owner("team.invited", detail: "#{user.email} as #{role}")
        render json: MemberSerializer.call(user), status: :created
      rescue ActiveRecord::RecordNotUnique
        raise ApiError.validation("email" => ["already belongs to a PayHub user"])
      end

      # M11: rotate the token and email it again. Only a pending invite: an
      # accepted or removed member is 409. The cap counts this invite's audit
      # rows (the DB stamps their time), under a row lock so two clicks
      # cannot both pass the fifth.
      sig { void }
      def resend
        user = live_merchant.merchant_users.find(params[:id])
        MerchantUser.transaction do
          user.lock!
          unless user.active? && user.pending_invitation?
            raise ApiError.new(type: ApiError::Type::InvalidRequest, http_status: 409, code: "invalid_state", param: "id",
                               message: "Only a pending invitation can be resent")
          end
          if resends_today(user) >= RESEND_LIMIT
            raise ApiError.new(type: ApiError::Type::RateLimit, http_status: 429, code: "resend_limit",
                               message: "This invitation was resent #{RESEND_LIMIT} times today. Try again tomorrow.")
          end

          token = user.rotate_invitation!
          audit!("team.invitation_resent", target: user, metadata: { "email" => user.email })
          # TC-M11-6: only a committed token is worth emailing; a rollback
          # would leave the link dead.
          ActiveRecord.after_all_transactions_commit { InvitationMailer.invite(user, token).deliver_later }
        end
        render json: MemberSerializer.call(user)
      end

      sig { void }
      def show
        user = invitation!
        render json: { "email" => user.email, "role" => user.role, "merchant_name" => T.must(user.merchant).name }
      end

      sig { void }
      def accept
        user = invitation!
        user.update!(name: params.require(:name).to_s, password: params.require(:password).to_s)
        cookies.encrypted[ENROL_COOKIE] = { value: { "id" => user.id, "exp" => ENROL_TTL.from_now.to_i },
                                            httponly: true, same_site: :strict, secure: Rails.env.production?,
                                            path: "/dashboard" }
        render json: { "next" => "enrol_otp" }
      end

      private

      sig { params(user: MerchantUser).returns(Integer) }
      def resends_today(user)
        AuditEvent.where(action: "team.invitation_resent", target_type: "MerchantUser", target_id: user.id)
                  .where("created_at > now() - interval '24 hours'").count
      end

      sig { returns(MerchantUser) }
      def invitation!
        MerchantUser.find_by_invitation_token(params[:token].to_s) || raise(ActiveRecord::RecordNotFound)
      end
    end
  end
end
