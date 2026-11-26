<script setup>
/* global axios */
import { ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { emitter } from 'shared/helpers/mitt';
const props = defineProps({
  accountId: { type: [String, Number], required: true },
  conversationId: { type: [String, Number], default: null },
});
const { t } = useI18n();
const state = ref(null);
const busy = ref(false);
const error = ref('');
let revision = 0;
const endpoint = () =>
  `/api/v1/accounts/${props.accountId}/corporate/sharing${props.conversationId ? `/conversations/${props.conversationId}` : ''}`;
watch(
  () => [props.accountId, props.conversationId],
  async () => {
    revision += 1;
    const expected = revision;
    state.value = null;
    error.value = '';
    busy.value = false;
    try {
      const { data } = await axios.get(endpoint());
      if (expected === revision) state.value = data;
    } catch {
      if (expected === revision) error.value = t('CORPORATE.SHARING.ERROR');
    }
  },
  { immediate: true }
);
const toggle = async () => {
  const expected = revision;
  busy.value = true;
  error.value = '';
  const absence = !props.conversationId;
  try {
    const { data } = await axios.patch(
      `${endpoint()}${absence ? '/absence' : ''}`,
      {
        shared: !(absence ? state.value.absence : state.value.manual),
      }
    );
    if (expected !== revision) return;
    state.value = data;
    emitter.emit('corporate_sharing_changed');
  } catch (failure) {
    if (expected === revision)
      error.value =
        failure.response?.data?.error || t('CORPORATE.SHARING.ERROR');
  } finally {
    if (expected === revision) busy.value = false;
  }
};
</script>

<template>
  <div
    class="flex flex-wrap items-center gap-2 p-2 text-sm border-b border-n-weak"
  >
    <template v-if="state">
      <button
        v-if="!conversationId || state.can_manage"
        type="button"
        :disabled="busy"
        class="rounded bg-n-alpha-2 px-3 py-1 text-n-blue-text"
        :aria-pressed="conversationId ? state.manual : state.absence"
        @click="toggle"
      >
        {{
          t(
            !conversationId
              ? state.absence
                ? 'CORPORATE.SHARING.END_ABSENCE'
                : 'CORPORATE.SHARING.START_ABSENCE'
              : state.manual
                ? 'CORPORATE.SHARING.MAKE_PRIVATE'
                : 'CORPORATE.SHARING.MAKE_SHARED'
          )
        }}
      </button>
      <span v-if="conversationId && state.shared" class="text-n-blue-text">{{
        t(
          state.absence
            ? 'CORPORATE.SHARING.ABSENCE_CHAT'
            : 'CORPORATE.SHARING.SHARED_CHAT'
        )
      }}</span>
      <span v-if="!conversationId && state.absence" class="text-xs">{{
        t('CORPORATE.SHARING.ABSENCE_HINT')
      }}</span>
    </template>
    <span v-if="error" role="alert">{{ error }}</span>
  </div>
</template>
