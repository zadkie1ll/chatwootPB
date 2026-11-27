/* global axios */
import { mount, flushPromises } from '@vue/test-utils';
import StaffManagement from '../StaffManagement.vue';
import { corporateRole } from 'dashboard/composables/useCorporate';

const result = name => ({
  data: {
    payload: [
      {
        id: 7,
        name,
        email: 'synthetic@example.invalid',
        active: true,
        clients_count: 2,
        conversations_count: 3,
        notifications: { connected: 1, verified: 0 },
      },
    ],
    meta: {
      total: 1,
      per_page: 25,
      summary: { total: 1, active: 1, disabled: 0, mapped: 0 },
    },
  },
});
describe('Manager directory', () => {
  let wrapper;
  beforeEach(() => {
    corporateRole.value = 'supervisor';
    vi.stubGlobal('axios', {
      get: vi.fn().mockResolvedValue(result('Synthetic employee')),
    });
  });
  afterEach(() => {
    wrapper?.unmount();
    corporateRole.value = '';
    vi.unstubAllGlobals();
  });
  it('shows workload and searches through the account API', async () => {
    wrapper = mount(StaffManagement, { props: { accountId: 1 } });
    await flushPromises();
    expect(wrapper.text()).toContain('Synthetic employee');
    await wrapper.find('input').setValue('Synthetic');
    await wrapper.find('form').trigger('submit');
    await flushPromises();
    expect(axios.get).toHaveBeenLastCalledWith(
      '/api/v1/accounts/1/corporate/staff/directory',
      { params: { q: 'Synthetic', status: 'all', page: 1 } }
    );
  });
  it('does not load staff for an ordinary manager', async () => {
    corporateRole.value = 'manager';
    wrapper = mount(StaffManagement, { props: { accountId: 1 } });
    await flushPromises();
    expect(wrapper.text()).toContain('CORPORATE.ACCESS_DENIED');
    expect(axios.get).not.toHaveBeenCalled();
  });
  it('discards a stale response after switching accounts', async () => {
    let oldResponse;
    axios.get
      .mockImplementationOnce(
        () =>
          new Promise(resolve => {
            oldResponse = resolve;
          })
      )
      .mockResolvedValue(result('New account employee'));
    wrapper = mount(StaffManagement, { props: { accountId: 1 } });
    await wrapper.setProps({ accountId: 2 });
    await flushPromises();
    oldResponse(result('Old account employee'));
    await flushPromises();
    expect(wrapper.text()).toContain('New account employee');
    expect(wrapper.text()).not.toContain('Old account employee');
  });
});
