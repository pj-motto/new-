-- Run as the project owner in Supabase SQL Editor after 061–067.
-- Replace ALL three placeholders below. Never put this secret in env.js.
begin;
insert into public.ug_private_config(key,value) values
 ('push_function_url','https://YOUR_PROJECT_REF.supabase.co/functions/v1/push-dispatch'),
 ('internal_secret','PASTE_THE_SAME_RANDOM_INTERNAL_PUSH_SECRET_HERE'),
 ('app_public_url','https://YOUR_PUBLIC_UNIGUARD_WEBSITE')
on conflict(key) do update set value=excluded.value;
commit;

-- Read-only installation checks: no secret values are printed.
select key,(value<>'' and value not like '%YOUR_%' and value not like '%PASTE_%') as configured
from public.ug_private_config where key in ('push_function_url','internal_secret','app_public_url');
select extname from pg_extension where extname in ('pg_net','pg_cron');
-- Run the following two queries only when pg_cron is enabled:
-- select jobname,schedule,active from cron.job where jobname like 'ug-%';
-- select jobid,status,start_time,return_message from cron.job_run_details order by start_time desc limit 20;
select tablename from pg_publication_tables where pubname='supabase_realtime'
 and schemaname='public' and tablename in ('notifications','sos_log','report_dispatches','change_requests','dispatch_locations') order by tablename;
