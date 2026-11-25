<script setup>
/* global axios */
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAccount } from 'dashboard/composables/useAccount';
import { corporateRole } from 'dashboard/composables/useCorporate';
const props = defineProps({
  id: { type: [Number, String], required: true },
  conversationId: { type: [Number, String], required: true },
  content: { type: String, default: '' },
  sourceId: { type: String, default: '' },
  messageType: { type: Number, required: true },
  private: { type: Boolean, default: false },
  attributes: { type: Object, default: () => ({}) },
});
const { accountId } = useAccount();
const { t } = useI18n();
const editing = ref(false);
const draft = ref('');
const busy = ref(false);
const error = ref('');
let revision = 0;
watch(
  () => [props.id, props.conversationId, accountId.value],
  () => {
    revision += 1;
    editing.value = false;
    busy.value = false;
    error.value = '';
  }
);
const enabled = computed(() =>
  ['manager', 'supervisor'].includes(corporateRole.value)
);
const editPending = computed(() =>
  ['pending', 'in_flight', 'unknown'].includes(
    props.attributes.corporateEditStatus
  )
);
const canEdit = computed(
  () =>
    enabled.value &&
    props.messageType === 1 &&
    !props.private &&
    !!props.sourceId &&
    !props.attributes.deleted
);
const fileState = computed(
  () =>
    props.attributes.corporateAttachmentsState ||
    props.attributes.corporateMediaState
);
const begin = () => {
  draft.value = props.content;
  error.value = '';
  editing.value = true;
};
const save = async () => {
  const expected = revision;
  busy.value = true;
  error.value = '';
  try {
    await axios.put(
      `/api/v1/accounts/${accountId.value}/corporate/conversations/${props.conversationId}/messages/${props.id}/edit`,
      { content: draft.value }
    );
    if (expected === revision) editing.value = false;
  } catch (failure) {
    if (expected === revision)
      error.value =
        failure.response?.data?.error || t('CORPORATE.MESSAGE.EDIT_FAILED');
  } finally {
    if (expected === revision) busy.value = false;
  }
};
</script>

<template>
  <div v-if="enabled" class="flex flex-col gap-1 text-xs px-2 py-1">
    <p v-if="fileState === 'pending'" role="status">
      {{ t('CORPORATE.MESSAGE.MEDIA_PENDING') }}
    </p>
    <p
      v-if="
        fileState === 'rejected' ||
        fileState === 'failed' ||
        attributes.corporateMediaError
      "
      role="alert"
    >
      {{ t('CORPORATE.MESSAGE.MEDIA_FAILED') }}
    </p>
    <p v-if="editPending" role="status">
      {{ t('CORPORATE.MESSAGE.EDIT_PENDING') }}
    </p>
    <p
      v-else-if="
        attributes.corporateEditStatus === 'failed' ||
        attributes.corporateEditStatus === 'cancelled'
      "
      role="alert"
    >
      {{ t('CORPORATE.MESSAGE.EDIT_FAILED') }}
    </p>
    <p v-else-if="attributes.corporateEditedAt">
      {{ t('CORPORATE.MESSAGE.EDITED') }}
    </p>
    <template v-if="canEdit">
      <button
        v-if="!editing"
        type="button"
        class="underline text-start"
        :disabled="editPending"
        @click="begin"
      >
        {{ t('CORPORATE.MESSAGE.EDIT') }}
      </button>
      <form v-else class="flex flex-col gap-1" @submit.prevent="save">
        <textarea
          v-model="draft"
          :aria-label="t('CORPORATE.MESSAGE.EDIT_TEXT')"
          class="rounded border border-n-weak bg-n-background p-2"
          rows="3"
        />
        <div class="flex gap-3">
          <button type="submit" :disabled="busy">
            {{ t('CORPORATE.MESSAGE.SAVE') }}
          </button>
          <button type="button" :disabled="busy" @click="editing = false">
            {{ t('CORPORATE.MESSAGE.CANCEL') }}
          </button>
        </div>
      </form>
    </template>
    <p v-if="error" role="alert">{{ error }}</p>
  </div>
</template>
