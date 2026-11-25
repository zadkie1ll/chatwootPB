require 'net/http'

class Api::V1::Accounts::Corporate::ChannelController < Api::V1::Accounts::BaseController
  def show
    proxy('status')
  end

  def connect
    step = params.require(:step).to_s
    raise ActionController::BadRequest unless %w[start code password].include?(step)

    proxy(step, params.permit(:api_id, :api_hash, :phone, :code, :password).to_h)
  end

  private

  def proxy(step, data = nil)
    uri = URI.join(ENV.fetch('INTEGRATION_URL'), "/channel/#{step}/")
    request = data ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
    request['Authorization'] = "Bearer #{ENV.fetch('INTEGRATION_API_TOKEN')}"
    request['Content-Type'] = 'application/json'
    request.body = data.to_json if data
    response = Net::HTTP.start(uri.hostname, uri.port, open_timeout: 3, read_timeout: 45) { |http| http.request(request) }
    render json: JSON.parse(response.body), status: response.code.to_i
  rescue JSON::ParserError, SocketError, Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED
    render json: { error: 'channel_unavailable' }, status: :service_unavailable
  end
end
