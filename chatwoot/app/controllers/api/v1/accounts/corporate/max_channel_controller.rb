require 'net/http'

class Api::V1::Accounts::Corporate::MaxChannelController < Api::V1::Accounts::BaseController
  before_action :ensure_primary_account, :prevent_caching

  def show
    proxy('status')
  end

  def connect
    step = params.require(:step).to_s
    raise ActionController::BadRequest unless %w[start password cancel].include?(step)

    proxy(step, params.permit(:password, :attempt_id).to_h)
  end

  private

  def ensure_primary_account
    raise ActiveRecord::RecordNotFound unless ::Corporate.enabled? && Current.account.id.to_s == ENV.fetch('CORPORATE_ACCOUNT_ID')
  end

  def prevent_caching
    response.headers['Cache-Control'] = 'no-store'
    response.headers['Pragma'] = 'no-cache'
  end

  def proxy(step, data = nil)
    uri = URI.join(ENV.fetch('INTEGRATION_URL'), "/max-channel/#{step}/")
    request = data ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
    request['Authorization'] = "Bearer #{ENV.fetch('INTEGRATION_API_TOKEN')}"
    request['Content-Type'] = 'application/json'
    request.body = data.to_json if data
    result = Net::HTTP.start(uri.hostname, uri.port, open_timeout: 3, read_timeout: 12) { |http| http.request(request) }
    render json: JSON.parse(result.body), status: result.code.to_i
  rescue JSON::ParserError, SocketError, Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED
    render json: { error: 'channel_unavailable' }, status: :service_unavailable
  end
end
