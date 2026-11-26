import { mount, flushPromises } from '@vue/test-utils';
import CrmBanner from '../CrmBanner.vue';
import {
  corporateCrmEnabled,
  corporateRole,
} from 'dashboard/composables/useCorporate';

describe('CRM panel visibility', () => {
  let wrapper;
  beforeEach(() => {
    localStorage.clear();
    corporateCrmEnabled.value = true;
    corporateRole.value = 'manager';
    vi.stubGlobal('axios', {
      get: vi.fn().mockResolvedValue({
        data: { state: 'unlinked', employee_mapped: true },
      }),
    });
  });
  afterEach(() => {
    wrapper.unmount();
    vi.unstubAllGlobals();
  });
  const open = async () => {
    wrapper = mount(CrmBanner, {
      props: { accountId: 1, conversationId: 13 },
      attachTo: document.body,
    });
    await flushPromises();
  };
  it('hides the binding form and restores the preference in another chat', async () => {
    await open();
    const toggle = wrapper.find('button[aria-expanded]');
    expect(wrapper.find('input[type=tel]').isVisible()).toBe(true);
    await toggle.trigger('click');
    expect(toggle.attributes('aria-expanded')).toBe('false');
    expect(wrapper.find('input[type=tel]').isVisible()).toBe(false);
    await wrapper.setProps({ conversationId: 14 });
    await flushPromises();
    expect(wrapper.find('input[type=tel]').isVisible()).toBe(false);
    wrapper.unmount();
    await open();
    expect(wrapper.find('input[type=tel]').isVisible()).toBe(false);
    await wrapper.find('button[aria-expanded]').trigger('click');
    expect(wrapper.find('input[type=tel]').isVisible()).toBe(true);
  });
});
