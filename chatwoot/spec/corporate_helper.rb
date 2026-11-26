ENV['RAILS_ENV'] = 'test'
require 'spec_helper'
require File.expand_path('../config/environment', __dir__)
abort 'Corporate specs require an isolated database' unless ActiveRecord::Base.connection_db_config.database.match?(/\Achatwoot(?:_[a-z0-9]+)*_spec\z/)
require 'rspec/rails'
require 'sidekiq/testing'
Sidekiq::Testing.fake!

module CorporateSpecData
  def staff(account, role)
    user = User.new(name: role, email: "#{SecureRandom.uuid}@example.invalid", password: 'LocalSpecPassword1!')
    user.skip_confirmation!
    user.save!
    AccountUser.create!(account: account, user: user, role: role == 'technical_admin' ? :administrator : :agent)
    CorporateMembership.create!(account: account, user: user, role: role)
    user
  end

  def client(account, owner: nil)
    contact = Contact.create!(account: account, name: 'Private synthetic client', identifier: SecureRandom.uuid)
    CustomerOwnership.create!(account: account, contact: contact, owner: owner)
    contact
  end

  def chat(account, contact)
    channel = Channel::Api.create!(account: account)
    inbox = Inbox.create!(account: account, channel: channel, name: 'Mock', enable_auto_assignment: false)
    contact_inbox = ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.uuid)
    Conversation.create!(account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox).reload
  end
end

RSpec.configure do |config|
  config.include CorporateSpecData
  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
  config.before { Current.reset }
  config.after { Current.reset }
end
