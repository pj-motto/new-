begin;
create or replace function public.ug_check_sos_escalation() returns void language plpgsql security definer set search_path=public as $$
declare s record; d record; recipients uuid[];
begin
 for s in select * from public.sos_log where status in ('sent','acknowledged') and created_at>now()-interval '24 hours' loop
  recipients:=public.ug_recipients_lgu()||public.ug_recipients_super_admin()||public.ug_recipients_barangay(s.barangay_id);
  if s.status='sent' and s.created_at<=now()-make_interval(secs=>public.ug_alert_value('sos_ack_timeout_s','60')::int) then
   perform public.ug_notify(recipients,'sos_escalation','SOS UNACKNOWLEDGED',coalesce(s.kind,'other')||' · '||s.barangay,'emergency','critical',true,'sosesc:'||s.id,s.report_id,s.id,null,null,'alert','sos',s.id::text);
  elsif s.status='acknowledged' and s.report_id is not null and s.created_at<=now()-make_interval(mins=>public.ug_alert_value('sos_onscene_timeout_min','10')::int)
   and not exists(select 1 from public.report_dispatches where report_id=s.report_id and dispatch_status in ('on_scene','under_control','fire_out','arrived_hospital','done')) then
   perform public.ug_notify(recipients,'sos_no_arrival','SOS: no team on scene',coalesce(s.kind,'other')||' · '||s.barangay,'warning','urgent',true,'sosnoarr:'||s.id,s.report_id,s.id,null,null,'alert','sos',s.id::text);
  end if;
  for d in select rd.*,u.name from public.report_dispatches rd left join public.dispatch_units u on u.id=rd.unit_id
   where rd.report_id=s.report_id and rd.unit_id is not null and rd.alarm_acked_at is null and rd.dispatch_status not in ('done','declined')
    and rd.dispatched_at<=now()-make_interval(secs=>public.ug_alert_value('sos_ack_timeout_s','60')::int) loop
   perform public.ug_notify(public.ug_recipients_lgu(),'dispatch_unacked','Unit '||coalesce(d.name,d.team)||' has not acknowledged',s.barangay,'warning','urgent',true,'unitunacked:'||d.id,s.report_id,s.id,d.id,null,'truck','incident',s.report_id::text);
  end loop;
 end loop;
end $$;
revoke all on function public.ug_check_sos_escalation() from public,anon,authenticated;
create or replace function public.ug_check_one_hour_escalation() returns void language plpgsql security definer set search_path=public as $$
declare r record; begin
 for r in select * from public.reports where status='reported' and created_at<=now()-interval '1 hour' loop
  perform public.ug_notify(public.ug_recipients_lgu()||public.ug_recipients_barangay(r.barangay_id),'escalation_1h','Report awaiting verification: '||coalesce(r.code,''),r.hazard_type||' · '||r.barangay||' · unverified for one hour','warning','urgent',true,'esc1h:'||r.id,r.id,null,null,null,'clock','incident',r.id::text);
 end loop;
end $$;
revoke all on function public.ug_check_one_hour_escalation() from public,anon,authenticated;
-- Phase 3 replaces this stub; keeping it callable makes a staged rollout safe.
create or replace function public.ug_check_tracking() returns void language plpgsql security definer set search_path=public as $$ begin return; end $$;
revoke all on function public.ug_check_tracking() from public,anon,authenticated;
create or replace function public.ug_watchdog() returns void language plpgsql security definer set search_path=public as $$
begin
 -- Transaction-scoped lock prevents overlapping cron/manual executions.
 if not pg_try_advisory_xact_lock(761946102) then return; end if;
 perform public.ug_check_sos_escalation();
 perform public.ug_check_one_hour_escalation();
 perform public.ug_check_tracking();
 perform public.ug_repush_pending();
end $$;
revoke all on function public.ug_watchdog() from public,anon,authenticated;
do $$ begin
 begin create extension if not exists pg_cron; exception when others then raise warning 'pg_cron unavailable. Enable it and rerun 064 for scheduled escalation: %',sqlerrm; end;
 if exists(select 1 from pg_namespace where nspname='cron') then
  perform cron.unschedule(jobid) from cron.job where jobname in ('ug-alert-watchdog','ug-notifications-cleanup');
  perform cron.schedule('ug-alert-watchdog','* * * * *','select public.ug_watchdog()');
  perform cron.schedule('ug-notifications-cleanup','0 19 * * *','select public.ug_cleanup_notifications()');
 end if;
end $$;
commit;
