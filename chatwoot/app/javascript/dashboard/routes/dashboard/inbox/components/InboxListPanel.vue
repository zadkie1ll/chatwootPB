<script setup>
import { computed, ref, useCssVars } from 'vue';
import { useLayoutPreference } from 'dashboard/composables/useLayoutPreference';
import { useI18n } from 'vue-i18n';

const { t } = useI18n();
const MIN_WIDTH = 256;
const MAX_WIDTH = 640;
const DEFAULT_WIDTH = 340;
const KEYBOARD_STEP = 24;
const panel = ref(null);
const collapsed = useLayoutPreference('inbox-list-collapsed', false);
const width = useLayoutPreference('inbox-list-width', DEFAULT_WIDTH);
useCssVars(() => ({
  'inbox-list-width': `${Math.min(MAX_WIDTH, Math.max(MIN_WIDTH, width.value)) / 16}rem`,
}));
const toggleLabel = computed(() =>
  t(
    collapsed.value
      ? 'CORPORATE.LAYOUT.SHOW_INBOX'
      : 'CORPORATE.LAYOUT.HIDE_INBOX'
  )
);
let drag = null;
const startResize = event => {
  if (event.button !== 0) return;
  const direction = getComputedStyle(panel.value).direction === 'rtl' ? -1 : 1;
  drag = { x: event.clientX, width: width.value, direction };
  event.currentTarget.setPointerCapture(event.pointerId);
};
const resize = event => {
  if (!drag) return;
  width.value = Math.min(
    MAX_WIDTH,
    Math.max(MIN_WIDTH, drag.width + (event.clientX - drag.x) * drag.direction)
  );
};
const resizeWithKeyboard = event => {
  if (!['ArrowLeft', 'ArrowRight', 'Home'].includes(event.key)) return;
  event.preventDefault();
  const direction = getComputedStyle(panel.value).direction === 'rtl' ? -1 : 1;
  const delta = event.key === 'ArrowRight' ? KEYBOARD_STEP : -KEYBOARD_STEP;
  width.value =
    event.key === 'Home'
      ? DEFAULT_WIDTH
      : Math.min(
          MAX_WIDTH,
          Math.max(MIN_WIDTH, width.value + delta * direction)
        );
};
</script>

<template>
  <div
    ref="panel"
    class="relative flex flex-col h-full shrink-0 border-e border-n-weak"
    :class="
      collapsed
        ? 'w-10'
        : 'w-full lg:w-[var(--inbox-list-width)] lg:max-w-[50vw]'
    "
  >
    <div class="flex justify-end px-1 py-1">
      <button
        type="button"
        class="flex items-center justify-center rounded p-1 text-n-slate-11 hover:bg-n-alpha-2"
        :title="toggleLabel"
        :aria-label="toggleLabel"
        :aria-expanded="!collapsed"
        @click="collapsed = !collapsed"
      >
        <span
          :class="
            collapsed ? 'i-lucide-panel-left-open' : 'i-lucide-panel-left-close'
          "
          class="size-4"
        />
      </button>
    </div>
    <div v-show="!collapsed" class="flex flex-col flex-1 min-h-0 min-w-0">
      <slot />
    </div>
    <div
      v-if="!collapsed"
      role="separator"
      tabindex="0"
      aria-orientation="vertical"
      :aria-label="t('CORPORATE.LAYOUT.RESIZE_INBOX')"
      :aria-valuenow="width"
      :aria-valuemin="MIN_WIDTH"
      :aria-valuemax="MAX_WIDTH"
      class="absolute inset-y-0 -end-1 z-10 hidden w-2 cursor-col-resize touch-none hover:bg-n-alpha-2 focus:bg-n-alpha-2 lg:block"
      @pointerdown.prevent="startResize"
      @pointermove="resize"
      @pointerup="drag = null"
      @pointercancel="drag = null"
      @lostpointercapture="drag = null"
      @keydown="resizeWithKeyboard"
    />
  </div>
</template>
