self.addEventListener('install', (event) => {
  event.waitUntil(self.skipWaiting());
});
self.addEventListener('activate', (event) => {
  event.waitUntil(self.clients.claim());
});

self.addEventListener('push', (event) => {
  let payload;
  try {
    payload = event.data?.json() || {};
  } catch {
    payload = {};
  }
  if (payload.action === 'clear') {
    event.waitUntil((async () => {
      if (!payload.id) return;
      const notifications = await self.registration.getNotifications({
        tag: payload.id
      });
      notifications.forEach((notification) => notification.close());
    })());
    return;
  }
  const sentAt = Date.parse(payload.sentAt || '') || Date.now();
  const sentTime = new Date(sentAt).toLocaleTimeString([], {
    hour: 'numeric',
    minute: '2-digit'
  });
  const body = [payload.body, `Sent at ${sentTime}`]
    .filter(Boolean).join('\n');
  event.waitUntil(self.registration.showNotification(
    payload.title || 'Copilot Projects',
    {
      body: body || `Sent at ${sentTime}`,
      tag: payload.id || undefined,
      timestamp: sentAt,
      icon: '/icon-192.png',
      badge: '/icon-192.png',
      data: {
        id: payload.id || null,
        projectId: payload.projectId || null,
        sessionId: payload.sessionId || null
      }
    }
  ));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const data = event.notification.data || {};
  const query = new URLSearchParams();
  if (data.projectId) query.set('project', data.projectId);
  if (data.sessionId) query.set('session', data.sessionId);
  const url = new URL(`./?${query.toString()}`, self.registration.scope).href;
  event.waitUntil((async () => {
    if (data.id) {
      await fetch(new URL('notifications/dismiss', self.registration.scope), {
        method: 'POST',
        headers: {'Content-Type':'application/json'},
        body: JSON.stringify({id: data.id})
      }).catch(() => {});
    }
    const windows = await clients.matchAll({
      type: 'window',
      includeUncontrolled: true
    });
    if (windows.length) {
      windows[0].postMessage({
        type: 'focus-session',
        projectId: data.projectId,
        sessionId: data.sessionId
      });
      return windows[0].focus();
    }
    return clients.openWindow(url);
  })());
});

self.addEventListener('notificationclose', (event) => {
  const id = event.notification.data?.id;
  if (!id) return;
  event.waitUntil(fetch(
    new URL('notifications/dismiss', self.registration.scope),
    {
      method: 'POST',
      headers: {'Content-Type':'application/json'},
      body: JSON.stringify({id})
    }
  ).catch(() => {}));
});
