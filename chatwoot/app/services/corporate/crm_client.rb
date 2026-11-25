require 'net/http'

class Corporate::CrmClient
  class Error < StandardError
    attr_reader :code, :definitive

    def initialize(code, definitive: false)
      @code = code
      @definitive = definitive
      super(code)
    end
  end

  def call(path, payload = nil)
    raise Error, 'crm_not_configured' unless Corporate.crm_enabled?

    uri = URI.join(ENV.fetch('INTEGRATION_URL'), "/crm/#{path}/")
    request = payload ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
    execute(uri, request, payload)
  rescue JSON::ParserError, SocketError, Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED
    raise Error, 'crm_unavailable'
  end

  private

  def execute(uri, request, payload)
    request['Authorization'] = "Bearer #{ENV.fetch('INTEGRATION_API_TOKEN')}"
    request['Content-Type'] = 'application/json'
    request.body = payload.to_json if payload
    response = Net::HTTP.start(uri.hostname, uri.port, open_timeout: 3, read_timeout: 65) { |http| http.request(request) }
    data = JSON.parse(response.body)
    unless response.is_a?(Net::HTTPSuccess)
      definitive = [400, 401, 403, 404, 422].include?(response.code.to_i)
      raise Error.new(data.fetch('error', 'crm_unavailable'), definitive: definitive)
    end

    data
  end
end
