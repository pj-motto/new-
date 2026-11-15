begin;
create table if not exists public.ug_private_config(key text primary key,value text not null);
alter table public.ug_private_config enable row level security;
revoke all on public.ug_private_config from public,anon,authenticated;
create or replace function public.ug_private(p_key text) returns text language sql stable security definer set search_path=public as $$ select value from public.ug_private_config where key=p_key $$;
revoke all on function public.ug_private(text) from public,anon,authenticated;
create table if not exists public.notification_prefs(
 user_id uuid primary key references public.profiles(id) on delete cascade,
 push_enabled boolean not null default true,quiet_hours boolean not null default false,
 quiet_start time not null default '22:00',quiet_end time not null default '06:00'
);
alter table public.notification_prefs enable row level security;
drop policy if exists notification_prefs_own on public.notification_prefs;
create policy notification_prefs_own on public.notification_prefs for all to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());
grant select,insert,update,delete on public.notification_prefs to authenticated;
-- Settings are created in 065; jobs use defaults until it has been applied.
create or replace function public.ug_alert_value(p_key text,p_default text) returns text language plpgsql stable security definer set search_path=public as $$
declare v text; begin
 if to_regclass('public.ug_alert_settings') is not null then execute 'select to_jsonb(s)->>$1 from public.ug_alert_settings s where id=true' into v using p_key; end if;
 return coalesce(v,p_default);
end $$;
revoke all on function public.ug_alert_value(text,text) from public,anon,authenticated;
do $$ begin
 begin create extension if not exists pg_net; exception when others then raise warning 'pg_net unavailable. Push jobs require enabling pg_net: %',sqlerrm; end;
end $$;

create or replace function public.ug_queue_push(p_ids uuid[],p_renotify boolean default false) returns boolean language plpgsql security definer set search_path=public as $$
declare g record; v_url text:=public.ug_private('push_function_url'); v_secret text:=public.ug_private('internal_secret'); v_base text:=public.ug_private('app_public_url'); v_payload jsonb; v_req bigint; queued boolean:=false;
begin
 if v_url is null or v_secret is null or v_base is null or not exists(select 1 from pg_namespace where nspname='net') then return false; end if;
 for g in select type,title,body,priority,tone,sos_id,dispatch_id,report_id,target_route,target_id,
   array_agg(distinct user_id) users,array_agg(id) ids from public.notifications where id=any(p_ids)
   group by type,title,body,priority,tone,sos_id,dispatch_id,report_id,target_route,target_id loop
  if g.type='advisory' and exists(select 1 from public.advisories where id::text=g.target_id and delivery_mode='in_app') then continue; end if;
  v_payload:=jsonb_build_object('userIds',g.users,'notificationIds',g.ids,'title',g.title,'body',g.body,'priority',g.priority,'severity',g.tone,'type',g.type,
   'tag',case when g.sos_id is not null then 'sos-'||g.sos_id when g.dispatch_id is not null then 'dispatch-'||g.dispatch_id else 'n-'||g.ids[1] end,
   'url',rtrim(v_base,'/')||'/index.html#notifications','requireInteraction',g.priority in ('critical','urgent'),'renotify',p_renotify,
   'sos_id',g.sos_id,'dispatch_id',g.dispatch_id,'report_id',g.report_id);
  begin
   execute 'select net.http_post(url := $1, headers := $2, body := $3)' into v_req using v_url,jsonb_build_object('Content-Type','application/json','x-ug-internal',v_secret),v_payload;
   -- Reserve the attempt before the asynchronous response to prevent duplicate minute jobs.
   update public.notifications set last_push_at=now(),push_count=push_count+1 where id=any(g.ids);
   queued:=true;
  exception when others then raise warning 'UniGuard push could not be queued: %',sqlerrm;
  end;
 end loop;
 return queued;
exception when others then raise warning 'UniGuard push unavailable: %',sqlerrm; return false;
end $$;
revoke all on function public.ug_queue_push(uuid[],boolean) from public,anon,authenticated;
create or replace function public.ug_push_inserted() returns trigger language plpgsql security definer set search_path=public as $$
begin
 perform public.ug_queue_push(array(select id from ug_new_notifications),false); return null;
exception when others then raise warning 'UniGuard notification saved; push failed: %',sqlerrm; return null;
end $$;
revoke all on function public.ug_push_inserted() from public,anon,authenticated;
drop trigger if exists ug_push_inserted on public.notifications;
create trigger ug_push_inserted after insert on public.notifications referencing new table as ug_new_notifications for each statement execute function public.ug_push_inserted();

create or replace function public.ug_repush_pending() returns void language plpgsql security definer set search_path=public as $$
declare v record; v_req bigint; v_url text:=public.ug_private('push_function_url'); v_secret text:=public.ug_private('internal_secret');
begin
 perform public.ug_queue_push(array(select id from public.notifications where requires_ack and acked_at is null and priority in ('critical','urgent')
  and created_at>now()-interval '6 hours' and push_count<60 and (last_push_at is null or last_push_at<=now()-make_interval(secs=>public.ug_alert_value('repush_interval_s','60')::int))),true);
 if v_url is null or v_secret is null or not exists(select 1 from pg_namespace where nspname='net') then return; end if;
 for v in select n.id,n.user_id,n.title,n.body from public.notifications n where requires_ack and acked_at is null and priority='critical'
  and created_at>now()-interval '6 hours' and created_at<=now()-make_interval(secs=>public.ug_alert_value('sms_after_s','120')::int) and sms_sent_at is null for update skip locked loop
  begin
   execute 'select net.http_post(url := $1, headers := $2, body := $3)' into v_req
    using regexp_replace(v_url,'/push-dispatch/?$','/sms-fallback'),jsonb_build_object('Content-Type','application/json','x-ug-internal',v_secret),
    jsonb_build_object('userIds',array[v.user_id],'notificationIds',array[v.id],'title',v.title,'message',left(v.body||' Open UniGuard and acknowledge.',240),'severity','emergency');
   update public.notifications set sms_sent_at=now() where id=v.id;
  exception when others then raise warning 'UniGuard SMS could not be queued: %',sqlerrm; end;
 end loop;
end $$;
revoke all on function public.ug_repush_pending() from public,anon,authenticated;
commit;
