import { computed, watch, onBeforeUnmount } from 'vue';
import { useUISettings } from 'dashboard/composables/useUISettings';

export const INTERFACE_SCALES = [65, 85, 100, 120];
const SCALE_CLASSES = {
  65: ['[zoom:0.65]', '[--interface-scale:0.65]'],
  85: ['[zoom:0.85]', '[--interface-scale:0.85]'],
  100: ['[zoom:1]', '[--interface-scale:1]'],
  120: ['[zoom:1.2]', '[--interface-scale:1.2]'],
};

// Pointer events report screen coordinates; layout sizes use unscaled CSS pixels.
export const interfaceCoordinate = value =>
  value / (Number(document.documentElement.dataset.interfaceScale) || 1);

export const useInterfaceScale = () => {
  const { uiSettings, updateUISettings } = useUISettings();
  const scale = computed(() => {
    const saved = uiSettings.value.corporate_interface_scale;
    return INTERFACE_SCALES.includes(saved) ? saved : 100;
  });
  const updateScale = value => {
    const next = Number(value);
    if (INTERFACE_SCALES.includes(next))
      updateUISettings({ corporate_interface_scale: next });
  };
  return { scale, updateScale };
};

export const useInterfaceScaleDOM = () => {
  const { scale } = useInterfaceScale();
  const root = document.documentElement;
  const clear = () => {
    root.classList.remove(...Object.values(SCALE_CLASSES).flat());
    delete root.dataset.interfaceScale;
  };
  watch(
    scale,
    value => {
      clear();
      if (!window.chatwootConfig?.corporateAccessEnabled) return;
      root.classList.add(...SCALE_CLASSES[value]);
      root.dataset.interfaceScale = String(value / 100);
    },
    { immediate: true }
  );
  onBeforeUnmount(clear);
};
