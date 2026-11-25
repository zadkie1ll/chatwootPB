<script setup>
/* global axios */
import { ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import Button from 'dashboard/components-next/button/Button.vue';
const props = defineProps({
  accountId: { type: [Number, String], required: true },
  conversationId: { type: [Number, String], required: true },
});
const emit = defineEmits(['close']);
const { t } = useI18n();
const busy = ref(false);
const summary = ref('');
const error = ref('');
const truncated = ref(false);
const revision = ref(0);
watch(
  [() => props.accountId, () => props.conversationId, revision],
  async ([accountId, id], _old, onCleanup) => {
    let stale = false;
    onCleanup(() => {
      stale = true;
    });
    summary.value = '';
    error.value = '';
    busy.value = true;
    try {
      const { data } = await axios.post(
        `/api/v1/accounts/${accountId}/corporate/conversations/${id}/summary`
      );
      if (stale) return;
      summary.value = data.summary;
      truncated.value = data.truncated;
    } catch (failure) {
      if (!stale)
        error.value = failure.response?.data?.error || t('CORPORATE.ERROR');
    } finally {
      if (!stale) busy.value = false;
    }
  },
  { immediate: true }
);
</script>

<template>
  <Teleport to="body">
    <div
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
      @click.self="emit('close')"
      @keydown.esc="emit('close')"
    >
      <section
        role="dialog"
        aria-modal="true"
        :aria-label="t('CORPORATE.SUMMARY_TITLE')"
        class="flex max-h-[85vh] w-full max-w-2xl flex-col gap-4 rounded-xl bg-n-background p-6 shadow-xl"
      >
        <div class="flex items-center justify-between gap-3">
          <h2 class="text-lg font-medium">
            {{ t('CORPORATE.SUMMARY_TITLE') }}
          </h2>
          <Button
            icon="i-lucide-x"
            :aria-label="t('CORPORATE.CLOSE')"
            ghost
            @click="emit('close')"
          />
        </div>
        <p v-if="busy" role="status">{{ t('CORPORATE.SUMMARY_LOADING') }}</p>
        <p v-else-if="error" role="alert" class="text-n-ruby-11">{{ error }}</p>
        <p v-else class="overflow-y-auto whitespace-pre-wrap text-sm leading-6">
          {{ summary }}
        </p>
        <p v-if="truncated && summary" class="text-xs text-n-slate-11">
          {{ t('CORPORATE.SUMMARY_TRUNCATED') }}
        </p>
        <p class="text-xs text-n-slate-11">
          {{ t('CORPORATE.SUMMARY_NOTICE') }}
        </p>
        <Button
          v-if="error"
          :label="t('CORPORATE.RETRY')"
          faded
          @click="revision++"
        />
      </section>
    </div>
  </Teleport>
</template>
