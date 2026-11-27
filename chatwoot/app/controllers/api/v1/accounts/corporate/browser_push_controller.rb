class Api::V1::Accounts::Corporate::BrowserPushController < Api::V1::Accounts::BaseController
  rescue_from ::Corporate::BrowserPush::Error, with: :push_error

  def create
    record = service.register(params.require(:subscription).permit(:endpoint, keys: [:p256dh, :auth]).to_h)
    render json: service.status(record)
  end

  def status
    render json: service.status(service.find(params[:endpoint]))
  end

  def destroy
    service.find(params[:endpoint])&.destroy!
    head :no_content
  end

  def test
    ::Corporate::BrowserPushTest.new(subscription).send!
    render json: service.status(subscription.reload)
  end

  def confirm
    ::Corporate::BrowserPushTest.new(subscription).confirm!
    render json: service.status(subscription.reload)
  end

  private

  def service
    @service ||= ::Corporate::BrowserPush.new(account: Current.account, user: Current.user, origin: request.base_url,
                                              client: request.headers['client'])
  end

  def subscription
    @subscription ||= service.find(params[:endpoint]) || raise(ActiveRecord::RecordNotFound)
  end

  def push_error(error)
    render json: { error_code: error.message }, status: :unprocessable_entity
  end
end
