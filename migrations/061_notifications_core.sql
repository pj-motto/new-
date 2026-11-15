-- Central notifications. Apply after 060. Existing rows remain non-pending.
begin;
alter table public.notifications
  add column if not exists priority text not null default 'normal',
  add column if not exists requires_ack boolean not null default false,
  add column if not exists acked_at timestamptz,
  add column if not exists acked_by uuid references public.profiles(id) on delete set null,
  add column if not exists dedupe_key text,
  add column if not exists dispatch_id uuid,
  add column if not exists change_request_id uuid,
  add column if not exists target_route text,
  add column if not exists target_id text,
  add column if not exists last_push_at timestamptz,
  add column if not exists push_count int not null default 0,
  add column if not exists sms_sent_at timestamptz;
do $$ begin
 if not exists(select 1 from pg_constraint where conrelid='public.notifications'::regclass and conname='notifications_priority_check') then
  alter table public.notifications add constraint notifications_priority_check check(priority in ('critical','urgent','normal','info'));
 end if;
end $$;
create index if not exists notifications_pending_ack_idx on public.notifications(user_id) where requires_ack and acked_at is null;
create unique index if not exists notifications_dedupe_uq on public.notifications(user_id,dedupe_key) where dedupe_key is not null;

create or replace function public.ug_recipients_lgu() returns uuid[] language sql stable security definer set search_path=public as $$
 select coalesce(array_agg(id),'{}'::uuid[]) from public.profiles where role='lgu_ldrrmc' and not coalesce(is_super_admin,false) and not disabled;
$$;
create or replace function public.ug_recipients_super_admin() returns uuid[] language sql stable security definer set search_path=public as $$
 select coalesce(array_agg(id),'{}'::uuid[]) from public.profiles where role='lgu_ldrrmc' and is_super_admin and not disabled;
$$;
create or replace function public.ug_recipients_barangay(p_barangay_id uuid) returns uuid[] language sql stable security definer set search_path=public as $$
 select coalesce(array_agg(id),'{}'::uuid[]) from public.profiles where role='barangay_official' and barangay_id=p_barangay_id and not disabled;
$$;
create or replace function public.ug_recipients_unit(p_unit_id uuid) returns uuid[] language sql stable security definer set search_path=public as $$
 select coalesce(array_agg(id),'{}'::uuid[]) from public.profiles where role='dispatch_team' and dispatch_unit_id=p_unit_id and not disabled;
$$;
create or replace function public.ug_recipients_reporter(p_report_id uuid) returns uuid[] language sql stable security definer set search_path=public as $$
 select coalesce(array_agg(p.id),'{}'::uuid[]) from public.profiles p join public.reports r on r.reporter_id=p.id where r.id=p_report_id and not p.disabled;
$$;
revoke all on function public.ug_recipients_lgu(), public.ug_recipients_super_admin(), public.ug_recipients_barangay(uuid), public.ug_recipients_unit(uuid), public.ug_recipients_reporter(uuid) from public,anon,authenticated;

create or replace function public.ug_notify(
 p_user_ids uuid[],p_type text,p_title text,p_body text,p_tone text default 'advisory',p_priority text default 'normal',
 p_requires_ack boolean default false,p_dedupe_key text default null,p_report_id uuid default null,p_sos_id uuid default null,
 p_dispatch_id uuid default null,p_change_request_id uuid default null,p_icon text default 'bell',p_target_route text default null,p_target_id text default null
) returns int language plpgsql security definer set search_path=public as $$
declare v_n int;
begin
 insert into public.notifications(user_id,type,title,body,tone,priority,requires_ack,dedupe_key,report_id,sos_id,dispatch_id,change_request_id,icon,target_route,target_id)
 select p.id,p_type,p_title,left(coalesce(p_body,''),240),p_tone,p_priority,p_requires_ack,p_dedupe_key,p_report_id,p_sos_id,p_dispatch_id,p_change_request_id,p_icon,p_target_route,p_target_id
 from public.profiles p where p.id=any(p_user_ids) and not p.disabled on conflict do nothing;
 get diagnostics v_n=row_count;
 return v_n;
end $$;
revoke all on function public.ug_notify(uuid[],text,text,text,text,text,boolean,text,uuid,uuid,uuid,uuid,text,text,text) from public,anon,authenticated;

-- Invoker trigger: current_user is the outer definer for authorized server RPCs,
-- but authenticated for direct REST updates. A client-set GUC alone cannot bypass it.
create or replace function public.ug_notifications_guard() returns trigger language plpgsql set search_path=public as $$
begin
 if current_user not in ('postgres','supabase_admin','service_role') then
  if (to_jsonb(new)-'read_at') is distinct from (to_jsonb(old)-'read_at') then
   raise exception 'Only read_at may be changed directly' using errcode='42501';
  end if;
 end if;
 return new;
end $$;
revoke all on function public.ug_notifications_guard() from public,anon,authenticated;
drop trigger if exists ug_notifications_guard on public.notifications;
create trigger ug_notifications_guard before update on public.notifications for each row execute function public.ug_notifications_guard();
drop policy if exists notifications_update on public.notifications;
create policy notifications_update on public.notifications for update to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());
drop policy if exists notifications_delete on public.notifications;
create policy notifications_delete on public.notifications for delete to authenticated using(user_id=auth.uid() and not (requires_ack and acked_at is null));

create or replace function public.ack_notification(p_id uuid) returns jsonb language plpgsql security definer set search_path=public as $$
declare v public.notifications;
begin
 select * into v from public.notifications where id=p_id and user_id=auth.uid() for update;
 if v.id is null or not exists(select 1 from public.profiles where id=auth.uid() and not disabled) then raise exception 'Notification unavailable' using errcode='42501'; end if;
 -- These are acknowledged by handling the underlying incident, never by reading.
 if v.requires_ack and v.acked_at is null and (v.sos_id is not null or v.dispatch_id is not null or v.change_request_id is not null or v.type in ('escalation_1h','dispatch_needed','lost_signal')) then
  raise exception 'Open and handle this item to acknowledge it';
 end if;
 perform set_config('uniguard.ack','1',true);
 update public.notifications set acked_at=coalesce(acked_at,now()),acked_by=coalesce(acked_by,auth.uid()),read_at=coalesce(read_at,now()) where id=p_id;
 perform public.write_audit('notification.acked','notifications',p_id,jsonb_build_object('type',v.type));
 return jsonb_build_object('ok',true,'id',p_id);
end $$;
revoke all on function public.ack_notification(uuid) from public,anon;
grant execute on function public.ack_notification(uuid) to authenticated;

create or replace function public.ug_auto_ack_notifications() returns trigger language plpgsql security definer set search_path=public as $$
declare d record;
begin
 perform set_config('uniguard.ack','1',true);
 if tg_table_name='sos_log' then
  if new.status<>'sent' then
   update public.notifications set acked_at=now(),acked_by=auth.uid() where sos_id=new.id and type in ('sos','sos_escalation') and requires_ack and acked_at is null;
  end if;
  if new.status='resolved' then
   -- Resolution is a human action that also closes outstanding linked alarms;
   -- operational dispatch status still follows the existing response workflow.
   for d in select * from public.report_dispatches where report_id=new.report_id and alarm_acked_at is null for update loop
    insert into public.report_dispatch_events(dispatch_id,actor,actor_name,action,note)
     values(d.id,auth.uid(),(select full_name from public.profiles where id=auth.uid()),'alarm_acknowledged','SOS resolved by an official');
    update public.report_dispatches set alarm_acked_at=now(),alarm_acked_by=auth.uid() where id=d.id;
   end loop;
   update public.notifications set acked_at=now(),acked_by=auth.uid() where sos_id=new.id and requires_ack and acked_at is null;
  end if;
 elsif tg_table_name='report_dispatches' then
  if (to_jsonb(new)->>'alarm_acked_at') is not null or new.dispatch_status in ('done','declined') then
   update public.notifications set acked_at=now(),acked_by=auth.uid() where dispatch_id=new.id and type in ('dispatch','unit_dispatch','dispatch_unacked') and requires_ack and acked_at is null;
  end if;
  if new.dispatch_status in ('done','declined') then
   update public.notifications set acked_at=now(),acked_by=auth.uid() where dispatch_id=new.id and requires_ack and acked_at is null;
  end if;
  if new.dispatch_status in ('on_scene','under_control','fire_out','arrived_hospital','done') then
   update public.notifications set acked_at=now(),acked_by=auth.uid() where type='sos_no_arrival' and sos_id in (select id from public.sos_log where report_id=new.report_id) and requires_ack and acked_at is null;
  end if;
 elsif tg_table_name='change_requests' then
  if new.status<>'pending' then update public.notifications set acked_at=now(),acked_by=auth.uid() where change_request_id=new.id and requires_ack and acked_at is null; end if;
 elsif tg_table_name='reports' then
  if new.status<>'reported' then update public.notifications set acked_at=now(),acked_by=auth.uid() where report_id=new.id and type in ('escalation_1h','dispatch_needed','new_report') and requires_ack and acked_at is null; end if;
 elsif tg_table_name='alert_acknowledgments' then
  update public.notifications set acked_at=now(),acked_by=new.user_id where advisory_id=new.advisory_id and user_id=new.user_id and requires_ack and acked_at is null;
 end if;
 return null;
end $$;
revoke all on function public.ug_auto_ack_notifications() from public,anon,authenticated;
do $$ declare t text; begin
 foreach t in array array['sos_log','report_dispatches','change_requests','reports'] loop
  execute format('drop trigger if exists ug_auto_ack on public.%I',t);
  execute format('create trigger ug_auto_ack after update on public.%I for each row execute function public.ug_auto_ack_notifications()',t);
 end loop;
end $$;
drop trigger if exists ug_auto_ack on public.alert_acknowledgments;
create trigger ug_auto_ack after insert on public.alert_acknowledgments for each row execute function public.ug_auto_ack_notifications();
create or replace function public.ug_cleanup_notifications() returns int language plpgsql security definer set search_path=public as $$
declare n int; begin
 delete from public.notifications where created_at<now()-interval '90 days' and read_at is not null and not(requires_ack and acked_at is null);
 get diagnostics n=row_count; return n;
end $$;
revoke all on function public.ug_cleanup_notifications() from public,anon,authenticated;

-- Adapter for existing fan-out queries: keeps their text and recipient selection
-- verbatim while routing every row through ug_notify. No client execute grant.
create or replace function public.ug_notify_batch(p_rows jsonb,p_meta jsonb default '{}'::jsonb)
returns setof int language plpgsql security definer set search_path=public as $$
declare r jsonb; n int; v_id uuid; v_type text; v_route text; v_target text; v_priority text; v_ack boolean; v_before timestamptz; v_users uuid[]; v_i int;
begin
 for r in select (value-'user_id')||p_meta||jsonb_build_object('_users',jsonb_agg(value->'user_id')) from jsonb_array_elements(coalesce(p_rows,'[]')) group by (value-'user_id') loop
  select array_agg(value::uuid) into v_users from jsonb_array_elements_text(r->'_users');
  v_type:=coalesce(r->>'type',case when r->>'advisory_id' is not null then 'advisory' else '' end);
  v_route:=coalesce(r->>'target_route',case when r->>'sos_id' is not null then 'sos' when r->>'report_id' is not null then 'incident'
    when r->>'advisory_id' is not null then 'advisory-detail' when r->>'road_work_id' is not null then 'roadwork'
    when v_type in ('unit_request','support_request') then 'requests' when v_type='patient_notice' then 'hospital'
    when v_type='relief_escort' then 'relief' when v_type='change_request' then 'hotlines' else 'notifications' end);
  v_target:=coalesce(r->>'target_id',r->>'sos_id',r->>'report_id',r->>'advisory_id',r->>'road_work_id');
  v_priority:=coalesce(r->>'priority',case when v_type in ('dispatch_declined','dispatch_help') then 'urgent' else 'normal' end);
  v_ack:=coalesce((r->>'requires_ack')::boolean,false);
  n:=public.ug_notify(v_users,v_type,r->>'title',r->>'body',r->>'tone',v_priority,v_ack,r->>'dedupe_key',
    (r->>'report_id')::uuid,(r->>'sos_id')::uuid,(r->>'dispatch_id')::uuid,(r->>'change_request_id')::uuid,r->>'icon',v_route,v_target);
  if n>0 then
   -- These legacy link columns are outside ug_notify's fixed signature.
   if r->>'advisory_id' is not null or r->>'road_work_id' is not null or r->>'relief_id' is not null then
    update public.notifications set advisory_id=(r->>'advisory_id')::uuid,road_work_id=(r->>'road_work_id')::uuid,relief_id=(r->>'relief_id')::uuid
     where user_id=any(v_users) and target_route=v_route and target_id=v_target and created_at=now();
   end if;
   for v_i in 1..n loop return next 1; end loop;
  end if;
 end loop;
end $$;
revoke all on function public.ug_notify_batch(jsonb,jsonb) from public,anon,authenticated;

commit;
