<script setup>
/* global axios */
import { ref, onMounted } from 'vue';
import { useI18n } from 'vue-i18n';
const props = defineProps({
  accountId: { type: [String, Number], required: true },
});
const { t } = useI18n();
const status = ref('loading');
const step = ref('start');
const busy = ref(false);
const error = ref('');
const retryAfter = ref(0);
const apiId = ref('');
const apiHash = ref('');
const phone = ref('');
const code = ref('');
const password = ref('');
const endpoint = `/api/v1/accounts/${props.accountId}/corporate/channel`;
onMounted(async () => {
  try {
    status.value = (await axios.get(endpoint)).data.status;
  } catch {
    status.value = 'unavailable';
  }
});
const submit = async () => {
  busy.value = true;
  error.value = '';
  retryAfter.value = 0;
  let data;
  if (step.value === 'start')
    data = { api_id: apiId.value, api_hash: apiHash.value, phone: phone.value };
  else if (step.value === 'code') data = { code: code.value };
  else data = { password: password.value };
  try {
    const result = (
      await axios.post(`${endpoint}/connect`, { ...data, step: step.value })
    ).data;
    if (result.status === 'connected') status.value = 'connected';
    else if (result.status === 'code_required') step.value = 'code';
    else if (result.status === 'password_required') step.value = 'password';
    else if (result.status === 'wait') retryAfter.value = result.retry_after;
  } catch (failure) {
    retryAfter.value = failure.response?.data?.retry_after || 0;
    error.value = t('CORPORATE.AUTH_ERROR');
  } finally {
    apiHash.value = '';
    code.value = '';
    password.value = '';
    busy.value = false;
  }
};
</script>

<template>
  <div class="flex flex-col gap-3">
    <h2 class="text-lg font-semibold">{{ t('CORPORATE.TELEGRAM_SETUP') }}</h2>
    <p role="status">
      {{ t(`CORPORATE.CHANNEL_STATUS.${status.toUpperCase()}`) }}
    </p>
    <template v-if="status === 'disconnected'">
      <p>
        {{ t('CORPORATE.SETUP_HELP') }}
        <a
          href="https://my.telegram.org/apps"
          target="_blank"
          rel="noopener noreferrer"
          class="underline"
          >{{ t('CORPORATE.TELEGRAM_PORTAL') }}</a
        >
      </p>
      <form class="flex flex-col gap-3" @submit.prevent="submit">
        <template v-if="step === 'start'">
          <label
            >{{ t('CORPORATE.API_ID')
            }}<input
              v-model="apiId"
              type="number"
              min="1"
              required
              class="w-full rounded border border-n-weak bg-n-background p-2"
          /></label>
          <label
            >{{ t('CORPORATE.API_HASH')
            }}<input
              v-model="apiHash"
              type="password"
              autocomplete="off"
              required
              minlength="32"
              maxlength="32"
              class="w-full rounded border border-n-weak bg-n-background p-2"
          /></label>
          <label
            >{{ t('CORPORATE.TG_PHONE')
            }}<input
              v-model="phone"
              type="tel"
              :placeholder="t('CORPORATE.PHONE_EXAMPLE')"
              required
              class="w-full rounded border border-n-weak bg-n-background p-2"
          /></label>
        </template>
        <label v-else-if="step === 'code'"
          >{{ t('CORPORATE.TG_CODE')
          }}<input
            v-model="code"
            inputmode="numeric"
            autocomplete="one-time-code"
            required
            class="w-full rounded border border-n-weak bg-n-background p-2"
        /></label>
        <label v-else
          >{{ t('CORPORATE.TG_PASSWORD')
          }}<input
            v-model="password"
            type="password"
            autocomplete="off"
            required
            class="w-full rounded border border-n-weak bg-n-background p-2"
        /></label>
        <p v-if="error" role="alert">{{ error }}</p>
        <p v-if="retryAfter" role="status">
          {{ t('CORPORATE.AUTH_WAIT', { seconds: retryAfter }) }}
        </p>
        <button
          type="submit"
          :disabled="busy"
          class="rounded bg-n-alpha-2 px-3 py-2"
        >
          {{
            t(step === 'start' ? 'CORPORATE.SEND_CODE' : 'CORPORATE.CONFIRM')
          }}
        </button>
        <button
          v-if="step !== 'start'"
          type="button"
          :disabled="busy"
          @click="step = 'start'"
        >
          {{ t('CORPORATE.AUTH_RESTART') }}
        </button>
      </form>
    </template>
  </div>
</template>
