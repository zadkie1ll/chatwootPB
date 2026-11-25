class Api::V1::Accounts::Conversations::DirectUploadsController < ActiveStorage::DirectUploadsController
  include DeviseTokenAuth::Concerns::SetUserByToken
  include RequestExceptionHandler
  include AccessTokenAuthHelper
  include EnsureCurrentAccountHelper
  include MfaEnforcementGuard

  skip_before_action :verify_authenticity_token, if: :authenticate_by_access_token?

  around_action :handle_with_exception
  before_action :authenticate_access_token!, if: :authenticate_by_access_token?
  before_action :validate_bot_access_token!, if: :authenticate_by_access_token?
  before_action :authenticate_user!, unless: :authenticate_by_access_token?
  before_action :current_account
  before_action :validate_token_api_access, if: :authenticate_by_access_token?
  before_action :check_account_mfa_enforcement, if: :authenticate_by_access_token?
  before_action :conversation

  def create
    if Corporate.enabled?
      raise ActiveRecord::RecordNotFound unless @conversation && Corporate.can_read?(Current.account, Current.user, @conversation)

      args = blob_args
      raise ActionController::BadRequest unless args[:byte_size].to_i.between?(1, Corporate::MessageSafety::MAX_BYTES)
      raise ActionController::BadRequest unless Corporate::MessageSafety::ALLOWED_TYPES.include?(args[:content_type])
    end

    return if @conversation.nil? || @current_account.nil?

    super
  end

  private

  def blob_args
    args = super
    return args unless Corporate.enabled?

    args.merge(metadata: {
                 corporate_account_id: @conversation.account_id,
                 corporate_contact_id: @conversation.contact_id,
                 corporate_user_id: Current.user.id
               })
  end

  def validate_token_api_access
    return if Current.account.api_and_webhooks_enabled?

    render json: { error: 'API access is not enabled for this account' }, status: :forbidden
  end

  def conversation
    @conversation ||= Current.account.conversations.find_by(display_id: params[:conversation_id])
  end
end
