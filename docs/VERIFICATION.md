# Verification report

Source base: GitHub `dearseolhwa/uni-guard`, `super_admin_screen`, commit
`ed1900f7b8e84892cf1263debdc862ce1934e5f1`. The original uploaded ZIP matched
that source byte for byte. Existing migrations 000–060 remain unchanged.

## Executed checks

| Check | Result | Scope |
| --- | --- | --- |
| `npm test` | 34 passed | Alarm/pending state, DOM integration, offline IndexedDB, push policy/authentication mocks, worker payload/routing |
| `python tests/run-database-tests.py` | 41 database assertions + 8 transport assertions passed | Fresh PostgreSQL 17, original 001–060, new 061–067 applied twice, unchanged existing RPC signatures |
| `npm run check` | 35 JavaScript files parsed; 4 TypeScript files transpiled | All app JavaScript + worker; all Edge Function sources |
| `deno check --node-modules-dir=none supabase/functions/push-dispatch/index.ts supabase/functions/sms-fallback/index.ts` | Passed on Deno 2.9.6 | Actual type checking, including imported shared delivery code |
| Central insert audit | Passed | After migration, `ug_notify` is the only public function body containing a direct notifications insert |
| Asset/cache inventory | Passed within `npm test` | Every local script/stylesheet in index exists and is precached; v35 is superseded |

There are **83 passing assertions/tests** across the Node and SQL suites, plus
syntax/type checks and migration compatibility checks. Node DOM tests use jsdom;
they are not a real browser or an acoustic/device test. The SQL transport tests
use a `net.http_post` test double to verify grouping, retry limits, SMS queue
metadata and non-blocking failure handling. Auth/storage helpers are minimal
Supabase substitutes in a disposable database. The actual pg_net HTTP transport,
pg_cron scheduler, Supabase Realtime network, VAPID delivery, SMS gateway and
multi-device timing require the acceptance checklist.

The isolated vanilla Postgres image does not include pg_net or pg_cron. The new
migrations correctly warn and continue; their absence is not reported as a live
scheduling success. The guide explains enabling them and rerunning the jobs.

## Requirement-to-code evidence

| Behavior | Implementation | Evidence |
| --- | --- | --- |
| Priorities, dedupe, scoped recipients, read-only REST edits | 061 `ug_notify`, recipient helpers, `ug_notifications_guard` | database T1–T4, T8, T34–T35 |
| Centralize old notification producers without replacing workflows | 063 latest bodies + 061 `ug_notify_batch` | RPC signature comparison; central insert audit; T12, T16, T20–T21, T36–T38 |
| Reading does not handle an incident | `UG_NOTIFY`, acknowledgement RPCs/triggers | T8, T10, T15; client read/offline test |
| Explicit unit human acceptance independent of GPS | 063 `dispatch_ack_alarm`; 067 `update_dispatch_location`; dispatch respond handler | T13–T15, T29; client GPS/human test |
| Immediate pending alarms independent of dirty forms and first-load silence | `js/notify.js` own queries/channel/body overlays; `js/alarm.js` looping API | client first-restored-load, dirty-form, other-device realtime and offline-reload tests |
| Loud looping profile, mute override, one loop per key, 30-minute reminder | `UG_ALARM.loop/stop/stopAll` | client idempotence/mute, unlock and reminder tests; actual speaker loudness pending device test |
| Scoped SOS and silent Super Admin backstop | 063 `submit_sos`, `UG_NOTIFY.sync` | T5–T7; client Super Admin/citizen tests |
| Named SOS timeline and resolution | 063 `update_sos_status`; `UG_TRACKING.timelineHTML/fillTimeline`; SOS modal | T11, T39; integration rendering checks |
| SOS, no-arrival, unaccepted unit and one-hour jobs | 064 `ug_check_sos_escalation`, `ug_check_one_hour_escalation`, `ug_watchdog` | T9, T40–T41; job definitions installed twice; live schedule pending |
| Grouped private push and bounded re-push/SMS attempts | 062 `ug_queue_push`, `ug_repush_pending`; Edge shared delivery helper | push SQL P1–P8; Edge policy/dead-subscription tests |
| Quiet hours and recipient preferences | `notification_prefs`; `UG_SETTINGS`; `pushAllowed` | Edge Manila boundary, responder override and citizen exceptions tests |
| JWT broadcast, private internal path, own-device test | `push-dispatch/index.ts`; hardened `sms-fallback/index.ts` | Edge forged-header/missing-auth, own-device test, SMS rejection; Deno check |
| Worker interaction/vibration/open-window forwarding | `sw.js` v36 | five service-worker tests |
| Push enrollment/devices/recovery | `UG_NOTIFY.deviceState/devicesHTML`; `UG_PWA.enablePush/repairPush/detachPush` | integration device controls and Edge own-device test; real subscription renewal pending |
| Pinned inbox, filters, action badge and routing | `UG_NOTIFY` + all existing portal inbox integrations | integration screens/filters, worker routing; manual role routing checklist |
| Pending cache retention and shared database repair | `notifications-store.js`, `pwa.js`, shared IDB v2 | cache 201-row test; shared-store/account test; offline pending reload test |
| Super Admin alert/tracking settings | 065 RPCs; actual Settings route in `js/settings.js` | T17, T35; rendered settings field test |
| Additional notification coverage | 066 `ug_notify_coverage`; relief phase control | T19–T25; original existing producers remain centralized |
| Citizen en-route update | 063 `dispatch_respond`; existing help alarm branch extended | T16 |
| GPS history and read scope | 067 `dispatch_locations` RLS and location RPC | T26, T30–T31 |
| Stale signal and recovery | 067 `ug_check_tracking`; `UG_TRACKING.signal`; location RPC | T27–T29; tracking DOM/signal test |
| Accurate configurable arrival radius | 065 protected setting; 067 location RPC | T17, T32–T33 |
| Read-only map, trail, approximate ETA and timeline | `js/tracking.js`; tracking route/menu integrations | tracking integration/ETA test; actual Leaflet/device usability pending |

## Running checks yourself

The website itself has no build step. For development checks, install Node and
run:

```bash
npm ci
npm test
npm run check
```

With Docker installed:

```bash
python3 tests/run-database-tests.py
```

The Python runner creates and deletes a separate unexposed PostgreSQL container.
It never uses the configured Supabase project. It supplies the original 043
migration's required owner fixture and pg_trgm prerequisite, applies the original
migrations, reapplies every new migration, checks RPC compatibility, and runs SQL
assertions. Logs go to `work/test-results/`, which is excluded from the release.
Do not run `tests/bootstrap.sql` or the SQL fixtures on production.

For actual devices, follow `docs/ACCEPTANCE-CHECKLIST.md` after `START_HERE.md`.
No hosted app, production migration, live push/SMS or GitHub push is claimed here.
