/* global axios */
import { mount, flushPromises } from '@vue/test-utils';
import StaffEditor from '../StaffEditor.vue';

describe('Manager editor', () => {
  let wrapper;
  beforeEach(() => {
    vi.stubGlobal('axios', {
      get: vi.fn().mockResolvedValue({
        data: {
          employees: [
            {
              id: '901',
              name: 'Already linked',
              email: 'linked@example.invalid',
            },
            {
              id: '902',
              name: 'Synthetic CRM employee',
              email: 'new@example.invalid',
            },
          ],
          assigned_ids: ['901'],
        },
      }),
      post: vi.fn().mockResolvedValue({
        data: {
          id: 7,
          name: 'Synthetic CRM employee',
          email: 'new@example.invalid',
        },
      }),
      patch: vi.fn().mockResolvedValue({ data: { id: 7 } }),
    });
  });
  afterEach(() => {
    wrapper?.unmount();
    vi.unstubAllGlobals();
  });
  const render = props =>
    mount(StaffEditor, {
      props: { accountId: 1, ...props },
      global: { stubs: { teleport: true } },
    });
  it('does not send an empty password when editing a profile', async () => {
    wrapper = render({
      member: {
        id: 7,
        active: true,
        name: 'Synthetic',
        email: 'old@example.invalid',
      },
    });
    await wrapper.find('input').setValue('Changed synthetic');
    await wrapper.find('form').trigger('submit');
    await flushPromises();
    expect(axios.patch).toHaveBeenCalledWith(
      '/api/v1/accounts/1/corporate/staff/7',
      { name: 'Changed synthetic', email: 'old@example.invalid' }
    );
    expect(wrapper.emitted('close')).toHaveLength(1);
  });
  it('creates a linked manager and shows credentials only in the creation dialog', async () => {
    wrapper = render({ crmEnabled: true });
    await flushPromises();
    const selects = wrapper.findAll('select');
    expect(
      selects[1].find('option[value="901"]').attributes('disabled')
    ).toBeDefined();
    await selects[1].setValue('902');
    await wrapper.findAll('input')[2].setValue('SyntheticPassword12!');
    await wrapper.find('form').trigger('submit');
    await flushPromises();
    expect(axios.post).toHaveBeenCalledWith(
      '/api/v1/accounts/1/corporate/staff',
      {
        name: 'Synthetic CRM employee',
        email: 'new@example.invalid',
        password: 'SyntheticPassword12!',
        bitrix_user_id: '902',
      }
    );
    expect(wrapper.find('code').text()).toBe('SyntheticPassword12!');
    expect(wrapper.emitted('saved')).toHaveLength(1);
    expect(wrapper.emitted('close')).toBeUndefined();
  });
});
