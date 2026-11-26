require 'corporate_helper'

RSpec.describe Corporate::TelegramEmoji do
  let(:event) do
    { channel: 'telegram', text: 'A😀B', custom_emojis: [{ offset: 1, length: 2, document_id: '123' }],
      attachments: [{ emoji_document_id: '123' }] }.with_indifferent_access
  end

  it 'preserves UTF-16 offsets and exposes only media matching a validated emoji entity' do
    expect(described_class.entities(event)).to eq([{ 'offset' => 1, 'length' => 2, 'document_id' => '123' }])
    expect(described_class.attachment_metadata(event, 0)).to include(telegram_custom_emoji_id: '123', scan_state: 'clean')
    event[:attachments] = [{ emoji_document_id: '456' }]
    expect(described_class.attachment_metadata(event, 0)).not_to have_key(:telegram_custom_emoji_id)
  end

  it 'rejects out-of-range entities and leaves other channels unchanged' do
    event[:custom_emojis] = [{ offset: 100, length: 2, document_id: '123' }]
    expect(described_class.entities(event)).to be_empty
    expect(described_class.entities(event.merge(channel: 'max'))).to be_empty
  end
end
