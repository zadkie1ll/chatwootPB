class Api::V1::Accounts::BaseController < Api::BaseController
  include SwitchLocale
  include EnsureCurrentAccountHelper
  include MfaEnforcementGuard
  before_action :current_account
  before_action :corporate_access_guard
  after_action :issue_corporate_file_session
  before_action :validate_token_api_access, if: :authenticate_by_access_token?
  before_action :check_account_mfa_enforcement, if: :authenticate_by_access_token?
  around_action :switch_locale_using_account_locale

  private

  def issue_corporate_file_session
    return unless Corporate.enabled?

    response.headers['Cache-Control'] = 'no-store, private'
    Corporate::FileSession.issue(cookies, request, api_request: authenticate_by_access_token?)
  end

  def corporate_access_guard
    Corporate::RequestGuard.new(self).check! if Corporate.enabled?
  end

  def validate_token_api_access
    return if Current.account.api_and_webhooks_enabled?

    render json: { error: 'API access is not enabled for this account' }, status: :forbidden
  end
end
