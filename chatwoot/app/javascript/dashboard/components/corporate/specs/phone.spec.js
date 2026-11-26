import {
  formatRussianPhone,
  normalizeRussianPhone,
  normalizeTelegramUsername,
  formatRecipient,
} from '../phone';

describe('Recipient input normalization', () => {
  it.each([
    '89991234567',
    '8 (999) 123-45-67',
    '9991234567',
    '+7 (999) 123-45-67',
  ])('normalizes pasted %s', value => {
    expect(normalizeRussianPhone(value)).toBe('+79991234567');
    expect(formatRussianPhone(value)).toBe('+7 (999) 123-45-67');
  });
  it.each([
    '+7 (999) 123-45-6',
    '899912345678',
    '+15551234567',
    'номер 89991234567',
  ])('rejects invalid %s rather than looking up another number', value => {
    expect(normalizeRussianPhone(value)).toBeNull();
    expect(normalizeRussianPhone(formatRussianPhone(value))).toBeNull();
  });
  it('retains a Telegram username when typing and normalizes supported links', () => {
    expect(formatRecipient('@sample_user', 'telegram')).toBe('@sample_user');
    expect(normalizeTelegramUsername('https://t.me/sample_user')).toBe(
      '@sample_user'
    );
    expect(normalizeRussianPhone('@sample_user')).toBeNull();
  });
});
