/* global axios */
import { computed, ref, onMounted, onBeforeUnmount } from 'vue';
import { useEventListener } from '@vueuse/core';
import { useLayoutPreference } from 'dashboard/composables/useLayoutPreference';

const REFRESH_INTERVAL = 60000;
const TEST_POLL_INTERVAL = 2000;
const TEST_WAIT = 30000;
const WORKER_WAIT = 15000;

const withTimeout = async (operation, code) => {
  let timer;
  try {
    return await Promise.race([
      operation,
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error(code)), WORKER_WAIT);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
};
const waitForWorker = async () => {
  await withTimeout(
    navigator.serviceWorker.register('/sw.js', { updateViaCache: 'none' }),
    'worker_unavailable'
  );
  return withTimeout(navigator.serviceWorker.ready, 'worker_unavailable');
};

export const useBrowserNotifications = accountId => {
  const permission = ref('default');
  const optedOut = useLayoutPreference(
    `corporate-push-disabled-${accountId.value}`,
    false
  );
  const online = ref(navigator.onLine);
  const supported =
    window.isSecureContext &&
    'Notification' in window &&
    'serviceWorker' in navigator &&
    'PushManager' in window;
  const server = ref({});
  const busy = ref(false);
  const checking = ref(false);
  const error = ref('');
  let subscription = null;
  let refreshTimer;
  let testTimer;
  let testStarted = 0;
  let alive = true;
  let refreshing = false;
  const api = action =>
    `/api/v1/accounts/${accountId.value}/corporate/browser_push${action ? `/${action}` : ''}`;
  const post = (action, data = {}) =>
    axios.post(api(action), { endpoint: subscription?.endpoint, ...data });
  const setError = failure => {
    if (failure.response?.data?.error_code) {
      error.value = failure.response.data.error_code;
    } else if (
      failure.name === 'NotAllowedError' ||
      /permission denied/i.test(failure.message)
    ) {
      error.value = 'browser_blocked';
    } else if (failure.message === 'worker_unavailable') {
      error.value = 'worker_unavailable';
    } else {
      error.value = 'push_unavailable';
    }
  };
  const state = computed(() => {
    if (!supported) return 'unsupported';
    if (!online.value) return 'offline';
    if (permission.value === 'denied') return 'blocked';
    if (error.value || server.value.last_error) return 'error';
    if (server.value.configured === false) return 'not_configured';
    if (permission.value !== 'granted') return 'off';
    if (!server.value.connected) return 'disconnected';
    if (checking.value) return 'checking';
    if (server.value.confirmed_at) return 'verified';
    if (server.value.test_received_at) return 'confirm';
    return 'connected';
  });
  const refresh = async (sync = false) => {
    if (!supported || refreshing || !alive) return;
    refreshing = true;
    try {
      permission.value = Notification.permission;
      online.value = navigator.onLine;
      if (!online.value) return;
      if (permission.value === 'granted') {
        const registration = await waitForWorker();
        subscription = await registration.pushManager.getSubscription();
      } else {
        subscription = null;
      }
      let { data } = await post('status');
      if (
        sync &&
        !optedOut.value &&
        subscription &&
        !data.connected &&
        data.configured
      ) {
        data = (
          await axios.post(api(), { subscription: subscription.toJSON() })
        ).data;
      }
      if (!alive) return;
      server.value = data;
      error.value = '';
      if (data.test_received_at && checking.value) {
        checking.value = false;
        clearInterval(testTimer);
      }
    } catch (failure) {
      if (alive) setError(failure);
    } finally {
      refreshing = false;
    }
  };
  const enable = async () => {
    optedOut.value = false;
    busy.value = true;
    error.value = '';
    try {
      // Keep this in the user gesture: Safari requires an explicit click.
      permission.value = await Notification.requestPermission();
      if (permission.value !== 'granted') return;
      const registration = await waitForWorker();
      const existing = await registration.pushManager.getSubscription();
      if (existing) {
        await axios.delete(api(), { data: { endpoint: existing.endpoint } });
        await existing.unsubscribe();
      }
      subscription = await withTimeout(
        registration.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey: window.chatwootConfig.vapidPublicKey,
        }),
        'push_unavailable'
      );
      server.value = (
        await axios.post(api(), { subscription: subscription.toJSON() })
      ).data;
    } catch (failure) {
      setError(failure);
    } finally {
      busy.value = false;
    }
  };
  const disable = async () => {
    optedOut.value = true;
    busy.value = true;
    try {
      await axios.delete(api(), { data: { endpoint: subscription?.endpoint } });
      if (subscription) await subscription.unsubscribe();
      subscription = null;
      checking.value = false;
      clearInterval(testTimer);
      server.value = {
        ...server.value,
        connected: false,
        confirmed_at: null,
        test_received_at: null,
      };
      error.value = '';
    } catch (failure) {
      setError(failure);
    } finally {
      busy.value = false;
    }
  };
  const test = async () => {
    busy.value = true;
    error.value = '';
    try {
      server.value = (await post('test')).data;
      checking.value = !server.value.test_received_at;
      testStarted = Date.now();
      clearInterval(testTimer);
      testTimer = setInterval(() => {
        if (Date.now() - testStarted > TEST_WAIT) {
          checking.value = false;
          clearInterval(testTimer);
          return;
        }
        refresh();
      }, TEST_POLL_INTERVAL);
    } catch (failure) {
      setError(failure);
    } finally {
      busy.value = false;
    }
  };
  const confirm = async () => {
    busy.value = true;
    try {
      server.value = (await post('confirm')).data;
    } catch (failure) {
      setError(failure);
    } finally {
      busy.value = false;
    }
  };
  const update = () => refresh(true);
  useEventListener(window, 'focus', update);
  useEventListener(window, 'online', () => {
    online.value = true;
    update();
  });
  useEventListener(window, 'offline', () => {
    online.value = false;
  });
  useEventListener(document, 'visibilitychange', () => {
    if (!document.hidden) update();
  });
  onMounted(() => {
    refresh(true);
    refreshTimer = setInterval(update, REFRESH_INTERVAL);
  });
  onBeforeUnmount(() => {
    alive = false;
    clearInterval(refreshTimer);
    clearInterval(testTimer);
  });
  return {
    state,
    server,
    permission,
    supported,
    busy,
    checking,
    error,
    enable,
    disable,
    test,
    confirm,
    refresh: update,
  };
};
