# Install the UniGuard notification and tracking upgrade

This package upgrades your existing UniGuard application. It does not change your
live Supabase project until you perform the installation below. Keep a copy of
your current website and take a Supabase database backup first.

The ZIP supplied in chat exactly matched the GitHub `super_admin_screen` branch
at `ed1900f7b8e84892cf1263debdc862ce1934e5f1`. The upgrade preserves that app,
its design, its existing database tables, and existing RPC signatures.

The uploaded prompt ends after section 5 and references missing sections 6–12.
The supplied requirements were implemented; assumptions for the additional
coverage/tracking are recorded in `CHANGES.md`. This package does not claim
validation against the missing text.

## 1. Install the new database migrations

Open your project in Supabase → SQL Editor. If your system is already through
migration 060, run **only these seven new files**, one at a time, in this order:

1. `migrations/061_notifications_core.sql`
2. `migrations/062_push_pipeline.sql`
3. `migrations/063_dispatch_alarm_ack.sql`
4. `migrations/064_watchdog_jobs.sql`
5. `migrations/065_alert_settings.sql`
6. `migrations/066_notification_coverage.sql`
7. `migrations/067_dispatch_live_tracking.sql`

Wait for each file to finish before running the next. They are safe to re-run.
Existing notification rows are not turned into new alarms. Existing dispatches
are grandfathered once. Any currently unacknowledged SOS within the last 24 hours
still appears on duty consoles.

Enable **pg_net** and **pg_cron** in Supabase → Database → Extensions if they are
not enabled. If the SQL reports either extension unavailable, enable it and run
062, 064 and 067 again. The app can store notifications without these extensions,
but scheduled escalation, repeat pushes and SMS attempts require them.

If this is a completely new database, see `docs/MIGRATION-ORDER.md` for the exact
old migration order and prerequisites. Do not renumber either 045 file or 047.

## 2. Configure push keys and the private server secret

The project already contains a public VAPID key in `env.js`. Keep the matching
private key if you already have it. Never put the private key in `env.js`.
If you do not have the matching private key, generate a new pair on your computer:

```bash
npx web-push generate-vapid-keys
```

Put its **public** key in `env.js` → `VAPID_PUBLIC_KEY`. Put its **private** key
only in Supabase Edge Function Secrets. Devices subscribed with the previous
key must remove their device registration and enable alerts again.

Generate a separate internal secret, for example:

```bash
openssl rand -hex 32
```

In Supabase → Edge Functions → Secrets, set:

| Name | What to enter |
| --- | --- |
| `INTERNAL_PUSH_SECRET` | The separate random secret you just generated |
| `VAPID_PUBLIC_KEY` | Your matching public VAPID key |
| `VAPID_PRIVATE_KEY` | The matching private VAPID key |
| `VAPID_SUBJECT` | A real contact such as `mailto:your-office@example.gov.ph` |

Supabase provides `SUPABASE_URL`, `SUPABASE_ANON_KEY` and
`SUPABASE_SERVICE_ROLE_KEY` to hosted functions. Keep the service-role key out of
the website, repository and browser. Existing public anon configuration stays
in `env.js`, protected by database RLS.

In SQL Editor, open `docs/ALERTS-SETUP.sql`. Replace its three clearly marked
placeholders and run it. **Use the exact same internal secret in SQL and Edge
Function Secrets.** Set the public app URL to the actual HTTPS website address,
including its directory if deployed under a subdirectory. The push URL is your
Supabase project's `/functions/v1/push-dispatch` endpoint.

These values go into `ug_private_config`, which browser accounts cannot read.
Do not put them in `app_settings` or a screenshot shared with others.

## 3. Deploy both Edge Functions

Install/sign in to the Supabase CLI on your computer if needed. From this
project directory, link the existing project and deploy:

```bash
supabase login
supabase link --project-ref YOUR_PROJECT_REF
supabase functions deploy push-dispatch --no-verify-jwt
supabase functions deploy sms-fallback --no-verify-jwt
```

`supabase/config.toml` also declares this setting. The function code performs its
own authentication: normal broadcast/self-test calls validate the user's JWT;
database calls require the private internal secret. The SMS endpoint accepts
only server credentials. Removing gateway JWT validation is necessary for
`pg_net`; deploying the updated authentication code at the same time is essential.

There is no new installation or change required for the `admin-users` function.

## 4. Optional: enable actual SMS

SMS is provider dependent. Set these secrets only after arranging your gateway:

- `SMS_GATEWAY_URL`
- `SMS_GATEWAY_KEY`
- `SMS_SENDER`

The existing `buildRequest` helper in `supabase/functions/sms-fallback/index.ts`
sends JSON `{sender,to,message}` with a bearer API key. Adjust that helper if your
provider documents a different format. A gateway account and credit are needed.
**Without a gateway, the function only logs how many messages it would send. No
SMS is actually delivered.** `sms_sent_at` records the queue attempt, not a
carrier delivery receipt.

## 5. Update the website files

Deploy this project's `index.html`, `env.js`, `sw.js`, `manifest.json`, `js/`,
`css/`, `vendor/`, icons and fonts using your existing hosting process. The source
archive includes everything. `node_modules`, tests, migrations, private SQL
configuration and documentation do not need to be exposed by the web host.

The app remains buildless: **you do not need Node to run the website**. Node is
used only for development checks. No replacement hosting service is required.

This version uses `BUILD: 2026-11-15.notifications.1`, service-worker cache v36,
and shared offline database version 2. `APP_PUBLIC_URL` now follows the deployed
origin instead of the old hardcoded localhost URL. If hosted in a subdirectory,
set `APP_PUBLIC_URL` explicitly to that full HTTPS app URL. Check Supabase Auth's
Site URL and allowed redirect URLs match the public website.

Reload installed copies after deploying. Close older UniGuard tabs if an offline
database upgrade is blocked. Use Settings → reload application if a device keeps
an old screen; do not clear queued offline reports unnecessarily.

## 6. Enable alerts and sound on every responder device

Sign in as each LGU staff member, barangay official, dispatch team member and
Super Admin. The app displays device enrollment instructions until push is on.
On iPhone, first add UniGuard to the Home Screen and open it from that icon.
Then:

1. Tap **Allow alerts** and accept the browser permission prompt.
2. Tap **Enable alarm sound** once. Keep the device volume up.
3. Tap **Send test alert**. This sends only to that account's registered devices.
4. In Settings → Notifications, use **Test SOS alarm (3 s)**. The dispatch portal
   has device and sound controls on its Notifications screen.

Settings lists registered devices and lets the account remove them. Signing out
removes this browser's subscription and unsubscribes it, so a shared device does
not keep receiving the former user's alerts. A resident receives a one-time
invitation to enable push after their first successful report or SOS.

## 7. Set the response policy

As Super Admin, open Settings → Notifications → **Alerts & tracking**. The server
validates ranges and audits changes. Ordinary LGU accounts cannot change them.
The default Super Admin SOS alarm is **Backstop only**: silent pending cards
until the server escalates. **Every SOS** enables the immediate siren there too.
LGU duty staff and the correct barangay receive immediate SOS sirens. Units hear
their own assignments. Citizens never hear someone else's SOS alarm.

Reading a notification or marking all read does **not** acknowledge it. An SOS
stays pinned and rings until an official acknowledges/resolves it. A unit's GPS
can change its operational status automatically; a person must still tap
Acknowledge to stop the unit alarm. Resolving an SOS also closes linked pending
unit alarms, while leaving operational dispatch status under the existing
response workflow.

Open **Live dispatch tracking** from the LGU/barangay console or Super Admin
menu. Select a team to see its last fix, accuracy, signal state, approximate ETA,
recent trail and response timeline. Super Admin tracking is read-only. Relief
staff can now set a distribution's scheduled/ongoing/completed/cancelled phase.

## 8. Check the live installation before using it operationally

Follow `docs/ACCEPTANCE-CHECKLIST.md` with your own test accounts and devices.
The automated results and their limits are in `docs/VERIFICATION.md`.
Do not send trial SOS or SMS to actual on-duty staff without coordinating a test.

If push is off, check browser permission, installation on iPhone, VAPID key match,
the account's registered device, function logs, pg_net and private configuration.
If no escalation arrives, check `cron.job` and `cron.job_run_details` in SQL Editor.
The end of `docs/ALERTS-SETUP.sql` includes queries that do not print secrets.

The default one-minute job escalates a 60-second timeout at approximately 60–119
seconds. Open screens show the overdue counter at the configured second. Push
and SMS depend on connectivity and operating-system policy. A closed/sleeping
browser cannot promise looping audio or continuous background GPS. After 30
minutes, an open page's continuous siren becomes a short reminder every minute;
the pending state remains visible. Keep an operational phone/radio fallback.
