class CreateCorporateAccess < ActiveRecord::Migration[8.0]
  def change
    create_table :corporate_memberships do |t|
      t.references :account, null: false, type: :integer, foreign_key: true
      t.references :user, null: false, type: :integer, foreign_key: true
      t.string :role, null: false
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :corporate_memberships, [:account_id, :user_id], unique: true

    create_table :customer_ownerships do |t|
      t.references :account, null: false, type: :integer, foreign_key: true
      t.references :contact, null: false, type: :integer, foreign_key: true
      t.references :owner, type: :integer, foreign_key: { to_table: :users }
      t.datetime :assigned_at
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :customer_ownerships, [:account_id, :contact_id], unique: true
    add_index :customer_ownerships, [:account_id, :owner_id, :contact_id], name: 'index_customer_ownerships_visibility'

    create_table :assignment_audits do |t|
      t.references :account, null: false, type: :integer, foreign_key: true
      t.references :contact, null: false, type: :integer, foreign_key: true
      t.references :actor, null: false, type: :integer, foreign_key: { to_table: :users }
      t.references :old_owner, type: :integer, foreign_key: { to_table: :users }
      t.references :new_owner, type: :integer, foreign_key: { to_table: :users }
      t.string :reason, null: false, limit: 500
      t.uuid :correlation_id, null: false
      t.integer :assignment_version, null: false
      t.timestamps
    end

    create_table :channel_identities do |t|
      t.references :account, null: false, type: :integer, foreign_key: true
      t.references :contact, null: false, type: :integer, foreign_key: true
      t.string :channel, null: false
      t.string :external_account_id, null: false, limit: 100
      t.string :external_user_id, null: false, limit: 100
      t.string :verified_phone
      t.timestamps
    end
    add_index :channel_identities, [:account_id, :channel, :external_account_id, :external_user_id],
              unique: true, name: 'index_channel_identities_external_key'
  end
end
