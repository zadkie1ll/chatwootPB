/* eslint-disable no-restricted-globals, no-console */
/* globals clients */
self.addEventListener('push', event => {
  const notification = event.data && event.data.json();
  if (!notification) return;
  const url = new URL(notification.url || '/app', self.location.origin);
  const target = url.origin === self.location.origin ? url.href : self.location.origin + '/app';
  event.waitUntil((async () => {
    await self.registration.showNotification(notification.title, {
      body: notification.body,
      tag: notification.tag,
      data: { url: target },
    });
    if (notification.type === 'corporate_test' && notification.receipt_token) {
      await fetch('/api/v1/corporate_push_receipts', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        credentials: 'omit',
        body: JSON.stringify({ token: notification.receipt_token }),
      });
    }
  })());
});

self.addEventListener('notificationclick', event => {
  const notification = event.notification;
  notification.close();

  event.waitUntil(
    clients.matchAll({ type: 'window' }).then(windowClients => {
      let matchingWindowClients = windowClients.filter(
        client => client.url === notification.data.url
      );

      if (matchingWindowClients.length) {
        let firstWindow = matchingWindowClients[0];
        if (firstWindow && 'focus' in firstWindow) {
          firstWindow.focus();
          return;
        }
      }
      if (clients.openWindow) {
        clients.openWindow(notification.data.url);
      }
    })
  );
});
