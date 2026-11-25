import { test } from 'node:test';
import assert from 'node:assert/strict';
import { formatRussianPhone } from '../../chatwoot/app/javascript/dashboard/components/corporate/phone.js';
test('Russian phone paste and partial input keep a consistent +7 display', () => {
  for (const value of ['89991234567', '+79991234567', '9991234567', '+7 (999) 123-45-67']) {
    assert.equal(formatRussianPhone(value), '+7 (999) 123-45-67');
  }
  assert.equal(formatRussianPhone(''), '');
  assert.equal(formatRussianPhone('9'), '+7 (9');
  assert.equal(formatRussianPhone('7999'), '+7 (999)');
});
