<script setup>
import { useI18n } from 'vue-i18n';
import {
  INTERFACE_SCALES,
  useInterfaceScale,
} from 'dashboard/composables/useInterfaceScale';
const { t } = useI18n();
const { scale, updateScale } = useInterfaceScale();
</script>

<template>
  <label class="flex shrink-0 items-center gap-2 text-xs text-n-slate-11">
    <span class="hidden sm:inline">{{ t('CORPORATE.LAYOUT.SCALE') }}</span>
    <select
      :value="scale"
      :aria-label="t('CORPORATE.LAYOUT.SCALE')"
      class="rounded border border-n-weak bg-n-background px-2 py-1 text-sm text-n-slate-12"
      @change="updateScale($event.target.value)"
    >
      <option v-for="value in INTERFACE_SCALES" :key="value" :value="value">
        {{ value }}%
      </option>
    </select>
  </label>
</template>
