export function formatRussianPhone(value) {
  let digits = String(value).replace(/\D/g, '');
  if (!digits) return '';
  if (digits.startsWith('8')) digits = `7${digits.slice(1)}`;
  if (!digits.startsWith('7')) digits = `7${digits}`;
  digits = digits.slice(0, 11);
  const body = digits.slice(1);
  let result = '+7';
  if (body.length) result += ` (${body.slice(0, 3)}`;
  if (body.length >= 3) result += ')';
  if (body.length > 3) result += ` ${body.slice(3, 6)}`;
  if (body.length > 6) result += `-${body.slice(6, 8)}`;
  if (body.length > 8) result += `-${body.slice(8, 10)}`;
  return result;
}
