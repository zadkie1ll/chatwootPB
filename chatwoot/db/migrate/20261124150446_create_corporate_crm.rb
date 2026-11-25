class CreateCorporateCrm < ActiveRecord::Migration[8.0]
  def change
    add_column :customer_ownerships, :shared_unidentified, :boolean, default: false, null: false
    add_index :customer_ownerships, [:account_id, :shared_unidentified, :contact_id], name: 'index_ownerships_shared_intake'
    add_column :assignment_audits, :source, :string, null: false, default: 'user'
    change_column_null :assignment_audits, :actor_id, true

    create_employees
    create_links
  end

  private

  def create_employees
    create_table :corporate_crm_employees do |t|
      t.references :account, null: false, type: :integer, foreign_key: true
      t.references :user, null: false, type: :integer, foreign_key: true
      t.string :external_user_id, null: false
      t.timestamps
    end
    add_index :corporate_crm_employees, [:account_id, :user_id], unique: true
    add_index :corporate_crm_employees, [:account_id, :external_user_id], unique: true, name: 'index_crm_employee_external'
  end

  def create_links
    create_table :corporate_crm_links do |t|
      t.references :account, null: false, type: :integer, foreign_key: true
      t.references :contact, null: false, type: :integer, foreign_key: true
      t.references :conversation, null: false, type: :integer, foreign_key: true
      t.references :actor, null: false, type: :integer, foreign_key: { to_table: :users }
      t.string :external_deal_id
      t.string :deal_title
      t.string :deal_url
      t.string :phone
      t.string :phone_source
      t.uuid :operation_id, null: false
      t.jsonb :sync_payload, null: false, default: {}
      t.string :sync_state, null: false, default: 'unlinked'
      t.string :error_code
      t.integer :assignment_version, null: false, default: 0
      t.datetime :lease_expires_at
      t.timestamps
    end
    index_links
  end

  def index_links
    add_index :corporate_crm_links, [:account_id, :contact_id], unique: true
    add_index :corporate_crm_links, [:account_id, :external_deal_id], unique: true, name: 'index_crm_deal_unique_customer'
    add_index :corporate_crm_links, :operation_id, unique: true
  end
end
