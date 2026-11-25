<script setup>
/* global axios */
import { ref, onMounted, onUnmounted } from 'vue';
import { useI18n } from 'vue-i18n';
import Button from 'dashboard/components-next/button/Button.vue';
const props = defineProps({
  accountId: { type: [String, Number], required: true },
});
const { t } = useI18n();
const state = ref({ status: 'loading', attempt_id: null });
const password = ref('');
const error = ref('');
const busy = ref(false);
const polling = ref(false);
let timer;
let active = true;
let revision = 0;
const endpoint = `/api/v1/accounts/${props.accountId}/corporate/max_channel`;
const refresh = async () => {
  if (polling.value || busy.value) return;
  const version = revision;
  polling.value = true;
  try {
    const response = await axios.get(endpoint);
    if (active && version === revision) state.value = response.data;
  } catch {
    if (active && version === revision) state.value = { status: 'unavailable' };
  } finally {
    polling.value = false;
  }
};
const action = async step => {
  if (busy.value) return;
  revision += 1;
  busy.value = true;
  error.value = '';
  const data = step === 'start' ? {} : { attempt_id: state.value.attempt_id };
  if (step === 'password') data.password = password.value;
  try {
    const response = await axios.post(`${endpoint}/connect`, { step, ...data });
    if (active) state.value = response.data;
  } catch {
    if (active) error.value = t('CORPORATE.MAX.ERROR');
  } finally {
    password.value = '';
    busy.value = false;
  }
};
onMounted(() => {
  refresh();
  timer = setInterval(refresh, 2500);
});
onUnmounted(() => {
  active = false;
  clearInterval(timer);
  state.value = { status: 'disconnected' };
  password.value = '';
});
</script>

<template>
  <section
    class="flex flex-col gap-3 border-t border-n-weak pt-5"
    :aria-label="t('CORPORATE.MAX.TITLE')"
  >
    <h2 class="text-lg font-semibold">{{ t('CORPORATE.MAX.TITLE') }}</h2>
    <p class="text-sm text-n-slate-11">{{ t('CORPORATE.MAX.PILOT') }}</p>
    <p role="status">
      {{ t(`CORPORATE.MAX.STATUS.${state.status.toUpperCase()}`) }}
    </p>
    <template v-if="state.status === 'qr_required' && state.qr_image">
      <p>{{ t('CORPORATE.MAX.SCAN') }}</p>
      <img
        :src="state.qr_image"
        :alt="t('CORPORATE.MAX.QR_ALT')"
        class="size-64 max-w-full rounded-lg bg-white p-2"
      />
    </template>
    <form
      v-if="state.status === 'password_required'"
      class="flex flex-col gap-3"
      @submit.prevent="action('password')"
    >
      <label>
        <span>{{ t('CORPORATE.MAX.PASSWORD') }}</span>
        <input
          v-model="password"
          type="password"
          autocomplete="off"
          required
          maxlength="256"
          class="w-full rounded-lg border border-n-weak bg-n-background p-2"
      /></label>
      <Button type="submit" :disabled="busy" :label="t('CORPORATE.CONFIRM')" />
    </form>
    <p v-if="state.error || error" role="alert">
      {{ error || t('CORPORATE.MAX.ERROR') }}
    </p>
    <div class="flex flex-wrap gap-2">
      <Button
        v-if="['disconnected', 'error', 'unavailable'].includes(state.status)"
        :disabled="busy"
        :label="t('CORPORATE.MAX.START')"
        icon="i-lucide-qr-code"
        @click="action('start')"
      />
      <Button
        v-if="
          state.attempt_id &&
          !['disconnected', 'error', 'unavailable'].includes(state.status)
        "
        :disabled="busy"
        slate
        faded
        :label="t('CORPORATE.MAX.STOP')"
        @click="action('cancel')"
      />
    </div>
  </section>
</template>
