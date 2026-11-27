<script setup>
/* global axios */
import { computed, ref, watch, onUnmounted } from 'vue';
import { useI18n } from 'vue-i18n';
const props = defineProps({
  accountId: { type: [String, Number], required: true },
  compact: { type: Boolean, default: false },
});
const { t } = useI18n();
const state = ref(null);
const failed = ref(false);
let timer;
let revision = 0;
const refresh = async () => {
  const current = revision;
  try {
    const response = await axios.get(
      `/api/v1/accounts/${props.accountId}/corporate/health`
    );
    if (current === revision) {
      state.value = response.data;
      failed.value = false;
    }
  } catch {
    if (current === revision) failed.value = true;
  }
};
watch(
  () => props.accountId,
  () => {
    revision += 1;
    clearInterval(timer);
    state.value = null;
    refresh();
    timer = setInterval(refresh, 30000);
  },
  { immediate: true }
);
onUnmounted(() => {
  revision += 1;
  clearInterval(timer);
});
const delayed = computed(
  () =>
    failed.value ||
    (state.value &&
      (!state.value.telegram?.connected ||
        (state.value.max?.delivery_enabled &&
          (!state.value.max.connected ||
            state.value.max.sync_error ||
            state.value.max.status === 'degraded')) ||
        !state.value.chatwoot_worker?.healthy ||
        !state.value.workers?.delivery?.healthy ||
        !state.value.workers?.crm?.healthy ||
        state.value.workers?.delivery?.last_success_age == null ||
        state.value.workers?.delivery?.last_success_age > 300 ||
        state.value.workers?.crm?.last_success_age == null ||
        state.value.workers?.crm?.last_success_age > 300 ||
        state.value.incoming?.oldest_seconds > 300 ||
        state.value.outgoing?.oldest_seconds > 300))
);
</script>

<template>
  <section v-if="!compact || delayed" class="text-sm my-2">
    <p v-if="delayed" role="alert" class="text-n-ruby-11">
      {{ t('CORPORATE.PIPELINE.DELAYED') }}
    </p>
    <p v-else-if="state" role="status">{{ t('CORPORATE.PIPELINE.OK') }}</p>
    <p v-if="state">
      {{
        t('CORPORATE.PIPELINE.QUEUES', {
          incoming: state.incoming.count,
          outgoing: state.outgoing.count,
        })
      }}
    </p>
    <button type="button" class="underline" @click="refresh">
      {{ t('CORPORATE.PIPELINE.REFRESH') }}
    </button>
  </section>
</template>
