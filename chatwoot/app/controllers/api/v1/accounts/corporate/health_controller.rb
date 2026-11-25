require 'net/http'
require 'sidekiq/api'

class Api::V1::Accounts::Corporate::HealthController < Api::V1::Accounts::BaseController
  def show
    raise ActiveRecord::RecordNotFound unless ::Corporate.role(Current.account, Current.user) == 'supervisor'

    uri = URI.join(ENV.fetch('INTEGRATION_URL'), '/health/details/')
    request = Net::HTTP::Get.new(uri)
    request['Authorization'] = "Bearer #{ENV.fetch('INTEGRATION_API_TOKEN')}"
    response = Net::HTTP.start(uri.hostname, uri.port, open_timeout: 3, read_timeout: 8) { |http| http.request(request) }
    raise ::Corporate::ChannelUnavailable unless response.is_a?(Net::HTTPSuccess)

    render json: JSON.parse(response.body).merge(chatwoot_worker: worker_health)
  rescue JSON::ParserError, SocketError, Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, ::Corporate::ChannelUnavailable
    render json: { error: 'pipeline_unavailable' }, status: :service_unavailable
  end

  private

  def worker_health
    alive = Sidekiq::ProcessSet.new.any? { |process| Time.current.to_f - process['beat'].to_f < 120 }
    latency = [Sidekiq::Queue.new('critical').latency, Sidekiq::Queue.new('default').latency].max
    disk = ::Corporate::DiskHealth.status
    { healthy: alive && latency < 300 && disk[:healthy], queue_delay_seconds: latency, disk_available_bytes: disk[:available_bytes] }
  end
end
