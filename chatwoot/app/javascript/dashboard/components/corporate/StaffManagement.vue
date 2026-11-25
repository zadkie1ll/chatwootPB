<script setup>
/* global axios */
import { ref, onMounted } from 'vue';
import { useI18n } from 'vue-i18n';
const props = defineProps({
  accountId: { type: [String, Number], required: true },
});
const { t } = useI18n();
const staff = ref([]);
const name = ref('');
const email = ref('');
const password = ref('');
const busy = ref(false);
const message = ref('');
const endpoint = `/api/v1/accounts/${props.accountId}/corporate/staff`;
const load = async () => {
  staff.value = (await axios.get(endpoint)).data;
};
onMounted(() =>
  load().catch(() => {
    message.value = t('CORPORATE.ERROR');
  })
);
const create = async () => {
  busy.value = true;
  message.value = '';
  try {
    await axios.post(endpoint, {
      name: name.value,
      email: email.value,
      password: password.value,
    });
    name.value = '';
    email.value = '';
    password.value = '';
    await load();
    message.value = t('CORPORATE.STAFF_CREATED');
  } catch {
    message.value = t('CORPORATE.STAFF_ERROR');
  } finally {
    busy.value = false;
  }
};
const disable = async member => {
  if (!window.confirm(t('CORPORATE.DISABLE_CONFIRM', { name: member.name })))
    return;
  busy.value = true;
  try {
    await axios.delete(`${endpoint}/${member.id}`);
    await load();
  } catch (failure) {
    message.value = failure.response?.data?.error || t('CORPORATE.ERROR');
  } finally {
    busy.value = false;
  }
};
</script>

<template>
  <section class="border-t border-n-weak mt-4 pt-4 flex flex-col gap-3">
    <h2 class="text-lg font-semibold">{{ t('CORPORATE.STAFF_TITLE') }}</h2>
    <form class="flex flex-col gap-3" @submit.prevent="create">
      <label
        >{{ t('CORPORATE.STAFF_NAME')
        }}<input
          v-model="name"
          required
          maxlength="100"
          class="w-full rounded border border-n-weak bg-n-background p-2"
      /></label>
      <label
        >{{ t('CORPORATE.STAFF_EMAIL')
        }}<input
          v-model="email"
          type="email"
          required
          class="w-full rounded border border-n-weak bg-n-background p-2"
      /></label>
      <label
        >{{ t('CORPORATE.STAFF_PASSWORD')
        }}<input
          v-model="password"
          type="password"
          autocomplete="new-password"
          minlength="12"
          maxlength="128"
          required
          class="w-full rounded border border-n-weak bg-n-background p-2"
      /></label>
      <button
        type="submit"
        :disabled="busy"
        class="rounded bg-n-alpha-2 px-3 py-2"
      >
        {{ t('CORPORATE.CREATE_MANAGER') }}
      </button>
    </form>
    <p v-if="message" role="status">{{ message }}</p>
    <ul class="flex flex-col gap-2">
      <li
        v-for="member in staff"
        :key="member.id"
        class="flex flex-wrap gap-2 items-center"
      >
        <span>{{ member.name }} — {{ member.email }}</span>
        <button
          v-if="member.active"
          type="button"
          :disabled="busy"
          @click="disable(member)"
        >
          {{ t('CORPORATE.DISABLE_MANAGER') }}
        </button>
        <span v-else>{{ t('CORPORATE.STAFF_DISABLED') }}</span>
      </li>
    </ul>
  </section>
</template>
