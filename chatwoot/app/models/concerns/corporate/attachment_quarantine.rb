module Corporate::AttachmentQuarantine
  extend ActiveSupport::Concern

  included do
    before_save :corporate_quarantine
    after_commit :corporate_scan, on: [:create, :update]
  end

  private

  def corporate_quarantine
    return unless Corporate.enabled? && file.attached? && meta.to_h['scan_state'].blank?

    self.meta = meta.to_h.merge('scan_state' => 'pending')
  end

  def corporate_scan
    return unless Corporate.enabled? && file.attached? && meta.to_h['scan_state'] == 'pending'

    Corporate::AttachmentScanJob.perform_later(id)
  end
end
