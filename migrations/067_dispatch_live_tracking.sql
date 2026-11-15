begin;
create table if not exists public.dispatch_locations(
 id bigint generated always as identity primary key,
 dispatch_id uuid not null references public.report_dispatches(id) on delete cascade,
 unit_id uuid not null references public.dispatch_units(id) on delete cascade,
 report_id uuid not null references public.reports(id) on delete cascade,
 lat double precision not null check(lat between -90 and 90),lng double precision not null check(lng between -180 and 180),
 accuracy double precision check(accuracy>=0 and accuracy<100000),
 captured_at timestamptz not null default now(),shared_by uuid references public.profiles(id) on delete set null
);
create index if not exists dispatch_locations_recent_idx on public.dispatch_locations(dispatch_id,captured_at desc);
alter table public.dispatch_locations enable row level security;
revoke all on public.dispatch_locations from public,anon,authenticated;
grant select on public.dispatch_locations to authenticated;
drop policy if exists dispatch_locations_scoped on public.dispatch_locations;
create policy dispatch_locations_scoped on public.dispatch_locations for select to authenticated using(
 exists(select 1 from public.report_dispatches d where d.id=dispatch_id)
);
alter table public.report_dispatches add column if not exists signal_lost_at timestamptz,
 add column if not exists signal_restored_at timestamptz,
 add column if not exists location_shared_by uuid references public.profiles(id) on delete set null;
do $$ begin
 if exists(select 1 from pg_publication where pubname='supabase_realtime' and not puballtables) then
  begin alter publication supabase_realtime add table public.dispatch_locations;exception when duplicate_object then null;end;
 end if;
end $$;
create or replace function public.ug_check_tracking() returns void language plpgsql security definer set search_path=public as $$
declare d record; v_sos uuid; v_lost timestamptz; begin
 for d in select * from public.report_dispatches where unit_id is not null and dispatch_status not in ('done','declined')
  and not exists(select 1 from public.sos_log s where s.report_id=report_dispatches.report_id and s.status='resolved')
  and coalesce(last_loc_at,dispatched_at)<=now()-make_interval(secs=>public.ug_alert_value('signal_lost_s','180')::int) and signal_lost_at is null for update skip locked loop
  v_lost:=now(); update public.report_dispatches set signal_lost_at=v_lost where id=d.id;
  select id into v_sos from public.sos_log where report_id=d.report_id limit 1;
  perform public.ug_notify(public.ug_recipients_lgu()||public.ug_recipients_super_admin()||public.ug_recipients_barangay(d.target_barangay_id)||public.ug_recipients_unit(d.unit_id),
   'lost_signal','Team location signal lost',d.team||' · last location '||coalesce(d.last_loc_at::text,'not received'),
   'warning','urgent',true,'signal:'||d.id||':'||v_lost::text,d.report_id,v_sos,d.id,null,'alert','tracking',d.id::text);
 end loop;
end $$;
revoke all on function public.ug_check_tracking() from public,anon,authenticated;
create or replace function public.ug_cleanup_locations() returns int language plpgsql security definer set search_path=public as $$
declare n int; begin delete from public.dispatch_locations where captured_at<now()-interval '30 days'; get diagnostics n=row_count;return n;end $$;
revoke all on function public.ug_cleanup_locations() from public,anon,authenticated;
do $$ begin
 if exists(select 1 from pg_namespace where nspname='cron') then
  perform cron.unschedule(jobid) from cron.job where jobname='ug-tracking-cleanup';
  perform cron.schedule('ug-tracking-cleanup','5 19 * * *','select public.ug_cleanup_locations()');
 end if;
end $$;

-- Latest 057 location RPC, extended without changing its signature.
create or replace function public.update_dispatch_location(
  p_dispatch_id uuid,
  p_lat         double precision,
  p_lng         double precision,
  p_accuracy    double precision default null
)
returns jsonb
language plpgsql
security definer set search_path = public
as $$
declare
  v_row    public.report_dispatches;
  v_rep    public.reports;
  v_status text;
  v_scene  double precision;
  v_moved  double precision;
  c_scene  double precision := public.ug_alert_value('arrival_radius_m','100')::double precision;   -- metres: "on scene"
  c_moved  constant double precision := 50;    -- metres: "en route"
begin
  if auth.uid() is null then
    raise exception 'You must be signed in';
  end if;
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'Invalid coordinates';
  end if;

  if p_accuracy is not null and not(p_accuracy>=0 and p_accuracy<100000) then raise exception 'Invalid GPS accuracy'; end if;
  if not exists(select 1 from public.profiles where id=auth.uid() and not disabled) then raise exception 'Account disabled'; end if;
  select * into v_row from public.report_dispatches where id = p_dispatch_id for update;
  if v_row.id is null then
    raise exception 'That dispatch does not exist';
  end if;
  if v_row.unit_id is null or v_row.unit_id is distinct from public.my_unit_id()
     or not public.is_dispatch() then
    raise exception 'Only this unit''s users may share its location';
  end if;
  if v_row.dispatch_status in ('done', 'declined') then
    return jsonb_build_object('dispatch_id', p_dispatch_id, 'status', v_row.dispatch_status, 'tracking', false);
  end if;

  insert into public.dispatch_locations(dispatch_id,unit_id,report_id,lat,lng,accuracy,shared_by)
  values(v_row.id,v_row.unit_id,v_row.report_id,p_lat,p_lng,p_accuracy,auth.uid());
  -- A fresh server-accepted fix recovers the entire outage, across all recipients.
  update public.notifications set acked_at=now(),acked_by=auth.uid() where dispatch_id=v_row.id and type='lost_signal' and requires_ack and acked_at is null;
  update public.report_dispatches
     set signal_restored_at=case when signal_lost_at is not null then now() else signal_restored_at end,
         signal_lost_at=null,location_shared_by=auth.uid(),last_lat = p_lat, last_lng = p_lng, last_accuracy = p_accuracy, last_loc_at = now(),
         start_lat = coalesce(start_lat, p_lat), start_lng = coalesce(start_lng, p_lng)
   where id = p_dispatch_id
   returning * into v_row;

  v_status := v_row.dispatch_status;
  select * into v_rep from public.reports where id = v_row.report_id;

  -- GPS changes the operational status, never the human alarm acknowledgement
  if v_status = 'sent' then
    perform public.dispatch_respond(p_dispatch_id, 'acknowledged', 'Automatic: location sharing started');
    v_status := 'acknowledged';
  end if;

  -- a poor fix moves nothing
  if p_accuracy is not null and p_accuracy <= 150 then
    if v_rep.lat is not null and v_rep.lng is not null then
      v_scene := public.distance_m(p_lat, p_lng, v_rep.lat, v_rep.lng);
    end if;
    v_moved := public.distance_m(v_row.start_lat, v_row.start_lng, p_lat, p_lng);

    if v_status in ('acknowledged', 'en_route') and v_scene is not null and v_scene <= c_scene then
      perform public.dispatch_respond(p_dispatch_id, 'on_scene',
        'Automatic: arrived (GPS, ' || round(v_scene::numeric) || ' m from the report)');
      v_status := 'on_scene';
    elsif v_status = 'acknowledged' and v_moved >= c_moved then
      perform public.dispatch_respond(p_dispatch_id, 'en_route', 'Automatic: moving (GPS)');
      v_status := 'en_route';
    end if;
  end if;

  return jsonb_build_object('dispatch_id', p_dispatch_id, 'status', v_status,
                            'distance_m', case when v_scene is null then null else round(v_scene::numeric) end,
                            'tracking', true);
end;
$$;
revoke all on function public.update_dispatch_location(uuid,double precision,double precision,double precision) from public,anon;
grant execute on function public.update_dispatch_location(uuid,double precision,double precision,double precision) to authenticated;
notify pgrst,'reload schema';
commit;
