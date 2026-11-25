# Browser media cannot send dashboard token headers. Mint a narrowly scoped,
# HttpOnly encrypted media cookie after an authenticated account API request.
class Corporate::FileSession
  COOKIE = 'corporate_file_session'.freeze

  def self.issue(cookie_jar, request, api_request:)
    user = Current.user
    return unless Corporate.membership(Current.account, user)

    client = request.headers['client']
    return if !api_request && (client.blank? || user.tokens.to_h[client].blank?)

    cookie_jar.encrypted[COOKIE] = {
      value: { user_id: user.id, client: client, nonce: Digest::SHA256.hexdigest(user.access_token.token) }.to_json,
      httponly: true, same_site: :strict, secure: request.ssl?,
      expires: 1.hour.from_now, path: '/api/v1/corporate_files'
    }
  end

  def self.user(cookie_jar, request)
    authorization = request.authorization.to_s
    if authorization.start_with?('Bearer ')
      token = authorization.delete_prefix('Bearer ')
      return AccessToken.find_by(token: token)&.owner
    end
    encrypted = cookie_jar.encrypted[COOKIE]
    return if encrypted.blank?

    data = JSON.parse(encrypted)
    user = User.find_by(id: data['user_id'])
    return unless user&.access_token
    return unless ActiveSupport::SecurityUtils.secure_compare(Digest::SHA256.hexdigest(user.access_token.token), data['nonce'].to_s)

    if data['client'].present?
      session = user.tokens.to_h[data['client']]
      return unless session && session['expiry'].to_i > Time.current.to_i
    end
    user
  rescue JSON::ParserError
    nil
  end
end
