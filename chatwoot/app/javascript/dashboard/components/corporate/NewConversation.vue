<script setup>
/* global axios */
import { ref, nextTick, computed } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useI18n } from 'vue-i18n';
import Button from 'dashboard/components-next/button/Button.vue';
import { corporateRole } from 'dashboard/composables/useCorporate';
const { t } = useI18n();
const route = useRoute();
const router = useRouter();
const enabled = computed(
  () =>
    window.chatwootConfig?.corporateAccessEnabled &&
    ['manager', 'supervisor'].includes(corporateRole.value)
);
const opened = ref(false);
const phone = ref('');
const channel = ref('telegram');
const input = ref(null);
const busy = ref(false);
const error = ref('');
const open = async () => {
  phone.value = '';
  error.value = '';
  opened.value = true;
  await nextTick();
  input.value?.focus();
};
const start = async () => {
  if (busy.value) return;
  let digits = phone.value.replace(/\D/g, '');
  if (digits.length === 10) digits = `7${digits}`;
  if (digits.length === 11 && digits[0] === '8') digits = `7${digits.slice(1)}`;
  if (!/^[1-9]\d{6,14}$/.test(digits)) {
    error.value = t('CORPORATE.INVALID_PHONE');
    return;
  }
  const accountId = route.params.accountId;
  busy.value = true;
  error.value = '';
  try {
    const { data } = await axios.post(
      `/api/v1/accounts/${accountId}/corporate/conversations`,
      { phone: `+${digits}`, channel: channel.value }
    );
    if (String(route.params.accountId) !== String(accountId)) return;
    opened.value = false;
    router.push(
      `/app/accounts/${accountId}/conversations/${data.conversation_id}`
    );
  } catch (failure) {
    error.value = failure.response?.data?.error || t('CORPORATE.ERROR');
  } finally {
    busy.value = false;
  }
};
</script>

<template>
  <Button
    v-if="enabled"
    :aria-label="t('CORPORATE.NEW_CHAT')"
    :title="t('CORPORATE.NEW_CHAT')"
    icon="i-lucide-plus"
    sm
    faded
    @click="open"
  />
  <Teleport to="body">
    <div
      v-if="opened"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
      @click.self="opened = false"
      @keydown.esc="opened = false"
    >
      <section
        role="dialog"
        aria-modal="true"
        :aria-label="t('CORPORATE.NEW_CHAT')"
        class="w-full max-w-md rounded-xl bg-n-background p-6 shadow-xl"
      >
        <h2 class="mb-4 text-lg font-medium">{{ t('CORPORATE.NEW_CHAT') }}</h2>
        <form class="flex flex-col gap-4" @submit.prevent="start">
          <label class="flex flex-col gap-2">
            {{ t('CORPORATE.CHANNEL') }}
            <select
              v-model="channel"
              class="rounded-lg border border-n-weak bg-n-background px-3 py-2"
            >
              <option value="telegram">
                {{ t('CORPORATE.CHANNEL_NAMES.TELEGRAM') }}
              </option>
              <option value="max">
                {{ t('CORPORATE.CHANNEL_NAMES.MAX') }}
              </option>
            </select>
          </label>
          <label class="flex flex-col gap-2">
            {{ t('CORPORATE.CLIENT_PHONE') }}
            <input
              ref="input"
              v-model="phone"
              type="tel"
              autocomplete="tel"
              maxlength="25"
              required
              :placeholder="t('CORPORATE.PHONE_EXAMPLE')"
              class="rounded-lg border border-n-weak bg-n-background px-3 py-2"
            />
          </label>
          <p v-if="error" role="alert" class="text-sm text-n-ruby-11">
            {{ error }}
          </p>
          <div class="flex justify-end gap-2">
            <Button
              :label="t('CORPORATE.CANCEL')"
              slate
              faded
              type="button"
              @click="opened = false"
            />
            <Button
              :label="t('CORPORATE.START')"
              type="submit"
              :disabled="busy"
              :is-loading="busy"
            />
          </div>
        </form>
      </section>
    </div>
  </Teleport>
</template>
