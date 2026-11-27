<script setup>
import { ref, computed } from 'vue';
import { onClickOutside, onKeyStroke } from '@vueuse/core';
import { useI18n } from 'vue-i18n';
import { useBrowserNotifications } from 'dashboard/composables/useBrowserNotifications';
const props = defineProps({
  accountId: { type: [String, Number], required: true },
});
const account = computed(() => props.accountId);
const { t } = useI18n();
const {
  state,
  server,
  supported,
  busy,
  checking,
  error,
  enable,
  disable,
  test,
  confirm,
  refresh,
} = useBrowserNotifications(account);
const opened = ref(false);
const panel = ref(null);
onClickOutside(panel, () => {
  opened.value = false;
});
onKeyStroke('Escape', () => {
  opened.value = false;
});
const label = computed(() => t(`CORPORATE.PUSH.STATE.${state.value}`));
const errorText = computed(() => {
  const codes = {
    browser_blocked: 'CORPORATE.PUSH.ERROR_BROWSER',
    worker_unavailable: 'CORPORATE.PUSH.ERROR_WORKER',
    session_required: 'CORPORATE.PUSH.ERROR_SESSION',
    push_unavailable: 'CORPORATE.PUSH.ERROR_PROVIDER',
    test_rate_limited: 'CORPORATE.PUSH.ERROR_RATE',
    test_not_received: 'CORPORATE.PUSH.ERROR_RECEIPT',
    subscription_expired: 'CORPORATE.PUSH.ERROR_EXPIRED',
  };
  return t(
    codes[error.value || server.value.last_error] || 'CORPORATE.PUSH.ERROR'
  );
});
const receivedAt = computed(() =>
  server.value.test_received_at
    ? new Date(server.value.test_received_at).toLocaleString()
    : ''
);
</script>

<template>
  <div ref="panel" class="relative">
    <button
      type="button"
      class="flex items-center gap-2 rounded px-2 py-1 text-xs hover:bg-n-alpha-2"
      :class="state === 'verified' ? 'text-n-teal-11' : 'text-n-amber-11'"
      :aria-label="t('CORPORATE.PUSH.TITLE')"
      :aria-expanded="opened"
      :title="label"
      @click="opened = !opened"
    >
      <span
        class="size-4"
        :class="state === 'verified' ? 'i-lucide-bell-ring' : 'i-lucide-bell'"
      />
      <span class="hidden md:inline">{{ label }}</span>
    </button>
    <section
      v-if="opened"
      role="dialog"
      :aria-label="t('CORPORATE.PUSH.TITLE')"
      class="absolute top-full end-0 z-50 mt-2 flex w-[22rem] max-w-[90vw] flex-col gap-3 rounded-xl border border-n-weak bg-n-background p-4 shadow-lg"
    >
      <h2 class="text-sm font-medium">{{ t('CORPORATE.PUSH.TITLE') }}</h2>
      <p role="status" class="text-sm">{{ label }}</p>
      <p class="text-xs text-n-slate-11">
        {{ t(`CORPORATE.PUSH.HELP.${state}`) }}
      </p>
      <p v-if="error" role="alert" class="text-xs text-n-ruby-11">
        {{ errorText }}
      </p>
      <p v-if="receivedAt" class="text-xs text-n-slate-11">
        {{ t('CORPORATE.PUSH.RECEIVED', { time: receivedAt }) }}
      </p>
      <p class="text-xs text-n-slate-11">
        {{ t('CORPORATE.PUSH.SYSTEM_LIMIT') }}
      </p>
      <div class="flex flex-wrap gap-2">
        <button
          v-if="
            supported &&
            (!server.connected || state === 'error') &&
            state !== 'blocked' &&
            server.configured
          "
          type="button"
          :disabled="busy"
          class="rounded bg-n-alpha-2 px-3 py-2 text-sm"
          @click="enable"
        >
          {{ t('CORPORATE.PUSH.ENABLE') }}
        </button>
        <button
          v-if="server.connected"
          type="button"
          :disabled="busy || checking"
          class="rounded bg-n-alpha-2 px-3 py-2 text-sm"
          @click="test"
        >
          {{ t('CORPORATE.PUSH.TEST') }}
        </button>
        <button
          v-if="server.test_received_at && !server.confirmed_at"
          type="button"
          :disabled="busy"
          class="rounded bg-n-alpha-2 px-3 py-2 text-sm text-n-blue-text"
          @click="confirm"
        >
          {{ t('CORPORATE.PUSH.CONFIRM') }}
        </button>
        <button
          v-if="server.connected"
          type="button"
          :disabled="busy"
          class="rounded px-3 py-2 text-sm"
          @click="disable"
        >
          {{ t('CORPORATE.PUSH.DISABLE') }}
        </button>
        <button
          type="button"
          :disabled="busy"
          class="rounded px-3 py-2 text-sm"
          @click="refresh"
        >
          {{ t('CORPORATE.PUSH.REFRESH') }}
        </button>
      </div>
    </section>
  </div>
</template>
