# Predictable URLs grant no access: every read requires an authenticated principal.
class Corporate::FileAccess
  def self.url(attachment)
    return '' unless attachment.meta.to_h['scan_state'] == 'clean'
    return '' unless Corporate.can_read?(attachment.account, Current.user, attachment.message)

    "#{ENV.fetch('FRONTEND_URL')}/api/v1/corporate_files/#{attachment.id}"
  end
end
