require 'net/http'

class Corporate::IntegrationClient
  def resolve(phone, channel: 'telegram')
    uri = URI.join(ENV.fetch('INTEGRATION_URL'), '/resolve/')
    request = Net::HTTP::Post.new(uri)
    request['Authorization'] = "Bearer #{ENV.fetch('INTEGRATION_API_TOKEN')}"
    request['Content-Type'] = 'application/json'
    recipient = phone.start_with?('@') ? { username: phone.delete_prefix('@') } : { phone: phone }
    request.body = recipient.merge(channel: channel).to_json
    response = Net::HTTP.start(uri.hostname, uri.port, open_timeout: 3, read_timeout: 15) { |http| http.request(request) }
    raise Corporate::ChannelUnavailable if response.code.to_i >= 500
    raise ArgumentError, 'Recipient unavailable' unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  end
end
