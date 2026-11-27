<script setup>
/* global axios */
import { ref, computed, onMounted, onBeforeUnmount } from 'vue';
import { useI18n } from 'vue-i18n';
import { onKeyStroke } from '@vueuse/core';
const props = defineProps({
  accountId: { type: [String, Number], required: true },
  member: { type: Object, default: null },
  crmEnabled: { type: Boolean, default: false },
});
const emit = defineEmits(['saved', 'close']);
const panel = ref(null);
const { t } = useI18n();
const mode = ref(props.crmEnabled ? 'bitrix' : 'manual');
const name = ref(props.member?.name || '');
const email = ref(props.member?.email || '');
const password = ref('');
const showPassword = ref(false);
const bitrixId = ref(props.member?.bitrix_user_id || '');
const employees = ref([]);
const assigned = ref([]);
const busy = ref(false);
const loadingCrm = ref(false);
const error = ref('');
const crmError = ref('');
const created = ref(null);
const importing = computed(() => !props.member && mode.value === 'bitrix');
const endpoint = `/api/v1/accounts/${props.accountId}/corporate`;
const loadCrm = async () => {
  loadingCrm.value = true;
  crmError.value = '';
  try {
    const { data } = await axios.get(`${endpoint}/crm/employees`);
    employees.value = data.employees;
    assigned.value = data.assigned_ids;
  } catch {
    crmError.value = t('CORPORATE.CRM.ERROR');
  } finally {
    loadingCrm.value = false;
  }
};
onKeyStroke('Escape', () => {
  if (!busy.value) emit('close');
});
onMounted(() => {
  panel.value?.focus();
  if (props.crmEnabled) loadCrm();
});
onBeforeUnmount(() => {
  password.value = '';
});
const selectEmployee = () => {
  if (!importing.value) return;
  const employee = employees.value.find(row => row.id === bitrixId.value);
  name.value = employee?.name || '';
  email.value = employee?.email || '';
};
const generate = () => {
  const bytes = crypto.getRandomValues(new Uint8Array(18));
  password.value =
    'Aa9!' +
    btoa(String.fromCharCode(...bytes))
      .replace(/\+/g, '-')
      .replace(/\//g, '_');
};
const save = async () => {
  busy.value = true;
  error.value = '';
  try {
    const data = { name: name.value.trim(), email: email.value.trim() };
    if (password.value) data.password = password.value;
    if (
      importing.value ||
      (props.member &&
        bitrixId.value &&
        bitrixId.value !== props.member.bitrix_user_id)
    )
      data.bitrix_user_id = bitrixId.value;
    const response = props.member
      ? await axios.patch(`${endpoint}/staff/${props.member.id}`, data)
      : await axios.post(`${endpoint}/staff`, data);
    emit('saved');
    if (props.member) emit('close');
    else created.value = response.data;
  } catch (failure) {
    error.value = failure.response?.data?.error || t('CORPORATE.STAFF_ERROR');
  } finally {
    busy.value = false;
  }
};
const copy = async () => {
  try {
    await navigator.clipboard.writeText(
      `${created.value.email}\n${password.value}`
    );
  } catch {
    error.value = t('CORPORATE.ADMIN.COPY_FAILED');
  }
};
</script>

<template>
  <Teleport to="body">
    <div
      class="fixed inset-0 z-[70] flex items-center justify-center bg-black/50 p-4"
      @click.self="!busy && emit('close')"
    >
      <section
        ref="panel"
        tabindex="-1"
        role="dialog"
        aria-modal="true"
        :aria-label="t(member ? 'CORPORATE.ADMIN.EDIT' : 'CORPORATE.ADMIN.ADD')"
        class="flex max-h-[calc(90dvh/var(--interface-scale,1))] w-full max-w-xl flex-col gap-4 overflow-auto rounded-xl border border-n-weak bg-n-background p-6 shadow-xl"
      >
        <h2 class="text-lg font-semibold">
          {{ t(member ? 'CORPORATE.ADMIN.EDIT' : 'CORPORATE.ADMIN.ADD') }}
        </h2>
        <p v-if="error" role="alert" class="text-sm text-n-ruby-11">
          {{ error }}
        </p>
        <template v-if="created">
          <p role="status">{{ t('CORPORATE.STAFF_CREATED') }}</p>
          <p class="text-sm">{{ t('CORPORATE.ADMIN.CREDENTIALS_ONCE') }}</p>
          <p class="select-all font-mono text-sm">{{ created.email }}</p>
          <code class="select-all break-all rounded bg-n-alpha-2 p-3">{{
            password
          }}</code>
          <div class="flex gap-2">
            <button
              type="button"
              class="rounded bg-n-alpha-2 px-3 py-2"
              @click="copy"
            >
              {{ t('CORPORATE.ADMIN.COPY') }}
            </button>
            <button
              type="button"
              class="rounded px-3 py-2"
              @click="emit('close')"
            >
              {{ t('CORPORATE.ADMIN.DONE') }}
            </button>
          </div>
        </template>
        <form v-else class="flex flex-col gap-4" @submit.prevent="save">
          <label
            v-if="!member && crmEnabled"
            class="flex flex-col gap-1 text-sm"
          >
            {{ t('CORPORATE.ADMIN.SOURCE') }}
            <select
              v-model="mode"
              class="rounded border border-n-weak bg-n-background p-2"
              @change="selectEmployee"
            >
              <option value="bitrix">
                {{ t('CORPORATE.ADMIN.FROM_BITRIX') }}
              </option>
              <option value="manual">{{ t('CORPORATE.ADMIN.MANUAL') }}</option>
            </select>
          </label>
          <div
            v-if="crmEnabled && (importing || member?.active)"
            class="flex flex-col gap-2"
          >
            <label class="flex flex-col gap-1 text-sm">
              {{ t('CORPORATE.CRM.EMPLOYEES') }}
              <select
                v-model="bitrixId"
                :required="importing"
                :disabled="loadingCrm"
                class="rounded border border-n-weak bg-n-background p-2"
                @change="selectEmployee"
              >
                <option value="" :disabled="!!member?.bitrix_user_id">
                  {{ t('CORPORATE.CRM.NOT_MAPPED') }}
                </option>
                <option
                  v-if="
                    member?.bitrix_user_id &&
                    !employees.some(row => row.id === member.bitrix_user_id)
                  "
                  :value="member.bitrix_user_id"
                >
                  {{
                    t('CORPORATE.ADMIN.BITRIX_ID', {
                      id: member.bitrix_user_id,
                    })
                  }}
                </option>
                <option
                  v-for="employee in employees"
                  :key="employee.id"
                  :value="employee.id"
                  :disabled="
                    assigned.includes(employee.id) &&
                    employee.id !== member?.bitrix_user_id
                  "
                >
                  {{ employee.name }} — {{ employee.email }} ({{ employee.id }})
                </option>
              </select>
            </label>
            <p v-if="crmError" role="alert" class="text-sm text-n-ruby-11">
              {{ crmError }}
            </p>
            <button
              v-if="crmError"
              type="button"
              class="text-start text-sm text-n-blue-text"
              @click="loadCrm"
            >
              {{ t('CORPORATE.CRM.REFRESH') }}
            </button>
          </div>
          <label class="flex flex-col gap-1 text-sm"
            >{{ t('CORPORATE.STAFF_NAME')
            }}<input
              v-model="name"
              :readonly="importing"
              required
              maxlength="100"
              class="rounded border border-n-weak bg-n-background p-2"
          /></label>
          <label class="flex flex-col gap-1 text-sm"
            >{{ t('CORPORATE.STAFF_EMAIL')
            }}<input
              v-model="email"
              :readonly="importing"
              type="email"
              required
              class="rounded border border-n-weak bg-n-background p-2"
          /></label>
          <label class="flex flex-col gap-1 text-sm"
            >{{
              t(
                member
                  ? 'CORPORATE.ADMIN.NEW_PASSWORD'
                  : 'CORPORATE.STAFF_PASSWORD'
              )
            }}<input
              v-model="password"
              :type="showPassword ? 'text' : 'password'"
              autocomplete="new-password"
              :required="!member"
              minlength="12"
              maxlength="128"
              class="rounded border border-n-weak bg-n-background p-2"
          /></label>
          <div class="flex flex-wrap gap-3 text-sm">
            <button type="button" class="text-n-blue-text" @click="generate">
              {{ t('CORPORATE.ADMIN.GENERATE') }}
            </button>
            <button type="button" @click="showPassword = !showPassword">
              {{
                t(
                  showPassword
                    ? 'CORPORATE.ADMIN.HIDE_PASSWORD'
                    : 'CORPORATE.ADMIN.SHOW_PASSWORD'
                )
              }}
            </button>
          </div>
          <p v-if="member" class="text-xs text-n-slate-11">
            {{ t('CORPORATE.ADMIN.SESSION_NOTICE') }}
          </p>
          <div
            v-if="member"
            class="rounded bg-n-alpha-2 p-3 text-xs text-n-slate-11"
          >
            {{
              t('CORPORATE.ADMIN.IDENTITY', {
                account: accountId,
                user: member.id,
              })
            }}
          </div>
          <div class="flex justify-end gap-2">
            <button
              type="button"
              :disabled="busy"
              class="rounded px-3 py-2"
              @click="emit('close')"
            >
              {{ t('CORPORATE.MESSAGE.CANCEL') }}
            </button>
            <button
              type="submit"
              :disabled="busy || (importing && !bitrixId)"
              class="rounded bg-n-alpha-2 px-3 py-2 text-n-blue-text"
            >
              {{
                t(
                  member ? 'CORPORATE.MESSAGE.SAVE' : 'CORPORATE.CREATE_MANAGER'
                )
              }}
            </button>
          </div>
        </form>
      </section>
    </div>
  </Teleport>
</template>
