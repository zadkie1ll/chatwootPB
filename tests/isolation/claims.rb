require 'json'
raise 'Synthetic lab only' unless ActiveRecord::Base.connection_db_config.database == 'chatwoot_lab' && Corporate.enabled?
fixture = JSON.parse(File.read('/lab-secrets/baseline.json'))
account_id = fixture.fetch('account_id')
user_ids = %w[A B].map { |label| fixture.fetch('users').fetch(label).fetch('id') }
begin
contact = Contact.create!(account_id: account_id, name: 'Synthetic concurrent claim', identifier: "stage2-race-#{SecureRandom.uuid}")
contact_id = contact.id
ActiveRecord::Base.connection_pool.disconnect!
barrier_reader, barrier_writer = IO.pipe
children = user_ids.map do |user_id|
  reader, writer = IO.pipe
  pid = fork do
    reader.close
    barrier_writer.close
    barrier_reader.read(1)
    begin
      account = Account.find(account_id)
      actor = User.find(user_id)
      Corporate::OwnershipService.new(account: account, actor: actor).claim(contact: Contact.find(contact_id))
      writer.write('claimed')
    rescue ActiveRecord::RecordNotFound
      writer.write('denied')
    rescue StandardError => e
      writer.write(e.class.name)
    ensure
      writer.close
    end
    exit! 0
  end
  writer.close
  [pid, reader]
end
barrier_reader.close
barrier_writer.write('xx')
barrier_writer.close
outcomes = children.map { |pid, reader| value = reader.read; reader.close; Process.wait(pid); value }
ownerships = CustomerOwnership.where(account_id: account_id, contact_id: contact_id)
audit = AssignmentAudit.where(account_id: account_id, contact_id: contact_id)
passed = outcomes.sort == %w[claimed denied] && ownerships.count == 1 && user_ids.include?(ownerships.first.owner_id) && audit.count == 1
puts JSON.generate({ kind: 'corporate-concurrent-claim', outcomes: outcomes.sort, ownership_rows: ownerships.count, audit_rows: audit.count, passed: passed })
raise 'Concurrent claim invariant failed' unless passed
ensure
  if contact_id
    AssignmentAudit.where(contact_id: contact_id).delete_all
    CustomerOwnership.where(contact_id: contact_id).delete_all
    Contact.where(id: contact_id).destroy_all
  end
end
