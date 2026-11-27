# A short-lived signed test token authenticates the service worker receipt.
# No session cookies, push endpoints or conversation data are returned.
class Api::V1::CorporatePushReceiptsController < ActionController::API
  def create
    return head :not_found unless Corporate::BrowserPush.enabled?

    accepted = Corporate::BrowserPushTest.receive(params.require(:token))
    head(accepted ? :no_content : :not_found)
  end
end
