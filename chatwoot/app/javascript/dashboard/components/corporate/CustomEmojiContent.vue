<script setup>
import { computed } from 'vue';
import FormattedContent from 'next/message/bubbles/Text/FormattedContent.vue';

const props = defineProps({
  content: { type: String, required: true },
  entities: { type: Array, default: () => [] },
  attachments: { type: Array, default: () => [] },
});
const parts = computed(() => {
  const result = [];
  let cursor = 0;
  const entities = [...props.entities]
    .sort((a, b) => a.offset - b.offset)
    .slice(0, 100);
  entities.forEach(entity => {
    const { offset, length, documentId } = entity;
    if (
      !Number.isInteger(offset) ||
      !Number.isInteger(length) ||
      offset < cursor ||
      length <= 0 ||
      offset + length > props.content.length
    )
      return;
    if (offset > cursor)
      result.push({ text: props.content.slice(cursor, offset) });
    const attachment = props.attachments.find(
      item => String(item.meta?.telegramCustomEmojiId) === String(documentId)
    );
    result.push({
      text: props.content.slice(offset, offset + length),
      attachment,
    });
    cursor = offset + length;
  });
  if (cursor < props.content.length)
    result.push({ text: props.content.slice(cursor) });
  return result;
});
</script>

<template>
  <span class="whitespace-pre-wrap">
    <template v-for="(part, index) in parts" :key="index">
      <video
        v-if="part.attachment?.fileType === 'video'"
        :src="part.attachment.dataUrl"
        :aria-label="part.text"
        autoplay
        loop
        muted
        playsinline
        class="inline-block size-6 align-middle object-contain"
      />
      <img
        v-else-if="part.attachment?.fileType === 'image'"
        :src="part.attachment.dataUrl"
        :alt="part.text"
        class="inline-block size-6 align-middle object-contain"
      />
      <FormattedContent v-else :content="part.text" />
    </template>
  </span>
</template>
