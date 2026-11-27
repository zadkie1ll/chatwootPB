<script setup>
/* global axios */
import { ref, computed, watch } from 'vue';
import { onClickOutside, onKeyStroke } from '@vueuse/core';
import { useRouter } from 'vue-router';
import { corporateCrmEnabled } from 'dashboard/composables/useCorporate';
import {
  formatRecipient,
  normalizeRussianPhone,
  normalizeTelegramUsername,
} from './phone';
import { useI18n } from 'vue-i18n';
import BrowserNotifications from './BrowserNotifications.vue';
import InterfaceScale from './InterfaceScale.vue';
import SharingControls from './SharingControls.vue';
import MaxSetup from './MaxSetup.vue';
import TelegramSetup from './TelegramSetup.vue';
import StaffManagement from './StaffManagement.vue';
import CrmEmployees from './CrmEmployees.vue';
import PipelineHealth from './PipelineHealth.vue';

const props = defineProps({
  accountId: { type: [String, Number], default: null },
});
const { t } = useI18n();
const router = useRouter();
const role = ref('');
const gatewayMode = ref('');
const opened = ref(false);
const toolbar = ref(null);
onClickOutside(toolbar, () => {
  opened.value = false;
});
onKeyStroke('Escape', () => {
  opened.value = false;
});
const clients = ref([]);
const owners = ref({});
const managers = ref([]);
const selection = ref({});
const reason = ref('');
const phone = ref('');
const message = ref('');
const page = ref(1);
const busy = ref(false);
const ownerFilter = ref('');
const audit = ref(null);
const auditPage = ref(1);
const isSupervisor = computed(() => role.value === 'supervisor');
const api = computed(() => `/api/v1/accounts/${props.accountId}`);
const enabled = window.chatwootConfig?.corporateAccessEnabled;

watch(
  () => props.accountId,
  async id => {
    role.value = '';
    clients.value = [];
    if (!enabled || !id) return;
    try {
      const response = await axios.get(`${api.value}/corporate/access`);
      role.value = response.data.role;
      gatewayMode.value = response.data.gateway_mode;
      if (role.value === 'technical_admin')
        router.replace(`/app/accounts/${props.accountId}/settings/inboxes`);
    } catch {
      message.value = t('CORPORATE.ACCESS_DENIED');
    }
  },
  { immediate: true }
);

const load = async () => {
  busy.value = true;
  message.value = '';
  try {
    const contacts = await axios.get(`${api.value}/contacts`, {
      params: { page: page.value, corporate_owner: ownerFilter.value },
    });
    clients.value = contacts.data.payload;
    if (isSupervisor.value) {
      const [staff, ownerships] = await Promise.all([
        axios.get(`${api.value}/corporate/access/staff`),
        axios.get(`${api.value}/corporate/ownerships`, {
          params: { contact_ids: clients.value.map(client => client.id) },
        }),
      ]);
      managers.value = staff.data;
      owners.value = Object.fromEntries(
        ownerships.data.map(row => [row.contact_id, row.owner_id])
      );
      selection.value = { ...owners.value };
    }
  } catch {
    message.value = t('CORPORATE.ERROR');
  } finally {
    busy.value = false;
  }
};
const toggle = async () => {
  opened.value = !opened.value;
  if (opened.value && role.value !== 'technical_admin') await load();
};
const transfer = async contact => {
  if (!reason.value.trim()) {
    message.value = t('CORPORATE.REASON_REQUIRED');
    return;
  }
  busy.value = true;
  try {
    await axios.put(`${api.value}/corporate/ownerships/${contact.id}`, {
      owner_id: selection.value[contact.id] || null,
      reason: reason.value,
    });
    await load();
    message.value = t('CORPORATE.TRANSFERRED');
  } catch {
    message.value = t('CORPORATE.ERROR');
  } finally {
    busy.value = false;
  }
};
const openChat = async contact => {
  try {
    const response = await axios.get(
      `${api.value}/contacts/${contact.id}/conversations`
    );
    const conversation = response.data.payload?.[0];
    if (conversation) {
      opened.value = false;
      router.push(
        `/app/accounts/${props.accountId}/conversations/${conversation.id}`
      );
    }
  } catch {
    message.value = t('CORPORATE.ERROR');
  }
};
const start = async () => {
  const recipient =
    normalizeRussianPhone(phone.value) ||
    normalizeTelegramUsername(phone.value);
  if (!recipient) {
    message.value = t('CORPORATE.INVALID_RECIPIENT');
    return;
  }
  busy.value = true;
  try {
    const response = await axios.post(`${api.value}/corporate/conversations`, {
      phone: recipient,
      channel: 'telegram',
    });
    opened.value = false;
    router.push(
      `/app/accounts/${props.accountId}/conversations/${response.data.conversation_id}`
    );
  } catch (error) {
    message.value = error.response?.data?.error || t('CORPORATE.ERROR');
  } finally {
    busy.value = false;
  }
};
const turnPage = async delta => {
  page.value = Math.max(1, page.value + delta);
  await load();
};
const filterClients = async () => {
  page.value = 1;
  await load();
};
const loadAudit = async delta => {
  auditPage.value = Math.max(1, auditPage.value + delta);
  try {
    audit.value = (
      await axios.get(`${api.value}/corporate/ownerships/audit`, {
        params: { page: auditPage.value },
      })
    ).data;
  } catch {
    message.value = t('CORPORATE.ERROR');
  }
};
</script>

<template>
  <div
    v-if="enabled && accountId && role"
    ref="toolbar"
    class="relative z-50 flex flex-wrap items-center gap-2 border-b border-n-weak bg-n-background px-2 py-1 text-sm"
  >
    <button
      type="button"
      class="rounded px-3 py-2 bg-n-alpha-2"
      @click="toggle"
    >
      {{
        t(
          isSupervisor
            ? 'CORPORATE.ALL_CLIENTS'
            : role === 'manager'
              ? 'CORPORATE.MY_CLIENTS'
              : 'CORPORATE.CHANNELS'
        )
      }}
    </button>
    <span v-if="gatewayMode === 'mock'" class="ms-3 text-xs text-n-slate-11">{{
      t('CORPORATE.TEST_MODE')
    }}</span>
    <div class="ms-auto flex flex-wrap items-center justify-end gap-3">
      <SharingControls
        v-if="role === 'manager'"
        :account-id="accountId"
        compact
      />
      <BrowserNotifications
        v-if="['manager', 'supervisor'].includes(role)"
        :key="accountId"
        :account-id="accountId"
      />
      <InterfaceScale />
    </div>
    <PipelineHealth v-if="isSupervisor" :account-id="accountId" compact />
    <section
      v-if="opened"
      class="absolute top-full end-0 w-full max-w-2xl max-h-[75vh] overflow-auto border border-n-weak bg-n-background p-4 shadow-lg"
    >
      <template v-if="role !== 'technical_admin'">
        <form class="flex flex-wrap gap-2 mb-4" @submit.prevent="start">
          <label for="corporate-phone">{{ t('CORPORATE.NEW_CHAT') }}</label>
          <input
            id="corporate-phone"
            :value="phone"
            type="text"
            required
            :placeholder="t('CORPORATE.PHONE_EXAMPLE')"
            class="rounded border border-n-weak bg-n-background px-2"
            @input="phone = formatRecipient($event.target.value, 'telegram')"
          />
          <button
            type="submit"
            :disabled="busy"
            class="rounded bg-n-alpha-2 px-3"
          >
            {{ t('CORPORATE.START') }}
          </button>
        </form>
        <label v-if="isSupervisor" class="flex flex-col gap-1 mb-4">
          {{ t('CORPORATE.REASON') }}
          <input
            v-model="reason"
            maxlength="500"
            class="rounded border border-n-weak bg-n-background px-2 py-1"
          />
        </label>
        <label v-if="isSupervisor" class="flex flex-col gap-1 mb-4">
          {{ t('CORPORATE.FILTER_OWNER') }}
          <select
            v-model="ownerFilter"
            class="rounded border border-n-weak bg-n-background"
            @change="filterClients"
          >
            <option value="">{{ t('CORPORATE.FILTER_ALL') }}</option>
            <option value="unassigned">{{ t('CORPORATE.UNASSIGNED') }}</option>
            <option
              v-for="manager in managers"
              :key="manager.id"
              :value="String(manager.id)"
            >
              {{ manager.name }}
            </option>
          </select>
        </label>
        <p v-if="message" role="status">{{ message }}</p>
        <ul class="flex flex-col gap-3">
          <li
            v-for="client in clients"
            :key="client.id"
            class="flex flex-wrap items-center gap-2 border-b border-n-weak pb-2"
          >
            <button type="button" @click="openChat(client)">
              {{ client.name }}
            </button>
            <span>{{ client.phone_number }}</span>
            <template v-if="isSupervisor">
              <span>{{
                managers.find(manager => manager.id === owners[client.id])
                  ?.name || t('CORPORATE.UNASSIGNED')
              }}</span>
              <select
                v-model="selection[client.id]"
                class="rounded border border-n-weak bg-n-background"
              >
                <option :value="null">{{ t('CORPORATE.UNASSIGNED') }}</option>
                <option
                  v-for="manager in managers"
                  :key="manager.id"
                  :value="manager.id"
                >
                  {{ manager.name }}
                </option>
              </select>
              <button type="button" :disabled="busy" @click="transfer(client)">
                {{ t('CORPORATE.TRANSFER') }}
              </button>
            </template>
          </li>
        </ul>
        <div class="flex gap-3 mt-4">
          <button
            type="button"
            :disabled="busy || page === 1"
            @click="turnPage(-1)"
          >
            {{ t('CORPORATE.PREVIOUS') }}
          </button>
          <span>{{ page }}</span>
          <button
            type="button"
            :disabled="busy || clients.length < 15"
            @click="turnPage(1)"
          >
            {{ t('CORPORATE.NEXT') }}
          </button>
        </div>
        <StaffManagement v-if="isSupervisor" :account-id="accountId" />
        <CrmEmployees
          v-if="isSupervisor && corporateCrmEnabled"
          :account-id="accountId"
        />
        <section v-if="isSupervisor" class="mt-4 border-t border-n-weak pt-4">
          <button type="button" @click="loadAudit(0)">
            {{ t('CORPORATE.AUDIT') }}
          </button>
          <template v-if="audit">
            <ul class="flex flex-col gap-2 my-3">
              <li v-for="entry in audit" :key="entry.id">
                {{
                  t('CORPORATE.AUDIT_ENTRY', {
                    contact: entry.contact_id,
                    actor: entry.actor_id,
                    from: entry.old_owner_id || t('CORPORATE.UNASSIGNED'),
                    to: entry.new_owner_id || t('CORPORATE.UNASSIGNED'),
                    reason: entry.reason,
                    date: new Date(entry.created_at).toLocaleString(),
                  })
                }}
              </li>
            </ul>
            <button
              type="button"
              :disabled="auditPage === 1"
              @click="loadAudit(-1)"
            >
              {{ t('CORPORATE.PREVIOUS') }}
            </button>
            <span class="mx-3">{{ auditPage }}</span>
            <button
              type="button"
              :disabled="audit.length < 50"
              @click="loadAudit(1)"
            >
              {{ t('CORPORATE.NEXT') }}
            </button>
          </template>
        </section>
      </template>
      <div v-else class="flex flex-col gap-6">
        <TelegramSetup :account-id="accountId" />
        <MaxSetup :account-id="accountId" />
      </div>
    </section>
  </div>
</template>
