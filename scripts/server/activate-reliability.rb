raise 'Corporate CE required' unless Corporate.enabled? && !ChatwootApp.enterprise?
account = Account.find(ENV.fetch('CORPORATE_ACCOUNT_ID'))
files = 0
Attachment.where(account: account).find_each do |attachment|
  next unless attachment.file.attached?
  next if %w[clean rejected].include?(attachment.meta.to_h['scan_state'])

  Corporate::AttachmentScanJob.perform_later(attachment.id)
  files += 1
end
links = 0
if Corporate.crm_enabled?(account)
  CorporateCrmLink.where(account: account, sync_state: 'applied').find_each do |link|
    account.with_lock do
      link.reload
      next unless link.sync_state == 'applied'

      ownership = CustomerOwnership.find_by!(account: account, contact_id: link.contact_id)
      Corporate::CrmLinkService.queue!(link, ownership: ownership, actor: link.actor, assign_owner: false)
      links += 1
    end
  end
end
puts JSON.generate({ existing_attachments_queued_for_verification: files, existing_crm_links_queued_for_url_refresh: links,
                     crm_responsibles_not_overwritten_by_activation: true })
