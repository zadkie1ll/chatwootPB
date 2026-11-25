<script setup>
import Icon from 'dashboard/components-next/icon/Icon.vue';
import { computed } from 'vue';
const props = defineProps({ channel: { type: String, default: '' } });
const known = computed(() => ['telegram', 'max'].includes(props.channel));
</script>

<template>
  <span
    v-if="known"
    :title="channel === 'telegram' ? 'Telegram' : 'MAX'"
    :aria-label="channel === 'telegram' ? 'Telegram' : 'MAX'"
    role="img"
    class="inline-flex size-5 shrink-0 items-center justify-center align-middle"
    :data-channel="channel"
  >
    <Icon
      v-if="channel === 'telegram'"
      icon="i-logos-telegram"
      class="size-4"
    />
    <svg v-else viewBox="0 0 24 24" class="size-5" aria-hidden="true">
      <rect width="24" height="24" rx="7" fill="#6655ee" />
      <path
        d="M12 4a8 8 0 0 0-7.4 11l-.5 4.4 4.2-.7A8 8 0 1 0 12 4Zm0 3a5 5 0 1 1-3 9l-1.5.3.2-1.5A5 5 0 0 1 12 7Z"
        fill="white"
      />
    </svg>
  </span>
</template>
