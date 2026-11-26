import { mount } from '@vue/test-utils';
import { nextTick } from 'vue';
import InboxListPanel from '../InboxListPanel.vue';

describe('Inbox list layout preference', () => {
  let wrapper;
  beforeEach(() => localStorage.clear());
  afterEach(() => wrapper.unmount());
  const open = () => {
    wrapper = mount(InboxListPanel, {
      slots: { default: '<p data-list>Notifications</p>' },
      attachTo: document.body,
    });
  };
  it('collapses, remembers the choice and can be reopened', async () => {
    open();
    await wrapper.find('button').trigger('click');
    expect(wrapper.find('[data-list]').isVisible()).toBe(false);
    wrapper.unmount();
    open();
    expect(wrapper.find('button').attributes('aria-expanded')).toBe('false');
    await wrapper.find('button').trigger('click');
    expect(wrapper.find('[data-list]').isVisible()).toBe(true);
  });
  it('resizes with the keyboard within bounds and restores the width', async () => {
    open();
    const separator = wrapper.find('[role=separator]');
    await separator.trigger('keydown', { key: 'ArrowRight' });
    expect(separator.attributes('aria-valuenow')).toBe('364');
    wrapper.unmount();
    open();
    expect(wrapper.find('[role=separator]').attributes('aria-valuenow')).toBe(
      '364'
    );
    for (let i = 0; i < 30; i += 1) {
      wrapper
        .find('[role=separator]')
        .element.dispatchEvent(
          new KeyboardEvent('keydown', { key: 'ArrowLeft', bubbles: true })
        );
    }
    await nextTick();
    expect(wrapper.find('[role=separator]').attributes('aria-valuenow')).toBe(
      '256'
    );
  });
});
