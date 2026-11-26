/* global axios */
import { mount, flushPromises } from '@vue/test-utils';
import { withFullI18n } from '../../../../../../vitest.i18n';
import NewConversation from '../NewConversation.vue';
import { corporateRole } from 'dashboard/composables/useCorporate';
vi.mock('vue-router', () => ({
  useRoute: () => ({ params: { accountId: 1 } }),
  useRouter: () => ({ push: vi.fn() }),
}));
withFullI18n();

describe('Corporate recipient form', () => {
  let wrapper;
  beforeEach(() => {
    window.chatwootConfig = { corporateAccessEnabled: true };
    corporateRole.value = 'manager';
    vi.stubGlobal('axios', {
      post: vi
        .fn()
        .mockRejectedValue({ response: { data: { error: 'Synthetic' } } }),
    });
  });
  afterEach(() => {
    wrapper.unmount();
    corporateRole.value = '';
    vi.unstubAllGlobals();
  });
  it('opens a dialog and validates a pasted MAX phone before lookup', async () => {
    wrapper = mount(NewConversation, {
      attachTo: document.body,
      global: { stubs: { teleport: true } },
    });
    await wrapper.find('button').trigger('click');
    await flushPromises();
    expect(wrapper.find('[role=dialog]').exists()).toBe(true);
    expect(wrapper.find('[role=dialog]').text()).toContain('@username');
    await wrapper.find('select').setValue('max');
    await wrapper.find('input').setValue('8 (999) 123-45-67');
    await wrapper.find('form').trigger('submit');
    await flushPromises();
    expect(axios.post).toHaveBeenCalledWith(
      '/api/v1/accounts/1/corporate/conversations',
      { phone: '+79991234567', channel: 'max' }
    );
    await wrapper.find('input').setValue('+7 (999) 123-45-6');
    await wrapper.find('form').trigger('submit');
    expect(axios.post).toHaveBeenCalledTimes(1);
  });
});
