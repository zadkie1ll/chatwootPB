<script setup>
/* global axios */
import { ref, onMounted } from 'vue';
import { useI18n } from 'vue-i18n';
const props = defineProps({
  accountId: { type: [String, Number], required: true },
});
const { t } = useI18n();
const managers = ref([]);
const employees = ref([]);
const selection = ref({});
const error = ref('');
const busy = ref(false);
const endpoint = `/api/v1/accounts/${props.accountId}/corporate/crm/employees`;
const load = async () => {
  busy.value = true;
  error.value = '';
  try {
    const { data } = await axios.get(endpoint);
    managers.value = data.managers;
    employees.value = data.employees;
    selection.value = Object.fromEntries(
      data.managers.map(member => [member.id, member.bitrix_user_id || ''])
    );
  } catch (failure) {
    error.value = failure.response?.data?.error || t('CORPORATE.CRM.ERROR');
  } finally {
    busy.value = false;
  }
};
onMounted(load);
const save = async member => {
  busy.value = true;
  error.value = '';
  try {
    await axios.put(`${endpoint}/${member.id}`, {
      bitrix_user_id: selection.value[member.id],
    });
    await load();
  } catch (failure) {
    error.value = failure.response?.data?.error || t('CORPORATE.CRM.ERROR');
  } finally {
    busy.value = false;
  }
};
</script>

<template>
  <section class="mt-4 border-t border-n-weak pt-4 flex flex-col gap-3">
    <h2 class="text-lg font-semibold">{{ t('CORPORATE.CRM.EMPLOYEES') }}</h2>
    <p>{{ t('CORPORATE.CRM.MAPPING_HELP') }}</p>
    <button type="button" :disabled="busy" @click="load">
      {{ t('CORPORATE.CRM.REFRESH') }}
    </button>
    <p v-if="error" role="alert">{{ error }}</p>
    <ul class="flex flex-col gap-3">
      <li
        v-for="member in managers"
        :key="member.id"
        class="flex flex-wrap items-center gap-2"
      >
        <span>{{ member.name }}</span>
        <select
          v-model="selection[member.id]"
          :aria-label="t('CORPORATE.CRM.EMPLOYEE_FOR', { name: member.name })"
          class="rounded border border-n-weak bg-n-background p-2"
        >
          <option value="">{{ t('CORPORATE.CRM.NOT_MAPPED') }}</option>
          <option
            v-for="employee in employees"
            :key="employee.id"
            :value="employee.id"
          >
            {{ employee.name }} ({{ employee.id }})
          </option>
        </select>
        <button
          type="button"
          :disabled="busy || !selection[member.id]"
          @click="save(member)"
        >
          {{ t('CORPORATE.CRM.SAVE_MAPPING') }}
        </button>
      </li>
    </ul>
  </section>
</template>
