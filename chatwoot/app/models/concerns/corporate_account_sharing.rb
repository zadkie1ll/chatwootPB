module CorporateAccountSharing
  extend ActiveSupport::Concern

  included do
    has_many :corporate_conversation_shares, dependent: :destroy
    has_many :corporate_conversation_views, dependent: :delete_all
    has_many :corporate_sharing_audits, dependent: :destroy
  end
end
