<script setup>
/* global axios */
import { ref, watch, onUnmounted } from 'vue';
import { useI18n } from 'vue-i18n';
import {
  corporateCrmEnabled,
  corporateRole,
} from 'dashboard/composables/useCorporate';
import { formatRussianPhone } from './phone';
const props = defineProps({
  accountId: { type: [String, Number], required: true },
  conversationId: { type: [String, Number], required: true },
});
const { t } = useI18n();
const info = ref(null);
const phone = ref('');
const dealUrl = ref('');
const ownerId = ref('');
const managers = ref([]);
const busy = ref(false);
const error = ref('');
const editing = ref(false);
let revision = 0;
let timer;
const endpoint = () =>
  `/api/v1/accounts/${props.accountId}/corporate/crm/conversations/${props.conversationId}`;
const apply = data => {
  info.value = data;
  if (!phone.value && data.phone) phone.value = formatRussianPhone(data.phone);
};
const refresh = async () => {
  const expected = revision;
  try {
    const { data } = await axios.get(endpoint());
    if (expected === revision) apply(data);
  } catch {
    /* A transfer can revoke this view; the access event reloads it. */
  }
};
watch(
  () => [props.accountId, props.conversationId, corporateCrmEnabled.value],
  async () => {
    revision += 1;
    const expected = revision;
    clearInterval(timer);
    info.value = null;
    phone.value = '';
    dealUrl.value = '';
    error.value = '';
    ownerId.value = '';
    busy.value = false;
    editing.value = false;
    if (!corporateCrmEnabled.value) return;
    await refresh();
    if (expected !== revision) return;
    if (corporateRole.value === 'supervisor') {
      try {
        const response = await axios.get(
          `/api/v1/accounts/${props.accountId}/corporate/access/staff`
        );
        if (expected === revision) managers.value = response.data;
      } catch {
        if (expected === revision) managers.value = [];
      }
    }
    if (expected !== revision) return;
    timer = setInterval(() => {
      if (
        info.value &&
        ['unlinked', 'looking_up', 'pending', 'sending', 'unknown'].includes(
          info.value.state
        )
      )
        refresh();
    }, 5000);
  },
  { immediate: true }
);
onUnmounted(() => {
  revision += 1;
  clearInterval(timer);
});
const bind = async mode => {
  busy.value = true;
  error.value = '';
  const expected = revision;
  const data =
    mode === 'phone' ? { phone: phone.value } : { deal_url: dealUrl.value };
  if (ownerId.value) data.owner_id = ownerId.value;
  try {
    const response = await axios.post(`${endpoint()}/bind`, data);
    if (expected === revision) {
      apply(response.data);
      editing.value = false;
    }
  } catch (failure) {
    if (expected === revision)
      error.value = failure.response?.data?.error || t('CORPORATE.CRM.ERROR');
  } finally {
    if (expected === revision) busy.value = false;
  }
};
const reconcile = async () => {
  const expected = revision;
  busy.value = true;
  try {
    await axios.post(`${endpoint()}/reconcile`);
    await refresh();
  } catch {
    if (expected === revision) error.value = t('CORPORATE.CRM.ERROR');
  } finally {
    if (expected === revision) busy.value = false;
  }
};
</script>

<template>
  <section
    v-if="corporateCrmEnabled && info"
    class="border-b border-n-weak p-3 text-sm flex flex-col gap-2"
  >
    <p v-if="info.shared" class="font-semibold">
      {{ t('CORPORATE.CRM.SHARED_INTAKE') }}
    </p>
    <template v-if="info.deal_id">
      <a
        :href="info.deal_url"
        target="_blank"
        rel="noopener noreferrer"
        class="underline"
        >{{
          t(
            info.entity_type === 'lead'
              ? 'CORPORATE.CRM.LEAD'
              : 'CORPORATE.CRM.DEAL',
            { id: info.deal_id, title: info.deal_title }
          )
        }}</a
      >
      <p role="status">{{ t(`CORPORATE.CRM.STATE.${info.state}`) }}</p>
      <button
        type="button"
        :disabled="busy || ['sending', 'unknown'].includes(info.state)"
        @click="editing = !editing"
      >
        {{ t('CORPORATE.CRM.CHANGE_LINK') }}
      </button>
      <button
        v-if="['unknown', 'error', 'pending'].includes(info.state)"
        type="button"
        :disabled="busy"
        @click="reconcile"
      >
        {{ t('CORPORATE.CRM.RECONCILE') }}
      </button>
    </template>
    <p v-else>{{ t('CORPORATE.CRM.IDENTIFY') }}</p>
    <p v-if="corporateRole === 'manager' && !info.employee_mapped">
      {{ t('CORPORATE.CRM.MAPPING_REQUIRED') }}
    </p>
    <template
      v-else-if="
        editing || !info.deal_id || ['not_found', 'error'].includes(info.state)
      "
    >
      <label v-if="corporateRole === 'supervisor'"
        >{{ t('CORPORATE.CRM.OWNER') }}
        <select
          v-model="ownerId"
          class="rounded border border-n-weak bg-n-background p-1"
        >
          <option value="">{{ t('CORPORATE.CRM.USE_CURRENT_OWNER') }}</option>
          <option
            v-for="member in managers"
            :key="member.id"
            :value="member.id"
          >
            {{ member.name }}
          </option>
        </select>
      </label>
      <form
        class="flex flex-wrap items-center gap-2"
        @submit.prevent="bind('phone')"
      >
        <label
          >{{ t('CORPORATE.CRM.PHONE')
          }}<input
            :value="phone"
            type="tel"
            :placeholder="t('CORPORATE.CRM.PHONE_EXAMPLE')"
            required
            class="rounded border border-n-weak bg-n-background p-1"
            @input="phone = formatRussianPhone($event.target.value)"
        /></label>
        <button type="submit" :disabled="busy">
          {{ t('CORPORATE.CRM.LINK_PHONE') }}
        </button>
      </form>
      <form
        class="flex flex-wrap items-center gap-2"
        @submit.prevent="bind('deal')"
      >
        <label
          >{{ t('CORPORATE.CRM.DEAL_URL')
          }}<input
            v-model="dealUrl"
            type="url"
            required
            class="rounded border border-n-weak bg-n-background p-1"
        /></label>
        <button type="submit" :disabled="busy">
          {{ t('CORPORATE.CRM.LINK_DEAL') }}
        </button>
      </form>
    </template>
    <p v-if="info.state === 'not_found'" role="status">
      {{ t('CORPORATE.CRM.NOT_FOUND') }}
    </p>
    <p v-if="error" role="alert">{{ error }}</p>
  </section>
</template>
