<script setup>
/* global axios */
import { ref, computed, watch, onBeforeUnmount } from 'vue';
import { useI18n } from 'vue-i18n';
import {
  corporateRole,
  corporateCrmEnabled,
} from 'dashboard/composables/useCorporate';
import StaffEditor from './StaffEditor.vue';
const props = defineProps({
  accountId: { type: [String, Number], required: true },
});
const { t } = useI18n();
const canManage = computed(() => corporateRole.value === 'supervisor');
const staff = ref([]);
const summary = ref({});
const query = ref('');
const status = ref('all');
const page = ref(1);
const total = ref(0);
const perPage = ref(25);
const busy = ref(false);
const error = ref('');
const editorOpen = ref(false);
const selected = ref(null);
const endpoint = computed(
  () => `/api/v1/accounts/${props.accountId}/corporate/staff`
);
let revision = 0;
const load = async () => {
  if (!canManage.value) return;
  revision += 1;
  const expected = revision;
  busy.value = true;
  error.value = '';
  try {
    const { data } = await axios.get(`${endpoint.value}/directory`, {
      params: { q: query.value, status: status.value, page: page.value },
    });
    if (expected !== revision) return;
    staff.value = data.payload;
    summary.value = data.meta.summary;
    total.value = data.meta.total;
    perPage.value = data.meta.per_page;
  } catch {
    if (expected === revision) error.value = t('CORPORATE.ERROR');
  } finally {
    if (expected === revision) busy.value = false;
  }
};
watch(
  [() => props.accountId, canManage],
  () => {
    revision += 1;
    staff.value = [];
    summary.value = {};
    editorOpen.value = false;
    query.value = '';
    status.value = 'all';
    page.value = 1;
    load();
  },
  { immediate: true }
);
onBeforeUnmount(() => {
  revision += 1;
});
const filter = () => {
  page.value = 1;
  load();
};
const turn = delta => {
  page.value += delta;
  load();
};
const edit = member => {
  selected.value = member;
  editorOpen.value = true;
};
const toggleAccess = async member => {
  const key = member.active
    ? 'CORPORATE.DISABLE_CONFIRM'
    : 'CORPORATE.ADMIN.ENABLE_CONFIRM';
  if (!window.confirm(t(key, { name: member.name }))) return;
  busy.value = true;
  error.value = '';
  try {
    if (member.active) await axios.delete(`${endpoint.value}/${member.id}`);
    else await axios.post(`${endpoint.value}/${member.id}/enable`);
    await load();
  } catch (failure) {
    error.value = failure.response?.data?.error || t('CORPORATE.ERROR');
  } finally {
    busy.value = false;
  }
};
const date = value =>
  value ? new Date(value).toLocaleString() : t('CORPORATE.ADMIN.NEVER');
</script>

<template>
  <main
    v-if="canManage"
    class="flex min-h-0 min-w-0 flex-1 flex-col gap-6 overflow-auto p-4 lg:p-8"
  >
    <header class="flex flex-wrap items-start justify-between gap-4">
      <div>
        <h1 class="text-2xl font-semibold">{{ t('CORPORATE.ADMIN.TITLE') }}</h1>
        <p class="mt-1 text-sm text-n-slate-11">
          {{ t('CORPORATE.ADMIN.SUBTITLE') }}
        </p>
      </div>
      <button
        type="button"
        class="flex items-center gap-2 rounded-lg bg-n-alpha-2 px-4 py-2 text-sm text-n-blue-text"
        @click="edit(null)"
      >
        <span class="i-lucide-user-plus size-4" />{{ t('CORPORATE.ADMIN.ADD') }}
      </button>
    </header>
    <div class="grid grid-cols-2 gap-3 lg:grid-cols-4">
      <div
        v-for="key in ['total', 'active', 'disabled', 'mapped']"
        :key="key"
        class="rounded-xl border border-n-weak bg-n-alpha-1 p-4"
      >
        <p class="text-xs text-n-slate-11">
          {{ t(`CORPORATE.ADMIN.COUNTER.${key}`) }}
        </p>
        <p class="mt-1 text-2xl font-semibold">{{ summary[key] ?? '—' }}</p>
      </div>
    </div>
    <form class="flex flex-wrap items-end gap-3" @submit.prevent="filter">
      <label class="flex min-w-0 flex-1 flex-col gap-1 text-xs text-n-slate-11"
        >{{ t('CORPORATE.ADMIN.SEARCH')
        }}<input
          v-model="query"
          maxlength="100"
          :placeholder="t('CORPORATE.ADMIN.SEARCH_PLACEHOLDER')"
          class="rounded-lg border border-n-weak bg-n-background px-3 py-2 text-sm text-n-slate-12"
      /></label>
      <label class="flex flex-col gap-1 text-xs text-n-slate-11"
        >{{ t('CORPORATE.ADMIN.STATUS')
        }}<select
          v-model="status"
          class="rounded-lg border border-n-weak bg-n-background px-3 py-2 text-sm text-n-slate-12"
          @change="filter"
        >
          <option value="all">{{ t('CORPORATE.ADMIN.ALL') }}</option>
          <option value="active">{{ t('CORPORATE.ADMIN.ACTIVE') }}</option>
          <option value="disabled">{{ t('CORPORATE.STAFF_DISABLED') }}</option>
        </select></label
      >
      <button
        type="submit"
        :disabled="busy"
        class="rounded-lg bg-n-alpha-2 px-4 py-2 text-sm"
      >
        {{ t('CORPORATE.ADMIN.FIND') }}
      </button>
      <button
        type="button"
        :disabled="busy"
        class="rounded-lg px-3 py-2 text-sm"
        @click="load"
      >
        {{ t('CORPORATE.CRM.REFRESH') }}
      </button>
    </form>
    <p v-if="error" role="alert" class="text-sm text-n-ruby-11">{{ error }}</p>
    <p v-if="busy" role="status" class="text-sm text-n-slate-11">
      {{ t('CORPORATE.ADMIN.LOADING') }}
    </p>
    <div class="overflow-x-auto rounded-xl border border-n-weak">
      <table class="w-full min-w-[60rem] text-start text-sm">
        <thead class="bg-n-alpha-1 text-xs text-n-slate-11">
          <tr>
            <th
              v-for="key in [
                'employee',
                'access',
                'clients',
                'conversations',
                'bitrix',
                'notifications',
                'login',
                'actions',
              ]"
              :key="key"
              scope="col"
              class="p-3 text-start font-medium"
            >
              {{ t(`CORPORATE.ADMIN.COLUMN.${key}`) }}
            </th>
          </tr>
        </thead>
        <tbody>
          <tr
            v-for="member in staff"
            :key="member.id"
            class="border-t border-n-weak align-top"
          >
            <td class="p-3">
              <p class="font-medium">{{ member.name }}</p>
              <p class="mt-1 text-xs text-n-slate-11">{{ member.email }}</p>
            </td>
            <td class="p-3">
              <span
                :class="member.active ? 'text-n-teal-11' : 'text-n-slate-11'"
                >{{
                  t(
                    member.active
                      ? 'CORPORATE.ADMIN.ACTIVE'
                      : 'CORPORATE.STAFF_DISABLED'
                  )
                }}</span
              >
              <p v-if="member.absence" class="mt-1 text-xs text-n-blue-text">
                {{ t('CORPORATE.ADMIN.ABSENT') }}
              </p>
            </td>
            <td class="p-3">{{ member.clients_count }}</td>
            <td class="p-3">{{ member.conversations_count }}</td>
            <td class="p-3">
              {{
                member.bitrix_user_id
                  ? t('CORPORATE.ADMIN.BITRIX_ID', {
                      id: member.bitrix_user_id,
                    })
                  : t('CORPORATE.CRM.NOT_MAPPED')
              }}
            </td>
            <td class="p-3 text-xs">
              {{ t('CORPORATE.ADMIN.PUSH_DEVICES', member.notifications) }}
            </td>
            <td class="p-3 text-xs text-n-slate-11">
              {{ date(member.last_sign_in_at) }}
            </td>
            <td class="p-3">
              <div class="flex flex-col items-start gap-2">
                <button
                  type="button"
                  class="text-n-blue-text"
                  :disabled="busy"
                  @click="edit(member)"
                >
                  {{ t('CORPORATE.ADMIN.EDIT') }}</button
                ><button
                  type="button"
                  :disabled="busy"
                  class="text-n-slate-11"
                  @click="toggleAccess(member)"
                >
                  {{
                    t(
                      member.active
                        ? 'CORPORATE.DISABLE_MANAGER'
                        : 'CORPORATE.ADMIN.ENABLE'
                    )
                  }}
                </button>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
      <p
        v-if="!busy && !staff.length"
        class="p-6 text-center text-sm text-n-slate-11"
      >
        {{ t('CORPORATE.ADMIN.EMPTY') }}
      </p>
    </div>
    <nav
      class="flex items-center justify-end gap-4 text-sm"
      :aria-label="t('CORPORATE.ADMIN.PAGINATION')"
    >
      <span>{{ t('CORPORATE.ADMIN.FOUND', { total }) }}</span
      ><button type="button" :disabled="busy || page === 1" @click="turn(-1)">
        {{ t('CORPORATE.PREVIOUS') }}</button
      ><span>{{ page }}</span
      ><button
        type="button"
        :disabled="busy || page * perPage >= total"
        @click="turn(1)"
      >
        {{ t('CORPORATE.NEXT') }}
      </button>
    </nav>
    <p class="text-xs text-n-slate-11">{{ t('CORPORATE.ADMIN.PUSH_HELP') }}</p>
    <StaffEditor
      v-if="editorOpen"
      :account-id="accountId"
      :member="selected"
      :crm-enabled="corporateCrmEnabled"
      @saved="load"
      @close="editorOpen = false"
    />
  </main>
  <p v-else role="alert" class="p-6">{{ t('CORPORATE.ACCESS_DENIED') }}</p>
</template>
