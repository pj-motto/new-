begin;
create table if not exists public.ug_alert_settings(
 id boolean primary key default true check(id),
 sos_ack_timeout_s int not null default 60 check(sos_ack_timeout_s between 10 and 600),
 sos_onscene_timeout_min int not null default 10 check(sos_onscene_timeout_min between 1 and 120),
 arrival_radius_m int not null default 100 check(arrival_radius_m between 20 and 500),
 signal_amber_s int not null default 60 check(signal_amber_s between 15 and 600),
 signal_lost_s int not null default 180 check(signal_lost_s between 30 and 1800 and signal_lost_s>signal_amber_s),
 repush_interval_s int not null default 60 check(repush_interval_s between 30 and 300),
 sms_after_s int not null default 120 check(sms_after_s between 30 and 3600),
 eta_speed_kmh int not null default 30 check(eta_speed_kmh between 5 and 120),
 super_admin_sos_alarm text not null default 'backstop' check(super_admin_sos_alarm in ('backstop','every')),
 updated_at timestamptz not null default now(),updated_by uuid references public.profiles(id) on delete set null
);
alter table public.ug_alert_settings enable row level security;
revoke all on public.ug_alert_settings from public,anon,authenticated;
insert into public.ug_alert_settings(id) values(true) on conflict do nothing;
create or replace function public.get_alert_settings() returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v jsonb; begin
 if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and not disabled) then raise exception 'Sign in required' using errcode='42501'; end if;
 select (to_jsonb(s)-'id')||jsonb_build_object('updated_by_name',(select full_name from public.profiles where id=s.updated_by)) into v from public.ug_alert_settings s where id;
 return v;
end $$;
revoke all on function public.get_alert_settings() from public,anon;
grant execute on function public.get_alert_settings() to authenticated;
create or replace function public.set_alert_settings(p_values jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare v public.ug_alert_settings; k text;
begin
 if not public.is_super_admin() or not exists(select 1 from public.profiles where id=auth.uid() and not disabled) then raise exception 'Super Admin only' using errcode='42501'; end if;
 if jsonb_typeof(p_values) is distinct from 'object' then raise exception 'Settings must be an object'; end if;
 for k in select jsonb_object_keys(p_values) loop
  if k not in ('sos_ack_timeout_s','sos_onscene_timeout_min','arrival_radius_m','signal_amber_s','signal_lost_s','repush_interval_s','sms_after_s','eta_speed_kmh','super_admin_sos_alarm') then raise exception 'Unknown setting: %',k; end if;
 end loop;
 select * into v from public.ug_alert_settings where id for update;
 v:=jsonb_populate_record(v,p_values);
 update public.ug_alert_settings set sos_ack_timeout_s=v.sos_ack_timeout_s,sos_onscene_timeout_min=v.sos_onscene_timeout_min,
  arrival_radius_m=v.arrival_radius_m,signal_amber_s=v.signal_amber_s,signal_lost_s=v.signal_lost_s,repush_interval_s=v.repush_interval_s,
  sms_after_s=v.sms_after_s,eta_speed_kmh=v.eta_speed_kmh,super_admin_sos_alarm=v.super_admin_sos_alarm,updated_at=now(),updated_by=auth.uid() where id;
 perform public.write_audit('alerts.settings_changed','ug_alert_settings',null,p_values);
 return public.get_alert_settings();
end $$;
revoke all on function public.set_alert_settings(jsonb) from public,anon;
grant execute on function public.set_alert_settings(jsonb) to authenticated;
notify pgrst,'reload schema';
commit;
