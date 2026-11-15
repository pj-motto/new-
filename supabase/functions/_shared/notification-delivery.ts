// Shared policy for database-originated delivery. No browser secrets.
export function secretMatches(actual: string | null, expected: string | undefined): boolean {
  if (!actual || !expected) return false;
  const a = new TextEncoder().encode(actual), b = new TextEncoder().encode(expected);
  let difference = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) difference |= (a[i] || 0) ^ (b[i] || 0);
  return difference === 0;
}
export function pushAllowed(profile: any, prefs: any, notification: any, now = new Date()): boolean {
  if (!profile || profile.disabled) return false;
  const responder = ['lgu_ldrrmc', 'barangay_official', 'dispatch_team'].includes(profile.role);
  const urgent = ['critical', 'urgent'].includes(notification.priority);
  if ((responder && urgent) || notification.sos_id || (notification.type === 'advisory' && notification.tone === 'emergency')) return true;
  if (notification.priority === 'info') return false;
  if (prefs?.push_enabled === false) return false;
  if (!prefs?.quiet_hours) return true;
  const minute = (value: string) => { const [h, m] = (value || '00:00').split(':').map(Number); return h * 60 + m; };
  const parts = new Intl.DateTimeFormat('en-GB', { timeZone: 'Asia/Manila', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).formatToParts(now);
  const current = Number(parts.find(p => p.type === 'hour')?.value) * 60 + Number(parts.find(p => p.type === 'minute')?.value);
  const start = minute(prefs.quiet_start), end = minute(prefs.quiet_end);
  const quiet = start === end || (start < end ? current >= start && current < end : current >= start || current < end);
  return !quiet;
}

export async function targetedPush(admin: any, webpush: any, body: Record<string, any>, selfUserId?: string) {
  const ids = Array.isArray(body.notificationIds) ? [...new Set(body.notificationIds)].slice(0, 10000) : [];
  let rows: any[] = [];
  if (!selfUserId) {
    if (!ids.length || !Array.isArray(body.userIds)) throw new Error('Notification and recipient IDs required');
    const result = await admin.from('notifications').select('*').in('id', ids).in('user_id', body.userIds);
    if (result.error) throw result.error;
    // An async request may arrive after another device has handled the incident.
    rows = (result.data || []).filter((n: any) => !(n.requires_ack && n.acked_at));
  }
  const userIds = selfUserId ? [selfUserId] : [...new Set(rows.map(n => n.user_id))];
  if (!userIds.length) return { ok: true, sent: 0, failed: 0, removed: 0 };
  const [people, preferences, devices] = await Promise.all([
    admin.from('profiles').select('id,role,disabled').in('id', userIds),
    admin.from('notification_prefs').select('*').in('user_id', userIds),
    admin.from('push_subscriptions').select('id,user_id,endpoint,p256dh,auth').in('user_id', userIds)
  ]);
  for (const result of [people, preferences, devices]) if (result.error) throw result.error;
  let sent = 0, failed = 0; const stale: string[] = [];
  for (const device of devices.data || []) {
    const person = (people.data || []).find((p: any) => p.id === device.user_id);
    const prefs = (preferences.data || []).find((p: any) => p.user_id === device.user_id);
    const n = selfUserId ? { title: 'UniGuard test alert', body: 'Push alerts are working on this device.', priority: 'normal', type: 'test', tone: 'advisory' }
      : rows.find(n => n.user_id === device.user_id);
    if (!n || (selfUserId ? !person || person.disabled : !pushAllowed(person, prefs, n))) continue;
    const priority = n.priority || 'normal';
    const payload = JSON.stringify({ title: n.title, body: n.body, severity: n.tone, type: n.type, priority,
      url: selfUserId ? './index.html#notifications' : String(body.url || './index.html#notifications'),
      tag: n.sos_id ? 'sos-' + n.sos_id : n.dispatch_id ? 'dispatch-' + n.dispatch_id : 'n-' + (n.id || 'test'),
      requireInteraction: ['critical', 'urgent'].includes(priority), renotify: !!body.renotify,
      notification_id: n.id, sos_id: n.sos_id, dispatch_id: n.dispatch_id, report_id: n.report_id, advisory_id: n.advisory_id });
    try {
      await webpush.sendNotification({ endpoint: device.endpoint, keys: { p256dh: device.p256dh, auth: device.auth } }, payload,
        { TTL: ['critical', 'urgent'].includes(priority) ? 3600 : priority === 'info' ? 300 : 900,
          urgency: ['critical', 'urgent'].includes(priority) ? 'high' : priority === 'info' ? 'low' : 'normal' });
      sent++;
    } catch (e) {
      failed++;
      if ([404, 410].includes((e as any).statusCode)) stale.push(device.id);
    }
  }
  if (stale.length) { const result = await admin.from('push_subscriptions').delete().in('id', stale); if (result.error) throw result.error; }
  // The database reserves last_push_at and increments push_count atomically when
  // queueing. Count attempts, including transport failures, to bound retries.
  await admin.from('audit_log').insert({ action: 'push.targeted', entity: 'notifications', meta: { sent, failed, removed: stale.length, selfTest: !!selfUserId } });
  return { ok: true, sent, failed, removed: stale.length };
}
