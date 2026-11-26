import { mount, flushPromises } from '@vue/test-utils';
import SharingControls from '../SharingControls.vue';

describe('Corporate shared access controls', () => {
  let wrapper;
  afterEach(() => {
    wrapper?.unmount();
    vi.unstubAllGlobals();
  });
  it('lets an owner explicitly share one conversation', async () => {
    const patch = vi.fn().mockResolvedValue({
      data: { shared: true, manual: true, can_manage: true },
    });
    vi.stubGlobal('axios', {
      get: vi.fn().mockResolvedValue({
        data: { shared: false, manual: false, can_manage: true },
      }),
      patch,
    });
    wrapper = mount(SharingControls, {
      props: { accountId: 1, conversationId: 13 },
    });
    await flushPromises();
    await wrapper.find('button').trigger('click');
    await flushPromises();
    expect(patch).toHaveBeenCalledWith(
      '/api/v1/accounts/1/corporate/sharing/conversations/13',
      { shared: true }
    );
    expect(wrapper.find('button').attributes('aria-pressed')).toBe('true');
  });
  it('shows shared status but no management button to a colleague', async () => {
    vi.stubGlobal('axios', {
      get: vi.fn().mockResolvedValue({
        data: { shared: true, manual: true, can_manage: false },
      }),
    });
    wrapper = mount(SharingControls, {
      props: { accountId: 1, conversationId: 13 },
    });
    await flushPromises();
    expect(wrapper.find('button').exists()).toBe(false);
    expect(wrapper.text()).toContain('CORPORATE.SHARING.SHARED_CHAT');
  });
  it('can end absence sharing independently of manually shared conversations', async () => {
    const patch = vi.fn().mockResolvedValue({ data: { absence: false } });
    vi.stubGlobal('axios', {
      get: vi.fn().mockResolvedValue({ data: { absence: true } }),
      patch,
    });
    wrapper = mount(SharingControls, { props: { accountId: 1 } });
    await flushPromises();
    await wrapper.find('button').trigger('click');
    await flushPromises();
    expect(patch).toHaveBeenCalledWith(
      '/api/v1/accounts/1/corporate/sharing/absence',
      { shared: false }
    );
    expect(wrapper.find('button').attributes('aria-pressed')).toBe('false');
  });
});
