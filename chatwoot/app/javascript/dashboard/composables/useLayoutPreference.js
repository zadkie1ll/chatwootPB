import { ref, watch } from 'vue';
import { LocalStorage } from 'shared/helpers/localStorage';

export const useLayoutPreference = (key, defaultValue) => {
  const stored = LocalStorage.get(key);
  const value = ref(
    typeof stored === typeof defaultValue ? stored : defaultValue
  );
  watch(
    value,
    preference => {
      try {
        LocalStorage.set(key, preference);
      } catch {
        // The control still works when browser storage is unavailable.
      }
    },
    { flush: 'sync' }
  );
  return value;
};
