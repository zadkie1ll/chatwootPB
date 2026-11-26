import { mount } from '@vue/test-utils';
import { ref } from 'vue';
import MessageMeta from '../MessageMeta.vue';

const context = {
  status: ref('read'),
  isPrivate: ref(false),
  createdAt: ref(1700000000),
  sourceId: ref('123'),
  messageType: ref(1),
  contentAttributes: ref({ corporateDelivery: 'sent' }),
};
vi.mock('../provider.js', () => ({ useMessageContext: () => context }));
vi.mock('shared/composables/useExactTimestamp', () => ({
  useExactTimestamp: () => () => 'Synthetic timestamp',
}));
vi.mock('dashboard/composables/useInbox', () => ({
  useInbox: () =>
    Object.fromEntries(
      [
        'isAFacebookInbox',
        'isALineChannel',
        'isAPIInbox',
        'isASmsInbox',
        'isATelegramChannel',
        'isATwilioChannel',
        'isAWebWidgetInbox',
        'isAWhatsAppChannel',
        'isAnEmailChannel',
        'isAnInstagramChannel',
        'isATiktokChannel',
      ].map(name => [name, { value: name === 'isAPIInbox' }])
    ),
}));
const render = () =>
  mount(MessageMeta, {
    global: {
      stubs: {
        MessageStatus: {
          props: ['status'],
          template: '<span :data-status="status" />',
        },
      },
    },
  });

describe('Corporate delivery and provider read receipts', () => {
  it('shows the actual read indicator after the corporate send has finished', () => {
    context.status.value = 'read';
    context.contentAttributes.value = { corporateDelivery: 'sent' };
    const wrapper = render();
    expect(wrapper.find('[data-status=read]').exists()).toBe(true);
    expect(wrapper.text()).not.toContain('CORPORATE.DELIVERY.sent');
  });
  it('keeps an uncertain send visibly uncertain instead of showing a sent check', () => {
    context.status.value = 'sent';
    context.contentAttributes.value = { corporateDelivery: 'unknown' };
    const wrapper = render();
    expect(wrapper.find('[data-status]').exists()).toBe(false);
    expect(wrapper.text()).toContain('CORPORATE.DELIVERY.unknown');
  });
});
