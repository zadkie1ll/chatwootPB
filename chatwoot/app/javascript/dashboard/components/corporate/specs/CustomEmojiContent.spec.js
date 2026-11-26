import { mount } from '@vue/test-utils';
import CustomEmojiContent from '../CustomEmojiContent.vue';

const render = attachments =>
  mount(CustomEmojiContent, {
    props: {
      content: 'A😀B',
      entities: [{ offset: 1, length: 2, documentId: '123' }],
      attachments,
    },
    global: {
      stubs: {
        FormattedContent: {
          props: ['content'],
          template: '<span>{{ content }}</span>',
        },
      },
    },
  });

describe('Telegram custom emoji rendering', () => {
  it('uses UTF-16 offsets and a protected attachment URL', () => {
    const wrapper = render([
      {
        fileType: 'image',
        dataUrl: '/api/v1/corporate_files/10',
        meta: { telegramCustomEmojiId: '123' },
      },
    ]);
    expect(wrapper.find('img').attributes('src')).toBe(
      '/api/v1/corporate_files/10'
    );
    expect(wrapper.find('img').attributes('alt')).toBe('😀');
    expect(wrapper.text()).toBe('AB');
  });
  it('keeps the ordinary emoji if its custom media is unavailable', () => {
    const wrapper = render([]);
    expect(wrapper.find('img').exists()).toBe(false);
    expect(wrapper.text()).toBe('A😀B');
  });
  it('plays video emoji inline without audio', () => {
    const wrapper = render([
      {
        fileType: 'video',
        dataUrl: '/api/v1/corporate_files/11',
        meta: { telegramCustomEmojiId: '123' },
      },
    ]);
    expect(wrapper.find('video').attributes('loop')).toBeDefined();
    expect(wrapper.find('video').element.muted).toBe(true);
  });
});
