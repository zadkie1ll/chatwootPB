import { mount, flushPromises } from '@vue/test-utils';
import { defineComponent, ref } from 'vue';
import { useBrowserNotifications } from 'dashboard/composables/useBrowserNotifications';
const Host = defineComponent({
  setup() {
    return useBrowserNotifications(ref(1));
  },
  template: '<div>{{ state }}</div>',
});

describe('Browser notification health', () => {
  let wrapper;
  let status;
  let registration;
  let post;
  beforeEach(() => {
    localStorage.clear();
    window.chatwootConfig = { vapidPublicKey: new Uint8Array(65) };
    status = { configured: true, connected: true };
    registration = {
      pushManager: {
        getSubscription: vi.fn().mockResolvedValue({
          endpoint: 'https://fcm.googleapis.com/fcm/send/test',
          toJSON: () => ({ endpoint: 'synthetic' }),
        }),
      },
    };
    vi.stubGlobal('isSecureContext', true);
    vi.stubGlobal('PushManager', class {});
    vi.stubGlobal('Notification', {
      permission: 'granted',
      requestPermission: vi.fn().mockResolvedValue('granted'),
    });
    Object.defineProperty(navigator, 'serviceWorker', {
      configurable: true,
      value: {
        register: vi.fn().mockResolvedValue(registration),
        ready: Promise.resolve(registration),
      },
    });
    post = vi
      .fn()
      .mockImplementation(() => Promise.resolve({ data: { ...status } }));
    vi.stubGlobal('axios', { post });
  });
  afterEach(() => {
    wrapper?.unmount();
    delete navigator.serviceWorker;
    vi.unstubAllGlobals();
  });
  it('does not call a connected subscription verified until a received test is confirmed', async () => {
    wrapper = mount(Host);
    await flushPromises();
    expect(wrapper.text()).toBe('connected');
    status.test_received_at = new Date().toISOString();
    await wrapper.vm.refresh();
    expect(wrapper.text()).toBe('confirm');
    status.confirmed_at = new Date().toISOString();
    await wrapper.vm.confirm();
    expect(wrapper.text()).toBe('verified');
  });
  it('does not request permission automatically and detects revocation', async () => {
    Notification.permission = 'default';
    wrapper = mount(Host);
    await flushPromises();
    expect(wrapper.text()).toBe('off');
    expect(Notification.requestPermission).not.toHaveBeenCalled();
    Notification.permission = 'denied';
    await wrapper.vm.refresh();
    expect(wrapper.text()).toBe('blocked');
  });
  it('replaces green status with an error if the provider fails later', async () => {
    status = {
      configured: true,
      connected: true,
      test_received_at: '2026-11-27T12:00:00Z',
      confirmed_at: '2026-11-27T12:00:01Z',
    };
    wrapper = mount(Host);
    await flushPromises();
    expect(wrapper.text()).toBe('verified');
    status.last_error = 'push_unavailable';
    await wrapper.vm.refresh();
    expect(wrapper.text()).toBe('error');
  });
  it('shows unsupported without contacting the server on an insecure origin', async () => {
    vi.stubGlobal('isSecureContext', false);
    wrapper = mount(Host);
    await flushPromises();
    expect(wrapper.text()).toBe('unsupported');
    expect(post).not.toHaveBeenCalled();
  });
  it('identifies a native permission rejection without reporting successful connection', async () => {
    status.connected = false;
    registration.pushManager.getSubscription.mockResolvedValue(null);
    registration.pushManager.subscribe = vi
      .fn()
      .mockRejectedValue(
        new DOMException(
          'Registration failed - permission denied',
          'AbortError'
        )
      );
    wrapper = mount(Host);
    await flushPromises();
    await wrapper.vm.enable();
    expect(wrapper.vm.error).toBe('browser_blocked');
    expect(wrapper.text()).toBe('error');
  });
});
