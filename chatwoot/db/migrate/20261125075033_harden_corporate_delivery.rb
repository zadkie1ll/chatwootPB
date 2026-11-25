class HardenCorporateDelivery < ActiveRecord::Migration[8.0]
  def change
    add_column :corporate_deliveries, :action, :string, null: false, default: 'send'
    add_column :corporate_deliveries, :revision, :integer, null: false, default: 0
    add_column :corporate_deliveries, :requested_content, :text
    remove_index :corporate_deliveries, :message_id, unique: true, name: 'index_corporate_deliveries_unique_message'
    add_index :corporate_deliveries, [:message_id, :revision], unique: true
    add_column :corporate_crm_links, :entity_type, :string, null: false, default: 'deal'
    remove_index :corporate_crm_links, [:account_id, :external_deal_id], unique: true, name: 'index_crm_deal_unique_customer'
    add_index :corporate_crm_links, [:account_id, :entity_type, :external_deal_id], unique: true, name: 'index_crm_entity_unique_customer'
  end
end
