export function normalizeRussianPhone(value) {
  const text = String(value).trim();
  if (!/^\+?[\d\s().-]+$/.test(text) || /^\+[^78]/.test(text)) return null;
  let digits = text.replace(/\D/g, '');
  if (digits.length === 10 && !text.startsWith('+')) digits = `7${digits}`;
  if (digits.length === 11 && digits.startsWith('8'))
    digits = `7${digits.slice(1)}`;
  return /^7\d{10}$/.test(digits) ? `+${digits}` : null;
}

export function normalizeTelegramUsername(value) {
  const match = String(value)
    .trim()
    .match(
      /^(?:@|(?:https?:\/\/)?(?:t\.me|telegram\.me)\/)?([a-zA-Z][a-zA-Z0-9_]{0,31})\/?$/
    );
  return match ? `@${match[1]}` : null;
}

export function formatRussianPhone(value) {
  const text = String(value).trim();
  if (!text) return '';
  if (!/^\+?[\d\s().-]+$/.test(text)) return text;
  const normalized = normalizeRussianPhone(text);
  let digits = (normalized || text).replace(/\D/g, '');
  if (
    digits.length > 11 ||
    /^\+[^78]/.test(text) ||
    (digits.length === 11 && !/^[78]/.test(digits))
  )
    return text;
  if (digits.startsWith('8')) digits = `7${digits.slice(1)}`;
  if (!digits.startsWith('7')) digits = `7${digits}`;
  const body = digits.slice(1);
  let result = '+7';
  if (body.length) result += ` (${body.slice(0, 3)}`;
  if (body.length >= 3) result += ')';
  if (body.length > 3) result += ` ${body.slice(3, 6)}`;
  if (body.length > 6) result += `-${body.slice(6, 8)}`;
  if (body.length > 8) result += `-${body.slice(8, 10)}`;
  return result;
}

export function formatRecipient(value, channel) {
  if (channel === 'telegram' && /[a-zA-Z@]/.test(value)) return value.trim();
  return formatRussianPhone(value);
}
