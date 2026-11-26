import { createI18n } from 'vue-i18n';
import en from 'dashboard/i18n/locale/en/corporate.json';
import ru from 'dashboard/i18n/locale/ru/corporate.json';

describe('Corporate recipient translations', () => {
  it.each(['en', 'ru'])(
    'renders the Telegram username hint in %s without a linked-message parsing error',
    locale => {
      const i18n = createI18n({ legacy: false, locale, messages: { en, ru } });
      expect(i18n.global.t('CORPORATE.RECIPIENT')).toContain('@username');
    }
  );
});
