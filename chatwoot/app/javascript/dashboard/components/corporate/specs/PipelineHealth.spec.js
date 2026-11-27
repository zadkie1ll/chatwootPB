import { mount, flushPromises } from '@vue/test-utils';
import PipelineHealth from '../PipelineHealth.vue';

describe('Messenger pipeline health', () => {
  let wrapper;
  afterEach(() => {
    wrapper?.unmount();
    vi.unstubAllGlobals();
  });
  const render = async patch => {
    const data = {
      telegram: { connected: true },
      max: { connected: true, delivery_enabled: true, status: 'ok' },
      chatwoot_worker: { healthy: true },
      workers: {
        delivery: { healthy: true, last_success_age: 1 },
        crm: { healthy: true, last_success_age: 1 },
      },
      incoming: { count: 0, oldest_seconds: 0 },
      outgoing: { count: 0, oldest_seconds: 0 },
      ...patch,
    };
    vi.stubGlobal('axios', { get: vi.fn().mockResolvedValue({ data }) });
    wrapper = mount(PipelineHealth, { props: { accountId: 1, compact: true } });
    await flushPromises();
  };
  it('does not show a warning for a healthy pipeline', async () => {
    await render({});
    expect(wrapper.find('[role=alert]').exists()).toBe(false);
  });
  it('warns when MAX is disconnected even though the application and workers are alive', async () => {
    await render({ max: { connected: false, delivery_enabled: true } });
    expect(wrapper.find('[role=alert]').exists()).toBe(true);
  });
  it('warns when MAX synchronization has stopped', async () => {
    await render({
      max: {
        connected: true,
        delivery_enabled: true,
        sync_error: 'sync_timeout',
      },
    });
    expect(wrapper.find('[role=alert]').exists()).toBe(true);
  });
  it('warns when a worker heartbeat is fresh but its last successful processing is stale', async () => {
    await render({
      workers: {
        delivery: { healthy: true, last_success_age: 301 },
        crm: { healthy: true, last_success_age: 1 },
      },
    });
    expect(wrapper.find('[role=alert]').exists()).toBe(true);
  });
});
