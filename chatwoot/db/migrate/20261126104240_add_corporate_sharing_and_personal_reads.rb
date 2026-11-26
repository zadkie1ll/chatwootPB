class AddCorporateSharingAndPersonalReads < ActiveRecord::Migration[8.0]
  def change
    add_column :corporate_memberships, :chats_shared_while_absent, :boolean, null: false, default: false
    create_table :corporate_conversation_shares do |t|
      t.references :account, null: false
      t.references :conversation, null: false, index: false
      t.references :shared_by, index: false
      t.timestamps
    end
    add_index :corporate_conversation_shares, [:account_id, :conversation_id], unique: true, name: 'corporate_share_identity'
    create_table :corporate_conversation_views do |t|
      t.references :account, null: false
      t.references :conversation, null: false
      t.references :user, null: false, index: false
      t.datetime :last_seen_at
      t.timestamps
    end
    add_index :corporate_conversation_views, [:account_id, :user_id, :conversation_id], unique: true, name: 'corporate_view_identity'
    create_table :corporate_sharing_audits do |t|
      t.references :account, null: false
      t.references :actor, index: false
      t.references :conversation, index: false
      t.references :subject_user, index: false
      t.string :action, null: false
      t.timestamps
    end
  end
end
