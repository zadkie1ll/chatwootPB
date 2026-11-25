class CreateCorporateDeliveryLedger < ActiveRecord::Migration[8.0]
  def change
    create_table :corporate_deliveries do |t|
      t.uuid :operation_id, null: false, default: -> { 'gen_random_uuid()' }
      t.references :account, type: :integer, null: false, foreign_key: true
      t.references :message, type: :integer, null: false, foreign_key: true
      t.references :actor, type: :integer, null: false, foreign_key: { to_table: :users }
      t.integer :assignment_version, null: false
      t.string :state, null: false, default: 'pending'
      t.string :dispatch_token
      t.datetime :lease_expires_at
      t.string :external_message_id
      t.string :error_code
      t.timestamps
    end
    add_index :corporate_deliveries, :operation_id, unique: true
    add_index :corporate_deliveries, :message_id, unique: true, name: 'index_corporate_deliveries_unique_message'
    add_index :corporate_deliveries, [:account_id, :state, :id]

    create_table :corporate_inbox_receipts do |t|
      t.references :account, type: :integer, null: false, foreign_key: true
      t.string :event_key, null: false, limit: 255
      t.references :message, type: :integer, foreign_key: true
      t.timestamps
    end
    add_index :corporate_inbox_receipts, [:account_id, :event_key], unique: true
  end
end
