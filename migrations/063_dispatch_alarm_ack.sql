begin;
alter table public.report_dispatches add column if not exists alarm_acked_at timestamptz,
 add column if not exists alarm_acked_by uuid references public.profiles(id) on delete set null;
-- Existing assignments are grandfathered once, never resurrected as new alarms.
-- A rollout marker makes this backfill safe on subsequent reruns.
do $$ begin
 if not exists(select 1 from public.ug_private_config where key='dispatch_alarm_backfilled') then
  update public.report_dispatches set alarm_acked_at=coalesce(ack_at,dispatched_at,now()) where alarm_acked_at is null;
  insert into public.ug_private_config(key,value) values('dispatch_alarm_backfilled','true') on conflict do nothing;
 end if;
end $$;
create or replace function public.dispatch_ack_alarm(p_dispatch_id uuid) returns jsonb language plpgsql security definer set search_path=public as $$
declare v public.report_dispatches; v_name text;
begin
 select * into v from public.report_dispatches where id=p_dispatch_id for update;
 if auth.uid() is null or not public.is_dispatch() or v.unit_id is null or v.unit_id is distinct from public.my_unit_id()
  or not exists(select 1 from public.profiles where id=auth.uid() and not disabled) then raise exception 'Only this unit may acknowledge' using errcode='42501'; end if;
 if v.dispatch_status in ('done','declined') then raise exception 'This dispatch is closed'; end if;
 if v.alarm_acked_at is not null then return jsonb_build_object('ok',true,'dispatch_id',v.id); end if;
 select full_name into v_name from public.profiles where id=auth.uid();
 update public.report_dispatches set alarm_acked_at=now(),alarm_acked_by=auth.uid() where id=v.id;
 if v.dispatch_status='sent' then
  perform public.dispatch_respond(v.id,'acknowledged','Acknowledged by '||coalesce(v_name,''));
 else
  insert into public.report_dispatch_events(dispatch_id,actor,actor_name,action,note) values(v.id,auth.uid(),v_name,'alarm_acknowledged','Human acknowledgement');
  perform public.ug_notify(public.ug_recipients_lgu()||public.ug_recipients_super_admin()||public.ug_recipients_barangay(v.target_barangay_id),
   'dispatch_status','Dispatch acknowledged','Acknowledged by '||coalesce(v_name,''),'advisory','normal',false,null,v.report_id,null,v.id,null,'truck','incident',v.report_id::text);
 end if;
 perform public.write_audit('dispatch.alarm_acked','report_dispatches',v.id,jsonb_build_object('by',v_name));
 return jsonb_build_object('ok',true,'dispatch_id',v.id);
end $$;
revoke all on function public.dispatch_ack_alarm(uuid) from public,anon;
grant execute on function public.dispatch_ack_alarm(uuid) to authenticated;
alter table public.sos_log add column if not exists acked_by uuid references public.profiles(id) on delete set null,
 add column if not exists acked_by_name text,add column if not exists acked_at timestamptz,
 add column if not exists resolved_by uuid references public.profiles(id) on delete set null,
 add column if not exists resolved_by_name text,add column if not exists resolved_at timestamptz;
commit;

begin;
-- Latest body from 051_report_workflow_fixes.sql; notification calls only except documented lifecycle changes.
create or replace function public.apply_corroboration()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  c_radius constant double precision := 500;
  v_barangay_id uuid;
  v_hazard      text;
  v_created     timestamptz;
  v_lat         double precision;
  v_lng         double precision;
  v_count       int;
  v_row         record;
begin
  select barangay_id, hazard_type, created_at, lat, lng
    into v_barangay_id, v_hazard, v_created, v_lat, v_lng
    from public.reports where id = new.report_id;

  if v_hazard is null then
    return new;
  end if;

  select count(distinct u) into v_count from (
    select r.reporter_id as u
      from public.reports r
     where r.hazard_type = v_hazard
       and (r.barangay_id is not distinct from v_barangay_id)
       and r.created_at between v_created - interval '6 hours' and v_created + interval '6 hours'
       and (v_lat is null or r.lat is null
            or public.distance_m(v_lat, v_lng, r.lat, r.lng) <= c_radius)
    union
    select c.user_id
      from public.report_corroborations c
      join public.reports r2 on r2.id = c.report_id
     where r2.hazard_type = v_hazard
       and (r2.barangay_id is not distinct from v_barangay_id)
       and r2.created_at between v_created - interval '6 hours' and v_created + interval '6 hours'
       and (v_lat is null or coalesce(c.lat, r2.lat) is null
            or public.distance_m(v_lat, v_lng, coalesce(c.lat, r2.lat), coalesce(c.lng, r2.lng)) <= c_radius)
  ) s;

  if v_count >= 3 then
    perform set_config('uniguard.reason', 'auto_corroboration', true);
    for v_row in
      update public.reports
         set status = 'verified', verified_at = now()
       where hazard_type = v_hazard
         and (barangay_id is not distinct from v_barangay_id)
         and status = 'reported'
         and created_at between v_created - interval '6 hours' and v_created + interval '6 hours'
         and (v_lat is null or lat is null
              or public.distance_m(v_lat, v_lng, lat, lng) <= c_radius)
      returning id, reporter_id, code
    loop
      if v_row.reporter_id is not null then
        perform * from public.ug_notify_batch((select coalesce(jsonb_agg(to_jsonb(ug_rows)),'[]'::jsonb) from (values (v_row.reporter_id,
                'Your report was auto-verified',
                'Report ' || coalesce(v_row.code, '') || ' reached 3 independent confirmations nearby.',
                'prepared', 'check', 'report_status', v_row.id)) as ug_rows(user_id, title, body, tone, icon, type, report_id)),'{}'::jsonb);
      end if;
    end loop;
  end if;
  return new;
end;
$$;
revoke all on function public.apply_corroboration() from public,anon,authenticated;

-- Latest body from 003_notifications_audit.sql; notification calls only except documented lifecycle changes.
create or replace function public.fanout_advisory(p_advisory_id uuid)
returns int language plpgsql security definer set search_path = public as $$
declare
  v_adv      record;
  v_inserted int := 0;
begin
  select * into v_adv from public.advisories where id = p_advisory_id;
  if v_adv is null then
    return 0;
  end if;

  if auth.uid() is null or not (public.is_lgu() or (public.is_official() and v_adv.author_id=auth.uid())) then raise exception 'Only the publisher or LGU may notify this audience' using errcode='42501'; end if;
  with targets as (
    select p.id
      from public.profiles p
     where p.disabled = false
       and (
         v_adv.citywide
         or exists (select 1 from public.advisory_targets t
                     where t.advisory_id = v_adv.id and t.barangay_id = p.barangay_id)
       )
  ), ins as (
    select * from public.ug_notify_batch((select coalesce(jsonb_agg(to_jsonb(ug_rows)),'[]'::jsonb) from (select id, v_adv.title, left(v_adv.body, 240), v_adv.severity, 'megaphone', v_adv.id from targets) as ug_rows(user_id, title, body, tone, icon, advisory_id)),jsonb_build_object('dedupe_key','advisory:'||p_advisory_id))
  )
  select count(*) into v_inserted from ins;

  return v_inserted;
end;
$$;
revoke all on function public.fanout_advisory(uuid) from public,anon;
grant execute on function public.fanout_advisory(uuid) to authenticated;

-- Latest body from 051_report_workflow_fixes.sql; notification calls only except documented lifecycle changes.
create or replace function public.advance_report_status(p_report_id uuid, p_next text, p_note text default '')
returns jsonb
language plpgsql
security definer set search_path = public
as $$
declare
  v_row      public.reports;
  v_from     text;
  v_role     text;
  v_brgy     uuid;
  v_name     text;
  v_is_super boolean := false;
  v_note     text := trim(coalesce(p_note, ''));
  v_reporter uuid;
  v_code     text;
  v_tone     text;
  v_title    text;
  v_body     text;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in';
  end if;
  if p_next is null or p_next not in ('verified', 'dispatched', 'resolved', 'rejected') then
    raise exception 'Unknown status: %', p_next;
  end if;

  select role, barangay_id, coalesce(full_name, ''), coalesce(is_super_admin, false)
    into v_role, v_brgy, v_name, v_is_super
    from public.profiles where id = auth.uid();

  -- lock the row so two officials clicking at once cannot both pass the
  -- one-step check below
  select * into v_row from public.reports where id = p_report_id for update;
  if v_row.id is null then
    raise exception 'That report does not exist';
  end if;

  if v_role = 'barangay_official' and v_row.barangay_id is distinct from v_brgy then
    raise exception 'That report is outside your barangay';
  end if;
  if v_role is null or v_role not in ('barangay_official', 'lgu_ldrrmc') then
    raise exception 'Only officials and LGU can change an incident status';
  end if;

  if v_is_super and v_row.status = 'reported' and p_next = 'verified' then
    raise exception 'Super Admin cannot verify reports. Use Edit to correct the record instead.';
  end if;

  if v_row.status = p_next then
    raise exception 'This report is already "%".', p_next;
  end if;
  if not (
       (v_row.status = 'reported'   and p_next in ('verified', 'rejected'))
    or (v_row.status = 'verified'   and p_next in ('dispatched', 'rejected'))
    or (v_row.status = 'dispatched' and p_next in ('resolved', 'rejected'))
  ) then
    raise exception 'A report in "%" cannot move to "%". Move one step at a time; resolved and rejected are final.', v_row.status, p_next;
  end if;

  if p_next = 'rejected' and v_note = '' then
    raise exception 'Write the reason for rejecting this report';
  end if;
  if p_next = 'resolved' and v_note = '' then
    raise exception 'Write a closing note before resolving this report';
  end if;

  v_from := v_row.status;
  perform set_config('uniguard.reason', 'rpc', true);
  perform set_config('uniguard.note', v_note, true);

  if p_next = 'verified' then
    update public.reports
       set status           = 'verified',
           verified_by      = auth.uid(),
           verified_by_name = v_name,
           verified_by_role = v_role,
           verified_at      = now()
     where id = p_report_id
     returning * into v_row;
  else
    update public.reports set status = p_next where id = p_report_id returning * into v_row;
  end if;

  perform public.write_audit('report.status_changed', 'reports', p_report_id,
    jsonb_build_object('from', v_from, 'to', p_next, 'note', v_note,
                       'verified_by_role', case when p_next = 'verified' then v_role else null end));

  v_reporter := v_row.reporter_id;
  v_code     := coalesce(v_row.code, '');
  if v_reporter is not null then
    v_tone  := case p_next when 'dispatched' then 'warning' when 'resolved' then 'prepared'
                            when 'rejected'  then 'warning' else 'advisory' end;
    v_title := case p_next
      when 'verified'   then 'Your report was verified'
      when 'dispatched' then 'Response dispatched to your report'
      when 'resolved'   then 'Your report is resolved'
      when 'rejected'   then 'Your report was rejected'
    end;
    v_body  := case p_next
      when 'verified'   then 'Report ' || v_code || ' was reviewed and verified' ||
                            case when v_role = 'lgu_ldrrmc' then ' by the Municipal DRRMO.' else '.' end
      when 'dispatched' then 'A responder unit has been dispatched for ' || v_code || '.'
      when 'resolved'   then 'Report ' || v_code || ' is resolved. Closing note: ' || left(v_note, 140)
      when 'rejected'   then 'Report ' || v_code || ' was rejected: ' || left(v_note, 140)
    end;
    perform * from public.ug_notify_batch((select coalesce(jsonb_agg(to_jsonb(ug_rows)),'[]'::jsonb) from (values (v_reporter, v_title, v_body, v_tone, 'check', 'report_status', v_row.id)) as ug_rows(user_id, title, body, tone, icon, type, report_id)),'{}'::jsonb);
  end if;

  return jsonb_build_object('id', v_row.id, 'code', v_row.code, 'status', v_row.status,
                            'resolved_at', v_row.resolved_at);
end;
$$;
revoke all on function public.advance_report_status(uuid,text,text) from public,anon,authenticated;
grant execute on function public.advance_report_status(uuid,text,text) to authenticated;

-- Latest body from 012_road_works.sql; notification calls only except documented lifecycle changes.
create or replace function public.fanout_road_work(p_post_id uuid)
returns int language plpgsql security definer set search_path = public as $$
declare
  v_post     record;
  v_inserted int := 0;
begin
  select * into v_post from public.road_work_posts where id = p_post_id;
  if v_post is null then return 0; end if;

  if auth.uid() is null or not (public.is_lgu() or (public.is_official() and v_post.author_id=auth.uid())) then raise exception 'Only the publisher or LGU may notify this audience' using errcode='42501'; end if;
  with targets as (
    select p.id
      from public.profiles p
     where p.disabled = false
       and (
         v_post.citywide
         or exists (select 1 from public.barangays b
                     where b.id = p.barangay_id and b.name = v_post.barangay)
       )
  ), ins as (
    select * from public.ug_notify_batch((select coalesce(jsonb_agg(to_jsonb(ug_rows)),'[]'::jsonb) from (select id, v_post.title, left(coalesce(v_post.description, ''), 240), 'warning', 'road', 'road_work', v_post.id from targets) as ug_rows(user_id, title, body, tone, icon, type, road_work_id)),jsonb_build_object('dedupe_key','roadwork:'||p_post_id))
  )
  select count(*) into v_inserted from ins;

  return v_inserted;
end;
$$;
revoke all on function public.fanout_road_work(uuid) from public,anon;
grant execute on function public.fanout_road_work(uuid) to authenticated;

-- Latest body from 060_sos_barangay_and_default_dispatch.sql; notification calls only except documented lifecycle changes.
create or replace function public.submit_sos(
  p_lat      double precision,
  p_lng      double precision,
  p_accuracy double precision default null,
  p_note     text default '',
  p_kind     text default 'other'
)
returns jsonb
language plpgsql
security definer set search_path = public
as $$
declare
  v_id      uuid;
  v_row     public.sos_log;
  v_prof    record;
  v_reach   int := 0;
  v_brgy_id uuid;
  v_brgy    text;
  v_kind    text := lower(coalesce(nullif(trim(p_kind), ''), 'other'));
  v_label   text;
  v_teams   text[];
  v_rep     uuid;
  v_sent    int := 0;
  v_err     text := '';
  v_names   text;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in to send an SOS';
  end if;
  if v_kind not in ('medical', 'fire', 'crime', 'rescue', 'other') then
    raise exception 'Unknown SOS type: %', p_kind;
  end if;

  perform public.check_rate_limit('sos', 5, interval '10 minutes');

  select full_name, phone, barangay, barangay_id into v_prof from public.profiles where id = auth.uid();

  -- the barangay where the emergency is; the profile's when that is unknown
  if p_lat is not null and p_lng is not null then
    begin
      v_brgy_id := public.resolve_barangay(p_lat, p_lng);
    exception when others then
      v_brgy_id := null;   -- outside Lingayen
    end;
  end if;
  if v_brgy_id is null then
    v_brgy_id := v_prof.barangay_id;
    if v_brgy_id is null and coalesce(v_prof.barangay, '') <> '' then
      select id into v_brgy_id from public.barangays where name = v_prof.barangay limit 1;
    end if;
  end if;
  select name into v_brgy from public.barangays where id = v_brgy_id;
  v_brgy := coalesce(v_brgy, v_prof.barangay, '');

  v_label := case v_kind when 'medical' then 'Medical emergency' when 'fire' then 'Fire'
                         when 'crime' then 'Crime / violence' when 'rescue' then 'Rescue needed'
                         else 'Other / not sure' end;
  v_teams := case v_kind when 'medical' then array['Ambulance', 'Barangay Response Team']
                         when 'fire'    then array['BFP', 'Barangay Response Team']
                         when 'crime'   then array['PNP', 'Barangay Response Team']
                         when 'rescue'  then array['Rescue Unit', 'Barangay Response Team']
                         else array['Barangay Response Team'] end;

  insert into public.sos_log (user_id, profile_name, profile_phone, barangay, barangay_id, lat, lng, accuracy, note, kind)
  values (auth.uid(),
          coalesce(v_prof.full_name, ''),
          coalesce(v_prof.phone, ''),
          v_brgy,
          v_brgy_id,
          p_lat, p_lng, p_accuracy, coalesce(p_note, ''), v_kind)
  returning * into v_row;
  v_id := v_row.id;

  -- Duty officers and officials siren; Super Admin is a silent backstop.
  v_reach := public.ug_notify(public.ug_recipients_lgu()||public.ug_recipients_barangay(v_brgy_id),
    'sos','SOS · '||v_label||' · '||coalesce(v_prof.full_name,'a resident'),
    coalesce(v_prof.phone,'')||' · '||v_brgy||' · '||coalesce(round(p_accuracy::numeric)::text||' m','no GPS fix'),
    'emergency','critical',true,'sos:'||v_id,null,v_id,null,null,'alert','sos',v_id::text);
  v_reach := v_reach + public.ug_notify(public.ug_recipients_super_admin(),
    'sos','SOS · '||v_label||' · '||coalesce(v_prof.full_name,'a resident'),
    coalesce(v_prof.phone,'')||' · '||v_brgy||' · '||coalesce(round(p_accuracy::numeric)::text||' m','no GPS fix'),
    'emergency','urgent',true,'sos:'||v_id,null,v_id,null,null,'alert','sos',v_id::text);

  -- an SOS with a position becomes an emergency report and its teams are
  -- sent at once. If that fails (outside Lingayen, report limit) the SOS
  -- itself still stands and the duty officers handle it.
  if p_lat is not null and p_lng is not null then
    begin
      perform set_config('uniguard.sos_submission','1',true);
      insert into public.reports (hazard_type, hazard_other_text, barangay, description, severity, urgency, lat, lng)
      values (case when v_kind = 'fire' then 'Fire' else 'Others' end,
              case when v_kind = 'fire' then null else 'SOS: ' || v_label end,
              v_brgy,
              left('SOS (' || v_label || ') from ' || coalesce(v_prof.full_name, 'a resident') ||
                   ', ' || coalesce(nullif(v_prof.phone, ''), 'no number') ||
                   case when coalesce(trim(p_note), '') <> '' then '. ' || trim(p_note) else '' end, 1000),
              'emergency', 'emergency', p_lat, p_lng)
      returning id into v_rep;
      perform set_config('uniguard.sos_submission','0',true);

      perform set_config('uniguard.reason', 'sos', true);
      update public.reports
         set status = 'verified', verified_at = now(), verified_by_name = 'SOS', verified_by_role = ''
       where id = v_rep and status = 'reported';

      v_sent := public.ug_auto_dispatch(v_rep, v_teams, 'sos');
      -- stays 'sent' (New) until a duty officer or official acknowledges it
      update public.sos_log set report_id = v_rep where id = v_id;
    exception when others then
      v_err := sqlerrm;
      v_rep := null;
      v_sent := 0;
    end;
  end if;

  -- the teams actually on the report (a team with no free unit is skipped)
  if v_rep is not null then
    select string_agg(d.team, ', ' order by d.dispatched_at) into v_names
      from public.report_dispatches d
     where d.report_id = v_rep and d.dispatch_status not in ('done', 'declined');
  end if;

  perform public.write_audit('sos.received', 'sos_log', v_id,
    jsonb_build_object('lat', p_lat, 'lng', p_lng, 'accuracy', p_accuracy, 'reach', v_reach,
                       'kind', v_kind, 'barangay_id', v_brgy_id, 'report_id', v_rep,
                       'dispatched', v_sent, 'report_error', nullif(v_err, '')));

  return jsonb_build_object('id', v_id, 'reach', v_reach, 'kind', v_kind,
                            'report_id', v_rep, 'dispatched', v_sent, 'team', v_names);
end;
$$;
revoke all on function public.submit_sos(double precision,double precision,double precision,text,text) from public,anon,authenticated;
grant execute on function public.submit_sos(double precision,double precision,double precision,text,text) to authenticated;

-- Latest body from 051_report_workflow_fixes.sql; notification calls only except documented lifecycle changes.
create or replace function public.evaluate_corroboration(p_report_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_barangay_id uuid;
  v_hazard      text;
  v_created     timestamptz;
  v_count       int;
  v_row         record;
begin
  select barangay_id, hazard_type, created_at
    into v_barangay_id, v_hazard, v_created
    from public.reports where id = p_report_id;

  if v_hazard is null or v_hazard = '' then return; end if;

  select count(distinct u) into v_count from (
    select r.reporter_id as u
      from public.reports r
     where r.hazard_type = v_hazard
       and (r.barangay_id is not distinct from v_barangay_id)
       and r.status <> 'rejected'
       and r.created_at between v_created - interval '6 hours' and v_created + interval '6 hours'
    union
    select c.user_id
      from public.report_corroborations c
      join public.reports r2 on r2.id = c.report_id
     where r2.hazard_type = v_hazard
       and (r2.barangay_id is not distinct from v_barangay_id)
       and r2.status <> 'rejected'
       and r2.created_at between v_created - interval '6 hours' and v_created + interval '6 hours'
  ) s
  where u is not null;

  if v_count >= 3 then
    perform set_config('uniguard.reason', 'auto_corroboration', true);
    for v_row in
      update public.reports
         set status = 'verified', verified_at = now()
       where hazard_type = v_hazard
         and (barangay_id is not distinct from v_barangay_id)
         and status = 'reported'
         and created_at between v_created - interval '6 hours' and v_created + interval '6 hours'
      returning id, reporter_id, code
    loop
      if v_row.reporter_id is not null then
        perform * from public.ug_notify_batch((select coalesce(jsonb_agg(to_jsonb(ug_rows)),'[]'::jsonb) from (values (v_row.reporter_id,
                'Your report was auto-verified',
                'Report ' || coalesce(v_row.code, '') || ' reached 3 independent confirmations in your barangay.',
                'prepared', 'check', 'report_status', v_row.id)) as ug_rows(user_id, title, body, tone, icon, type, report_id)),'{}'::jsonb);
      end if;
    end loop;
  end if;
end;
$$;
revoke all on function public.evaluate_corroboration(uuid) from public,anon,authenticated;

-- Latest body from 029_barangay_scoping.sql; notification calls only except documented lifecycle changes.
create or replace function public.update_sos_status(p_sos_id uuid, p_status text)
returns jsonb
language plpgsql
security definer set search_path = public as $$
declare
  v_row public.sos_log;
  v_role text;
begin
  if auth.uid() is null then raise exception 'You must be signed in'; end if;
  if p_status not in ('acknowledged', 'resolved') then
    raise exception 'Unknown SOS status: %', p_status;
  end if;

  select role into v_role from public.profiles where id = auth.uid();
  if v_role not in ('barangay_official', 'lgu_ldrrmc') then
    raise exception 'Only officials and LGU can update an SOS';
  end if;

  select * into v_row from public.sos_log where id = p_sos_id for update;
  if v_row.id is null then raise exception 'That SOS entry does not exist'; end if;

  if v_role = 'barangay_official' then
    if v_row.barangay_id is not null and v_row.barangay_id is distinct from public.my_barangay_id() then
      raise exception 'That SOS entry is outside your barangay';
    end if;
    if v_row.barangay_id is null and coalesce(v_row.barangay, '') is distinct from public.my_barangay_name() then
      raise exception 'That SOS entry is outside your barangay';
    end if;
  end if;

  if v_row.status = p_status or v_row.status = 'resolved' then
    return jsonb_build_object('id',v_row.id,'status',v_row.status);
  end if;
  if not exists(select 1 from public.profiles where id=auth.uid() and not disabled) then raise exception 'Account disabled'; end if;
  update public.sos_log set
    acked_at=case when p_status='acknowledged' then coalesce(acked_at,now()) else acked_at end,
    acked_by=case when p_status='acknowledged' then coalesce(acked_by,auth.uid()) else acked_by end,
    acked_by_name=case when p_status='acknowledged' then coalesce(acked_by_name,(select full_name from public.profiles where id=auth.uid())) else acked_by_name end,
    resolved_at=case when p_status='resolved' then now() else resolved_at end,
    resolved_by=case when p_status='resolved' then auth.uid() else resolved_by end,
    resolved_by_name=case when p_status='resolved' then (select full_name from public.profiles where id=auth.uid()) else resolved_by_name end,
    status = p_status where id = p_sos_id returning * into v_row;

  perform public.write_audit('sos.status_changed', 'sos_log', p_sos_id,
    jsonb_build_object('to', p_status));

  -- tell the sender their SOS was picked up / closed
  if v_row.user_id is not null then
    perform * from public.ug_notify_batch((select coalesce(jsonb_agg(to_jsonb(ug_rows)),'[]'::jsonb) from (values (v_row.user_id,
            case p_status when 'acknowledged' then 'Your SOS was received — help is being arranged'
                          else 'Your SOS is resolved' end,
            'Status of your SOS from ' || coalesce(v_row.barangay, 'your barangay') || ' is now ' || p_status || '.',
            case p_status when 'acknowledged' then 'warning' else 'prepared' end,
            'check', 'sos', v_row.id)) as ug_rows(user_id, title, body, tone, icon, type, sos_id)),'{}'::jsonb);
  end if;

  return jsonb_build_object('id', v_row.id, 'status', v_row.status);
end;
$$;
revoke all on function public.update_sos_status(uuid,text) from public,anon,authenticated;
grant execute on function public.update_sos_status(uuid,text) to authenticated;

-- Latest body from 051_report_workflow_fixes.sql; notification calls only except documented lifecycle changes.
create or replace function public.fanout_dispatch(
  p_report_id          uuid,
  p_dispatch_id        uuid,
  p_team               text,
  p_target_barangay_id uuid,
  p_unit_id            uuid,
  p_instructions       text,
  p_skip_reporter      boolean default false
)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row       public.reports;
  v_title     text;
  v_body      text;
  v_unit_tone text;
  v_count     int := 0;
begin
  select * into v_row from public.reports where id = p_report_id;
  if v_row.id is null then
    return 0;
  end if;

  v_title := 'Response dispatched to ' || coalesce(v_row.barangay, 'your barangay');
  v_body  := left(p_team || ': ' || coalesce(p_instructions, ''), 240);

  if p_team = 'Barangay Response Team' then
    v_unit_tone := 'warning';  -- action alert, the barangay's team is going
  else
    v_unit_tone := 'advisory'; -- info, a municipality unit is coming
  end if;

  -- reporter + LGU + the report's barangay. Never another barangay. The
  -- reporter is skipped when advance_report_status already told them.
  with targets as (
    select p.id
      from public.profiles p
     where p.disabled = false
       and (
         (p.id = v_row.reporter_id and not p_skip_reporter)
         or p.role in ('lgu_ldrrmc')
         or (v_row.barangay_id is not null and p.barangay_id = v_row.barangay_id)
       )
       and not (p_skip_reporter and p.id is not distinct from v_row.reporter_id)
  ), ins as (
    select * from public.ug_notify_batch((select coalesce(jsonb_agg(to_jsonb(ug_rows)),'[]'::jsonb) from (select id, v_title, v_body, v_unit_tone, 'truck', 'dispatch', v_row.id from targets) as ug_rows(user_id, title, body, tone, icon, type, report_id)),'{}'::jsonb)
  )
  select count(*) into v_count from ins;

  -- the dispatched unit's users (municipality-wide teams only)
  if p_unit_id is not null and p_team <> 'Barangay Response Team' then
    perform * from public.ug_notify_batch((select coalesce(jsonb_agg(to_jsonb(ug_rows)),'[]'::jsonb) from (select p.id, 'Incoming dispatch: ' || p_team,
           left(p_team || ' · ' || coalesce(p_instructions, '') ||
                ' · ' || coalesce(v_row.barangay, 'unknown barangay'), 240),
           'warning', 'truck', 'unit_dispatch', v_row.id
      from public.profiles p
     where p.disabled = false
       and p.role = 'dispatch_team'
       and p.dispatch_unit_id = p_unit_id) as ug_rows(user_id, title, body, tone, icon, type, report_id)),jsonb_build_object('type','dispatch','priority','critical','requires_ack',true,'dispatch_id',p_dispatch_id,'target_route','dispatch','target_id',p_dispatch_id,'dedupe_key','dispatch:'||p_dispatch_id));
  end if;

  return v_count;
end;
$$;
revoke all on function public.fanout_dispatch(uuid,uuid,text,uuid,uuid,text,boolean) from public,anon,authenticated;

-- Latest body from 051_report_workflow_fixes.sql; notification calls only except documented lifecycle changes.
create or replace function public.lgu_verify_report(p_report_id uuid, p_note text default '')
returns jsonb
language plpgsql
security definer set search_path = public
as $$
declare
  v_row      public.reports;
  v_role     text;
  v_name     text;
  v_is_super boolean := false;
  v_note     text := trim(coalesce(p_note, ''));
  v_reporter uuid;
  v_code     text;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in';
  end if;

  select role, coalesce(full_name, ''), coalesce(is_super_admin, false)
    into v_role, v_name, v_is_super
    from public.profiles where id = auth.uid();

  if v_role is null then
    raise exception 'Your account could not be loaded';
  end if;
  if v_role <> 'lgu_ldrrmc' then
    raise exception 'Only LGU / LDRRMC can LGU-verify a report';
  end if;
  if v_is_super then
    raise exception 'Super Admin cannot verify reports. Use Edit to correct the record instead.';
  end if;

  select * into v_row from public.reports where id = p_report_id for update;
  if v_row.id is null then
    raise exception 'That report does not exist';
  end if;
  if v_row.status <> 'reported' then
    raise exception 'Only a report still in "reported" can be LGU-verified (it is "%")', v_row.status;
  end if;

  perform set_config('uniguard.reason', 'lgu_verify', true);
  perform set_config('uniguard.note',  v_note, true);

  update public.reports
     set status           = 'verified',
         verified_by      = auth.uid(),
         verified_by_name = v_name,
         verified_by_role = 'lgu_ldrrmc',
         verified_at      = now()
   where id = p_report_id
   returning * into v_row;

  perform public.write_audit('report.lgu_verified', 'reports', p_report_id,
    jsonb_build_object('note', left(v_note, 300), 'verified_by', v_name));

  v_reporter := v_row.reporter_id;
  v_code     := coalesce(v_row.code, '');
  if v_reporter is not null then
    perform * from public.ug_notify_batch((select coalesce(jsonb_agg(to_jsonb(ug_rows)),'[]'::jsonb) from (values (v_reporter,
            'Your report was LGU-verified',
            'Report ' || v_code || ' was verified by the Municipal DRRMO' ||
              case when v_note <> '' then ' — ' || left(v_note, 140) else '' end,
            'prepared', 'shield', 'report_status', v_row.id)) as ug_rows(user_id, title, body, tone, icon, type, report_id)),'{}'::jsonb);
  end if;

  return jsonb_build_object('id', v_row.id, 'code', v_row.code, 'status', v_row.status,
                            'verified_by', v_name, 'verified_by_role', 'lgu_ldrrmc');
end;
$$;
revoke all on function public.lgu_verify_report(uuid,text) from public,anon,authenticated;
grant execute on function public.lgu_verify_report(uuid,text) to authenticated;

-- Latest body from 051_report_workflow_fixes.sql; notification calls only except documented lifecycle changes.
create or replace function public.dispatch_respond(
  p_dispatch_id uuid,
  p_action      text,
  p_note        text default ''
)
returns jsonb
language plpgsql
security definer set search_path = public
as $$
declare
  v_row      public.report_dispatches;
  v_target   uuid;
  v_role     text;
  v_name     text;
  v_report   public.reports;
  v_now      timestamptz := now();
  v_tone     text;
  v_title    text;
  v_body     text;
  v_team     text;
  v_hospital uuid;
  v_new      text;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in';
  end if;
  if p_action is null or p_action not in (
      'acknowledged','en_route','on_scene','done',
      'under_control','fire_out','on_hold','resume',
      'transporting','arrived_hospital'
    ) then
    raise exception 'Unknown action: %', p_action;
  end if;

  select role, coalesce(full_name, '') into v_role, v_name
    from public.profiles where id = auth.uid();

  select * into v_row from public.report_dispatches where id = p_dispatch_id for update;
  if v_row.id is null then
    raise exception 'That dispatch does not exist';
  end if;

  if v_row.dispatch_status = 'declined' then
    raise exception 'That dispatch was declined; no further action is allowed';
  end if;

  if v_role is distinct from 'lgu_ldrrmc' then
    if v_row.unit_id is not null then
      if v_role is distinct from 'dispatch_team' or v_row.unit_id is distinct from public.my_unit_id() then
        raise exception 'Only this unit''s users may respond to this dispatch';
      end if;
    else
      if v_role is distinct from 'barangay_official' then
        raise exception 'Only the barangay official may respond to this dispatch';
      end if;
      select * into v_report from public.reports where id = v_row.report_id;
      if v_report.barangay_id is distinct from public.my_barangay_id() then
        raise exception 'This dispatch is outside your barangay';
      end if;
    end if;
  end if;

  if public.is_super_admin() then raise exception 'Super Admin cannot respond to dispatches'; end if;
  v_team := v_row.team;

  if not (
    (v_row.dispatch_status = 'sent'         and p_action = 'acknowledged')
    or (v_row.dispatch_status = 'acknowledged' and p_action in ('en_route','on_scene','done'))
    or (v_row.dispatch_status = 'en_route'   and p_action in ('on_scene','done'))
    or (v_row.dispatch_status = 'on_scene'   and p_action = 'done')
    -- BFP: on_scene -> under_control -> fire_out -> done
    or (v_team = 'BFP' and v_row.dispatch_status = 'on_scene'      and p_action = 'under_control')
    or (v_team = 'BFP' and v_row.dispatch_status = 'under_control' and p_action in ('fire_out','done'))
    or (v_team = 'BFP' and v_row.dispatch_status = 'fire_out'      and p_action = 'done')
    -- Rescue: en_route/on_scene -> on_hold -> resume (back to on_scene)
    or (v_team in ('Rescue Unit','MDRRMO Rescue')
        and v_row.dispatch_status in ('en_route','on_scene')
        and p_action = 'on_hold')
    or (v_team in ('Rescue Unit','MDRRMO Rescue')
        and v_row.dispatch_status = 'on_hold'
        and p_action = 'resume')
    -- Ambulance: on_scene -> transporting -> arrived_hospital -> done
    or (v_team = 'Ambulance' and v_row.dispatch_status = 'on_scene'         and p_action = 'transporting')
    or (v_team = 'Ambulance' and v_row.dispatch_status = 'transporting'     and p_action = 'arrived_hospital')
    or (v_team = 'Ambulance' and v_row.dispatch_status = 'arrived_hospital' and p_action = 'done')
  ) then
    raise exception 'A dispatch in "%" (team %) cannot move to "%"', v_row.dispatch_status, v_team, p_action;
  end if;

  if p_action = 'on_hold' and coalesce(trim(p_note), '') = '' then
    raise exception 'A hold reason is required';
  end if;

  if p_action = 'transporting' then
    v_hospital := nullif(v_row.field_data->>'hospital_id', '')::uuid;
    if v_hospital is null then
      raise exception 'Choose an accepting hospital before transporting';
    end if;
    if not exists (
      select 1 from public.hospital_capacity h
        join public.dispatch_units u on u.id = h.unit_id
       where h.unit_id = v_hospital and h.accepting = true and u.active = true
    ) then
      raise exception 'The chosen hospital is not accepting patients';
    end if;
  end if;

  -- 'resume' is an event, not a stored status: the rescue is back on scene
  v_new := case when p_action = 'resume' then 'on_scene' else p_action end;

  update public.report_dispatches
     set dispatch_status = v_new,
         ack_at      = case when p_action = 'acknowledged' then v_now else ack_at end,
         en_route_at = case when p_action = 'en_route'     then v_now else en_route_at end,
         on_scene_at = case when p_action = 'on_scene' or (p_action = 'resume' and on_scene_at is null)
                            then v_now else on_scene_at end,
         done_at     = case when p_action = 'done'         then v_now else done_at end,
         hold_reason = case when p_action = 'on_hold' then left(coalesce(trim(p_note), ''), 500)
                            when p_action = 'resume'  then ''
                            else hold_reason end
   where id = p_dispatch_id;

  insert into public.report_dispatch_events (dispatch_id, actor, actor_name, action, note)
  values (p_dispatch_id, auth.uid(), v_name, p_action, left(coalesce(p_note, ''), 240));

  perform public.write_audit('dispatch.responded', 'report_dispatches', p_dispatch_id,
    jsonb_build_object('action', p_action, 'status', v_new, 'note', left(coalesce(p_note, ''), 240)));

  select * into v_report from public.reports where id = v_row.report_id;
  v_target := v_report.barangay_id;

  v_tone  := case p_action
    when 'acknowledged'     then 'advisory'
    when 'en_route'         then 'advisory'
    when 'on_scene'         then 'warning'
    when 'under_control'    then 'warning'
    when 'fire_out'         then 'prepared'
    when 'on_hold'          then 'warning'
    when 'resume'           then 'warning'
    when 'transporting'     then 'warning'
    when 'arrived_hospital' then 'prepared'
    when 'done'             then 'prepared'
  end;
  v_title := case p_action
    when 'acknowledged'     then 'Dispatch acknowledged'
    when 'en_route'         then 'Responder en route'
    when 'on_scene'         then 'Responder on scene'
    when 'under_control'    then 'Fire under control'
    when 'fire_out'         then 'Fire out'
    when 'on_hold'          then 'Rescue on hold'
    when 'resume'           then 'Rescue resumed'
    when 'transporting'     then 'Ambulance transporting'
    when 'arrived_hospital' then 'Patient arrived at hospital'
    when 'done'             then 'Dispatch complete'
  end;
  v_body  := case p_action
    when 'acknowledged'     then 'Response to ' || coalesce(v_report.code, '') || ' is acknowledged.'
    when 'en_route'         then 'Response to ' || coalesce(v_report.code, '') || ' is en route.'
    when 'on_scene'         then 'Response to ' || coalesce(v_report.code, '') || ' is on scene.'
    when 'under_control'    then 'Response to ' || coalesce(v_report.code, '') || ': fire is under control.'
    when 'fire_out'         then 'Response to ' || coalesce(v_report.code, '') || ': fire is out.'
    when 'on_hold'          then 'Response to ' || coalesce(v_report.code, '') || ' is on hold. Reason: ' || coalesce(trim(p_note), '')
    when 'resume'           then 'Response to ' || coalesce(v_report.code, '') || ' resumed operations.'
    when 'transporting'     then 'Ambulance for ' || coalesce(v_report.code, '') || ' is transporting.'
    when 'arrived_hospital' then 'Ambulance for ' || coalesce(v_report.code, '') || ' arrived at hospital.'
    when 'done'             then 'Response to ' || coalesce(v_report.code, '') || ' is done.'
  end;

  perform * from public.ug_notify_batch((select coalesce(jsonb_agg(to_jsonb(ug_rows)),'[]'::jsonb) from (select p.id, v_title, v_body, v_tone, 'truck', 'dispatch_status', v_report.id
    from public.profiles p
   where p.disabled = false
     and (
       p.role = 'lgu_ldrrmc'
       or (v_target is not null and p.barangay_id = v_target and p.role = 'barangay_official')
     )) as ug_rows(user_id, title, body, tone, icon, type, report_id)),'{}'::jsonb);

  if p_action in ('en_route','on_scene','under_control','fire_out','on_hold','resume',
                  'transporting','arrived_hospital','done')
     and v_report.reporter_id is not null then
    perform * from public.ug_notify_batch((select coalesce(jsonb_agg(to_jsonb(ug_rows)),'[]'::jsonb) from (values (v_report.reporter_id, v_title, v_body, v_tone, 'check', 'dispatch_status', v_report.id)) as ug_rows(user_id, title, body, tone, icon, type, report_id)),'{}'::jsonb);
  end if;

  if p_action = 'done' then
    perform public.release_dispatch_equipment(array[p_dispatch_id]);
  end if;

  return jsonb_build_object('dispatch_id', p_dispatch_id, 'action', p_action,
                            'status', v_new, 'at', v_now);
end;
$$;
revoke all on function public.dispatch_respond(uuid,text,text) from public,anon,authenticated;
grant execute on function public.dispatch_respond(uuid,text,text) to authenticated;

-- Latest body from 049_dispatch_team_features.sql; notification calls only except documented lifecycle changes.
create or replace function public.send_patient_notice(
  p_unit_id    uuid,
  p_report_id  uuid default null,
  p_patients   int default 1,
  p_condition  text default '',
  p_eta        timestamptz default null
)
returns jsonb
language plpgsql
security definer set search_path = public
as $$
declare
  v_role text;
  v_name text;
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'You must be signed in'; end if;
  if not exists (select 1 from public.dispatch_units where id = p_unit_id and unit_type = 'Hospital' and active = true) then
    raise exception 'That hospital does not exist';
  end if;
  -- F2: must be accepting
  if not exists (select 1 from public.hospital_capacity where unit_id = p_unit_id and accepting = true) then
    raise exception 'That hospital is not accepting patients';
  end if;

  select role, coalesce(full_name, '') into v_role, v_name
    from public.profiles where id = auth.uid();
  if v_role not in ('lgu_ldrrmc','barangay_official','dispatch_team') then
    raise exception 'Only officials, LGU or responders may send a patient notice';
  end if;

  insert into public.patient_notices (unit_id, report_id, patients, condition, eta, sent_by, status)
  values (p_unit_id, p_report_id, greatest(p_patients, 1), left(coalesce(p_condition, ''), 240), p_eta, auth.uid(), 'sent')
  returning id into v_id;

  perform * from public.ug_notify_batch((select coalesce(jsonb_agg(to_jsonb(ug_rows)),'[]'::jsonb) from (select p.id, 'Incoming patient notice', left(p_patients || ' patient(s) · ' || p_condition, 240),
         'warning', 'truck', 'patient_notice'
    from public.profiles p
   where p.disabled = false
     and p.role = 'dispatch_team'
     and p.dispatch_unit_id = p_unit_id) as ug_rows(user_id, title, body, tone, icon, type)),jsonb_build_object('target_route','hospital'));

  perform public.write_audit('patient.notice_sent', 'patient_notices', v_id,
    jsonb_build_object('unit_id', p_unit_id, 'patients', p_patients, 'sent_by', v_name));

  return jsonb_build_object('id', v_id, 'unit_id', p_unit_id);
end;
$$;
revoke all on function public.send_patient_notice(uuid,uuid,int,text,timestamptz) from public,anon,authenticated;
grant execute on function public.send_patient_notice(uuid,uuid,int,text,timestamptz) to authenticated;

-- Latest body from 040_dispatch_rpcs.sql; notification calls only except documented lifecycle changes.
create or replace function public.create_unit_request(
  p_unit_id uuid,
  p_kind    text,
  p_details text
)
returns jsonb
language plpgsql
security definer set search_path = public
as $$
declare
  v_role text;
  v_unit uuid;
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'You must be signed in'; end if;
  select role, dispatch_unit_id into v_role, v_unit
    from public.profiles where id = auth.uid();
  if v_role <> 'lgu_ldrrmc' and (v_role <> 'dispatch_team' or v_unit is distinct from p_unit_id) then
    raise exception 'Not your unit';
  end if;
  if p_kind not in ('fuel','personnel','equipment','mutual_aid','other') then
    raise exception 'Unknown request kind';
  end if;

  insert into public.unit_requests (unit_id, kind, details, created_by, status)
  values (p_unit_id, p_kind, left(coalesce(p_details, ''), 1000), auth.uid(), 'pending')
  returning id into v_id;

  -- notify every LGU user
  perform * from public.ug_notify_batch((select coalesce(jsonb_agg(to_jsonb(ug_rows)),'[]'::jsonb) from (select p.id, 'Support request from ' || (select name from public.dispatch_units where id = p_unit_id),
         left(p_kind || ': ' || p_details, 240), 'warning', 'inbox', 'unit_request'
    from public.profiles p
   where p.disabled = false and p.role = 'lgu_ldrrmc') as ug_rows(user_id, title, body, tone, icon, type)),'{}'::jsonb);

  return jsonb_build_object('id', v_id, 'status', 'pending');
end;
$$;
revoke all on function public.create_unit_request(uuid,text,text) from public,anon,authenticated;
grant execute on function public.create_unit_request(uuid,text,text) to authenticated;

-- Latest body from 040_dispatch_rpcs.sql; notification calls only except documented lifecycle changes.
create or replace function public.decide_unit_request(
  p_request_id uuid,
  p_decision   text,
  p_note       text default ''
)
returns jsonb
language plpgsql
security definer set search_path = public
as $$
declare
  v_row public.unit_requests;
  v_role text;
  v_name text;
begin
  if auth.uid() is null then raise exception 'You must be signed in'; end if;
  if p_decision not in ('approved','declined','done') then
    raise exception 'Decision must be approved, declined or done';
  end if;
  select * into v_row from public.unit_requests where id = p_request_id;
  if v_row.id is null then raise exception 'That request does not exist'; end if;

  select role, coalesce(full_name, '') into v_role, v_name
    from public.profiles where id = auth.uid();
  -- only the LGU may decide; a unit_admin may close a request to 'done'
  -- when they consider it delivered
  if v_role = 'lgu_ldrrmc' then
    null;
  elsif v_role = 'dispatch_team' and public.is_unit_admin() and p_decision = 'done' and v_row.unit_id = public.my_unit_id() then
    null;
  else
    raise exception 'Only the LGU may decide a support request';
  end if;

  update public.unit_requests
     set status = p_decision, decided_by = auth.uid(), decided_at = now()
   where id = p_request_id;

  -- notify the unit's users
  perform * from public.ug_notify_batch((select coalesce(jsonb_agg(to_jsonb(ug_rows)),'[]'::jsonb) from (select p.id, 'Support request ' || p_decision,
         left(coalesce(p_note, '') || ' · ' || v_row.kind, 240),
         case when p_decision = 'approved' then 'prepared' when p_decision = 'done' then 'prepared' else 'warning' end,
         'check', 'unit_request'
    from public.profiles p
   where p.disabled = false and p.role = 'dispatch_team' and p.dispatch_unit_id = v_row.unit_id) as ug_rows(user_id, title, body, tone, icon, type)),'{}'::jsonb);

  perform public.write_audit('unit_request.decided', 'unit_requests', p_request_id,
    jsonb_build_object('decision', p_decision, 'note', left(coalesce(p_note, ''), 240), 'by', v_name));

  return jsonb_build_object('id', p_request_id, 'status', p_decision);
end;
$$;
revoke all on function public.decide_unit_request(uuid,text,text) from public,anon,authenticated;
grant execute on function public.decide_unit_request(uuid,text,text) to authenticated;

-- Latest body from 046_super_admin_verify_block_and_change_requests.sql; notification calls only except documented lifecycle changes.
create or replace function public.approve_change_request(
  p_request_id    uuid,
  p_decision_note text default ''
)
returns public.change_requests
language plpgsql
security definer set search_path = public
as $$
declare
  v_row    public.change_requests;
  v_name   text;
  v_id     uuid;
  v_proposed jsonb;
  v_current jsonb;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in';
  end if;
  if not public.is_super_admin() then
    raise exception 'Only the Super Admin can approve a change request';
  end if;

  select * into v_row from public.change_requests where id = p_request_id;
  if v_row.id is null then
    raise exception 'That change request does not exist';
  end if;
  if v_row.status <> 'pending' then
    raise exception 'That change request has already been decided (%)', v_row.status;
  end if;

  select coalesce(full_name,'') into v_name from public.profiles where id = auth.uid();
  v_proposed := v_row.proposed_data;
  v_current  := v_row.current_data;

  -- Apply the change to the target table. Only emergency_hotlines is wired up
  -- in this migration; additional tables can be added here as needed.
  if v_row.target_table = 'emergency_hotlines' then
    if v_row.action = 'add' then
      insert into public.emergency_hotlines (agency_name, contact_number, scope, description, barangay_id, active)
      values (
        coalesce(v_proposed->>'agency_name',''),
        coalesce(v_proposed->>'contact_number',''),
        coalesce(v_proposed->>'scope','Municipality-wide'),
        coalesce(v_proposed->>'description',''),
        nullif(v_proposed->>'barangay_id','')::uuid,
        coalesce((v_proposed->>'active')::boolean, true)
      ) returning id into v_id;
    elsif v_row.action = 'edit' then
      update public.emergency_hotlines
         set agency_name    = coalesce(v_proposed->>'agency_name', agency_name),
             contact_number = coalesce(v_proposed->>'contact_number', contact_number),
             scope          = coalesce(v_proposed->>'scope', scope),
             description    = coalesce(v_proposed->>'description', description),
             active         = coalesce((v_proposed->>'active')::boolean, active),
             updated_at     = now()
       where id = v_row.target_id
       returning id into v_id;
      v_id := v_row.target_id;
    elsif v_row.action = 'delete' then
      delete from public.emergency_hotlines where id = v_row.target_id returning id into v_id;
      v_id := v_row.target_id;
    end if;
  else
    raise exception 'Approving changes on % is not supported yet', v_row.target_table;
  end if;

  update public.change_requests
     set status = 'approved',
         decided_by = auth.uid(),
         decided_at = now(),
         decision_note = left(coalesce(p_decision_note, ''), 500),
         updated_at = now()
   where id = p_request_id
   returning * into v_row;

  perform public.write_audit('change_request.approved', 'change_requests', p_request_id,
    jsonb_build_object(
      'target_table', v_row.target_table,
      'target_id', v_row.target_id,
      'action', v_row.action,
      'decided_by', v_name,
      'note', left(coalesce(p_decision_note, ''), 240)
    ));

  -- notify the requester
  if v_row.requester_id is not null then
    perform * from public.ug_notify_batch((select coalesce(jsonb_agg(to_jsonb(ug_rows)),'[]'::jsonb) from (values (v_row.requester_id,
            'Change request approved',
            'Your ' || v_row.action || ' request on ' || v_row.target_table ||
              ' was approved by ' || v_name || '.' ||
              case when coalesce(p_decision_note, '') <> '' then ' ' || left(p_decision_note, 140) else '' end,
            'prepared', 'check', 'change_request')) as ug_rows(user_id, title, body, tone, icon, type)),jsonb_build_object('change_request_id',v_row.id));
  end if;

  return v_row;
end;
$$;
revoke all on function public.approve_change_request(uuid,text) from public,anon,authenticated;
grant execute on function public.approve_change_request(uuid,text) to authenticated;

-- Latest body from 046_super_admin_verify_block_and_change_requests.sql; notification calls only except documented lifecycle changes.
create or replace function public.reject_change_request(
  p_request_id    uuid,
  p_decision_note text default ''
)
returns public.change_requests
language plpgsql
security definer set search_path = public
as $$
declare
  v_row  public.change_requests;
  v_name text;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in';
  end if;
  if not public.is_super_admin() then
    raise exception 'Only the Super Admin can reject a change request';
  end if;

  select * into v_row from public.change_requests where id = p_request_id;
  if v_row.id is null then
    raise exception 'That change request does not exist';
  end if;
  if v_row.status <> 'pending' then
    raise exception 'That change request has already been decided (%)', v_row.status;
  end if;

  select coalesce(full_name,'') into v_name from public.profiles where id = auth.uid();

  update public.change_requests
     set status = 'rejected',
         decided_by = auth.uid(),
         decided_at = now(),
         decision_note = left(coalesce(p_decision_note, ''), 500),
         updated_at = now()
   where id = p_request_id
   returning * into v_row;

  perform public.write_audit('change_request.rejected', 'change_requests', p_request_id,
    jsonb_build_object(
      'target_table', v_row.target_table,
      'target_id', v_row.target_id,
      'action', v_row.action,
      'decided_by', v_name,
      'note', left(coalesce(p_decision_note, ''), 240)
    ));

  if v_row.requester_id is not null then
    perform * from public.ug_notify_batch((select coalesce(jsonb_agg(to_jsonb(ug_rows)),'[]'::jsonb) from (values (v_row.requester_id,
            'Change request rejected',
            'Your ' || v_row.action || ' request on ' || v_row.target_table ||
              ' was rejected by ' || v_name || '.' ||
              case when coalesce(p_decision_note, '') <> '' then ' Reason: ' || left(p_decision_note, 140) else '' end,
            'warning', 'alert', 'change_request')) as ug_rows(user_id, title, body, tone, icon, type)),jsonb_build_object('change_request_id',v_row.id));
  end if;

  return v_row;
end;
$$;
revoke all on function public.reject_change_request(uuid,text) from public,anon,authenticated;
grant execute on function public.reject_change_request(uuid,text) to authenticated;

-- Latest body from 051_report_workflow_fixes.sql; notification calls only except documented lifecycle changes.
create or replace function public.decline_dispatch(
  p_dispatch_id uuid,
  p_reason      text
)
returns jsonb
language plpgsql
security definer set search_path = public
as $$
declare
  v_row      public.report_dispatches;
  v_role     text;
  v_name     text;
  v_unit     uuid;
  v_brgy     uuid;
  v_report   public.reports;
  v_reverted boolean := false;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'A reason is required to decline a dispatch';
  end if;
  select * into v_row from public.report_dispatches where id = p_dispatch_id for update;
  if v_row.id is null then
    raise exception 'That dispatch does not exist';
  end if;
  if v_row.dispatch_status not in ('sent','acknowledged') then
    raise exception 'A dispatch in "%" cannot be declined', v_row.dispatch_status;
  end if;

  select role, coalesce(full_name, ''), dispatch_unit_id, barangay_id
    into v_role, v_name, v_unit, v_brgy
    from public.profiles where id = auth.uid();

  if v_role is distinct from 'lgu_ldrrmc' then
    if v_row.unit_id is not null then
      if v_role is distinct from 'dispatch_team' or v_row.unit_id is distinct from v_unit then
        raise exception 'Only this unit''s users may decline this dispatch';
      end if;
    else
      if v_role is distinct from 'barangay_official' then
        raise exception 'Only the barangay official may decline this dispatch';
      end if;
      select * into v_report from public.reports where id = v_row.report_id;
      if v_report.barangay_id is distinct from v_brgy then
        raise exception 'This dispatch is outside your barangay';
      end if;
    end if;
  end if;

  update public.report_dispatches
     set dispatch_status = 'declined',
         decline_reason  = left(trim(p_reason), 500)
   where id = p_dispatch_id;

  insert into public.report_dispatch_events (dispatch_id, actor, actor_name, action, note)
  values (p_dispatch_id, auth.uid(), v_name, 'declined', left(trim(p_reason), 240));

  perform public.write_audit('dispatch.declined', 'report_dispatches', p_dispatch_id,
    jsonb_build_object('reason', left(trim(p_reason), 500), 'by', v_name));

  perform public.release_dispatch_equipment(array[p_dispatch_id]);

  -- lock the report, then: if no other dispatch is still active or done, the
  -- report has no team — return it to verified so it is dispatched again.
  select * into v_report from public.reports where id = v_row.report_id for update;
  if v_report.status = 'dispatched' and not exists (
       select 1 from public.report_dispatches d
        where d.report_id = v_report.id and d.dispatch_status <> 'declined'
     ) then
    perform set_config('uniguard.reason', 'all_declined', true);
    perform set_config('uniguard.note', left(coalesce(v_row.team, '') || ' declined: ' || trim(p_reason), 240), true);
    update public.reports set status = 'verified' where id = v_report.id;
    v_reverted := true;

    if v_report.reporter_id is not null then
      perform * from public.ug_notify_batch((select coalesce(jsonb_agg(to_jsonb(ug_rows)),'[]'::jsonb) from (values (v_report.reporter_id,
              'Responder reassignment',
              'The team assigned to ' || coalesce(v_report.code, 'your report') ||
                ' could not respond. A new team is being arranged.',
              'warning', 'truck', 'report_status', v_report.id)) as ug_rows(user_id, title, body, tone, icon, type, report_id)),'{}'::jsonb);
    end if;
  end if;

  -- notify the dispatcher and the LGU so they re-dispatch
  if v_row.dispatched_by is not null then
    perform * from public.ug_notify_batch((select coalesce(jsonb_agg(to_jsonb(ug_rows)),'[]'::jsonb) from (values (v_row.dispatched_by,
      'Dispatch declined: ' || coalesce(v_row.team, 'team'),
      left(coalesce(v_row.team, '') || ' declined: ' || trim(p_reason) ||
           ' — pick another team for ' || coalesce(v_report.code, ''), 240),
      'warning', 'alert', 'dispatch_declined', v_report.id)) as ug_rows(user_id, title, body, tone, icon, type, report_id)),'{}'::jsonb);
  end if;

  perform * from public.ug_notify_batch((select coalesce(jsonb_agg(to_jsonb(ug_rows)),'[]'::jsonb) from (select p.id, 'Dispatch declined: ' || coalesce(v_row.team, 'team'),
         left(coalesce(v_row.team, '') || ' declined ' || coalesce(v_report.code, '') ||
              ' — pick another team.', 240),
         'warning', 'alert', 'dispatch_declined', v_report.id
    from public.profiles p
   where p.disabled = false and p.role = 'lgu_ldrrmc'
     and p.id is distinct from v_row.dispatched_by) as ug_rows(user_id, title, body, tone, icon, type, report_id)),'{}'::jsonb);

  return jsonb_build_object('dispatch_id', p_dispatch_id, 'status', 'declined', 'at', now(),
                            'report_status', case when v_reverted then 'verified' else v_report.status end);
end;
$$;
revoke all on function public.decline_dispatch(uuid,text) from public,anon,authenticated;
grant execute on function public.decline_dispatch(uuid,text) to authenticated;

-- Latest body from 049_dispatch_team_features.sql; notification calls only except documented lifecycle changes.
create or replace function public.create_help_request(
  p_dispatch_id uuid,
  p_kind        text,
  p_message     text
)
returns jsonb
language plpgsql
security definer set search_path = public
as $$
declare
  v_row   public.report_dispatches;
  v_role  text;
  v_name  text;
  v_unit  uuid;
  v_brgy  uuid;
  v_id    uuid;
  v_report public.reports;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in';
  end if;
  if p_kind not in ('general','water_tanker','extra_personnel','beyond_capacity') then
    raise exception 'Unknown help request kind';
  end if;
  if coalesce(trim(p_message), '') = '' then
    raise exception 'Write a short message';
  end if;

  select * into v_row from public.report_dispatches where id = p_dispatch_id;
  if v_row.id is null then
    raise exception 'That dispatch does not exist';
  end if;
  if v_row.dispatch_status in ('done','declined') then
    raise exception 'This dispatch is closed';
  end if;

  select role, coalesce(full_name, ''), dispatch_unit_id, barangay_id
    into v_role, v_name, v_unit, v_brgy
    from public.profiles where id = auth.uid();

  -- scope: same block as dispatch_respond (LGU, unit's own users, report's
  -- barangay officials). The LGU never needs to send itself a help request
  -- but is allowed for symmetry.
  if v_role not in ('lgu_ldrrmc','dispatch_team','barangay_official') then
    raise exception 'Only responders, officials or the LGU may request help';
  end if;
  if v_role <> 'lgu_ldrrmc' then
    if v_row.unit_id is not null then
      if v_role <> 'dispatch_team' or v_row.unit_id is distinct from v_unit then
        raise exception 'You can only request help for your own unit''s dispatch';
      end if;
    else
      if v_role <> 'barangay_official' then
        raise exception 'Only the barangay official may request help for this dispatch';
      end if;
      select * into v_report from public.reports where id = v_row.report_id;
      if v_report.barangay_id is distinct from v_brgy then
        raise exception 'This dispatch is outside your barangay';
      end if;
    end if;
  end if;

  -- unit_id / barangay_id auto-fill: unit user sets unit_id; official sets
  -- barangay_id; LGU leaves both null (the dispatch row is the source of
  -- truth for which unit/barangay this concerns).
  insert into public.dispatch_help_requests
    (dispatch_id, unit_id, barangay_id, kind, message, status, created_by)
  values
    (p_dispatch_id,
     case when v_role = 'dispatch_team' then v_row.unit_id else null end,
     case when v_role = 'barangay_official' then v_brgy else null end,
     p_kind, left(trim(p_message), 1000), 'sent', auth.uid())
  returning id into v_id;

  -- notify every LGU user
  select * into v_report from public.reports where id = v_row.report_id;
  perform * from public.ug_notify_batch((select coalesce(jsonb_agg(to_jsonb(ug_rows)),'[]'::jsonb) from (select p.id,
    'Help request: ' || p_kind,
    left(coalesce(v_row.team, '') || ' · ' || coalesce(v_report.code, '') || ' — ' || trim(p_message), 240),
    'warning', 'inbox', 'dispatch_help', v_report.id
    from public.profiles p
   where p.disabled = false and p.role = 'lgu_ldrrmc') as ug_rows(user_id, title, body, tone, icon, type, report_id)),'{}'::jsonb);

  perform public.write_audit('dispatch.help_requested', 'dispatch_help_requests', v_id,
    jsonb_build_object('kind', p_kind, 'dispatch_id', p_dispatch_id, 'by', v_name));

  return jsonb_build_object('id', v_id, 'status', 'sent');
end;
$$;
revoke all on function public.create_help_request(uuid,text,text) from public,anon,authenticated;
grant execute on function public.create_help_request(uuid,text,text) to authenticated;

-- Latest body from 049_dispatch_team_features.sql; notification calls only except documented lifecycle changes.
create or replace function public.update_help_request(
  p_id     uuid,
  p_status text
)
returns jsonb
language plpgsql
security definer set search_path = public
as $$
declare
  v_row  public.dispatch_help_requests;
  v_name text;
  v_dispatch public.report_dispatches;
  v_report   public.reports;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in';
  end if;
  if p_status not in ('acknowledged','resolved') then
    raise exception 'Help request can only move to acknowledged or resolved';
  end if;
  if not public.is_lgu() then
    raise exception 'Only the LGU may update a help request';
  end if;
  select * into v_row from public.dispatch_help_requests where id = p_id;
  if v_row.id is null then
    raise exception 'That help request does not exist';
  end if;
  -- forward-only: sent -> acknowledged -> resolved
  if not (
    (v_row.status = 'sent'         and p_status = 'acknowledged')
    or (v_row.status = 'acknowledged' and p_status = 'resolved')
  ) then
    raise exception 'A help request in "%" cannot move to "%"', v_row.status, p_status;
  end if;

  select coalesce(full_name, '') into v_name from public.profiles where id = auth.uid();

  update public.dispatch_help_requests
     set status = p_status,
         acknowledged_by = case when p_status = 'acknowledged' then auth.uid() else acknowledged_by end,
         acknowledged_at = case when p_status = 'acknowledged' then now() else acknowledged_at end,
         resolved_by     = case when p_status = 'resolved'     then auth.uid() else resolved_by end,
         resolved_at     = case when p_status = 'resolved'     then now() else resolved_at end
   where id = p_id;

  -- notify the requester
  if v_row.created_by is not null then
    select * into v_dispatch from public.report_dispatches where id = v_row.dispatch_id;
    select * into v_report from public.reports where id = v_dispatch.report_id;
    perform * from public.ug_notify_batch((select coalesce(jsonb_agg(to_jsonb(ug_rows)),'[]'::jsonb) from (values (v_row.created_by,
      'Help request ' || p_status,
      left(coalesce(v_row.kind, '') || ' for ' || coalesce(v_report.code, '') || ' · ' || coalesce(v_row.message, ''), 240),
      case when p_status = 'resolved' then 'prepared' else 'advisory' end,
      'check', 'dispatch_help', v_report.id)) as ug_rows(user_id, title, body, tone, icon, type, report_id)),'{}'::jsonb);
  end if;

  perform public.write_audit('dispatch.help_updated', 'dispatch_help_requests', p_id,
    jsonb_build_object('status', p_status, 'by', v_name));

  return jsonb_build_object('id', p_id, 'status', p_status);
end;
$$;
revoke all on function public.update_help_request(uuid,text) from public,anon,authenticated;
grant execute on function public.update_help_request(uuid,text) to authenticated;

-- Latest body from 049_dispatch_team_features.sql; notification calls only except documented lifecycle changes.
create or replace function public.request_relief_escort(
  p_distribution_id uuid,
  p_note             text
)
returns jsonb
language plpgsql
security definer set search_path = public
as $$
declare
  v_row  public.relief_distributions;
  v_role text;
  v_brgy uuid;
  v_name text;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in';
  end if;
  select * into v_row from public.relief_distributions where id = p_distribution_id;
  if v_row.id is null then
    raise exception 'That distribution does not exist';
  end if;
  select role, coalesce(full_name, ''), barangay_id into v_role, v_name, v_brgy
    from public.profiles where id = auth.uid();
  if v_role not in ('lgu_ldrrmc','barangay_official') then
    raise exception 'Only the LGU or a barangay official may request an escort';
  end if;
  if v_role = 'barangay_official' and v_row.barangay_id is distinct from v_brgy then
    raise exception 'This distribution is outside your barangay';
  end if;
  if v_row.escort_status = 'confirmed' then
    raise exception 'This escort is already confirmed';
  end if;

  update public.relief_distributions
     set escort_status = 'requested',
         escort_note   = left(coalesce(p_note, ''), 1000)
   where id = p_distribution_id;

  -- notify every PNP unit member
  perform * from public.ug_notify_batch((select coalesce(jsonb_agg(to_jsonb(ug_rows)),'[]'::jsonb) from (select p.id,
    'Relief escort requested',
    left(coalesce(v_row.title, '') || ' · ' || coalesce(v_row.barangay, '') ||
         ' — ' || coalesce(p_note, ''), 240),
    'warning', 'shield', 'relief_escort'
    from public.profiles p
   where p.disabled = false and p.role = 'dispatch_team'
     and p.dispatch_unit_id in (
       select id from public.dispatch_units where unit_type = 'PNP' and active = true
     )) as ug_rows(user_id, title, body, tone, icon, type)),'{}'::jsonb);

  perform public.write_audit('relief.escort_requested', 'relief_distributions', p_distribution_id,
    jsonb_build_object('by', v_name, 'note', left(coalesce(p_note, ''), 500)));

  return jsonb_build_object('id', p_distribution_id, 'escort_status', 'requested');
end;
$$;
revoke all on function public.request_relief_escort(uuid,text) from public,anon,authenticated;
grant execute on function public.request_relief_escort(uuid,text) to authenticated;

-- Latest body from 052_reroute_and_advisory_seed.sql; notification calls only except documented lifecycle changes.
create or replace function public.reroute_misrouted_reports()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  b          record;
  v_id       uuid;
  v_row      public.reports;
  v_new_id   uuid;
  v_new_name text;
  v_moved    int := 0;
  v_skipped  int := 0;
  v_errors   jsonb := '[]'::jsonb;
  v_held     int := 0;
begin
  if auth.uid() is not null then
    raise exception 'Re-routing runs from the backend only';
  end if;

  select * into b from public.lingayen_bounds();

  for v_id in
    select r.id
      from public.reports r
     where r.status = 'reported'
       and r.lat between b.min_lat and b.max_lat
       and r.lng between b.min_lng and b.max_lng
     order by r.created_at
  loop
    begin
      -- lock; skip a row someone is updating right now
      select * into v_row from public.reports where id = v_id for update skip locked;
      if not found then
        v_skipped := v_skipped + 1;
        continue;
      end if;
      -- re-check under the lock: it may have been verified meanwhile
      if v_row.status <> 'reported' then
        continue;
      end if;

      v_new_id := public.resolve_barangay(v_row.lat, v_row.lng);
      if v_new_id is null or v_new_id is not distinct from v_row.barangay_id then
        continue;
      end if;
      select name into v_new_name from public.barangays where id = v_new_id;

      perform set_config('uniguard.reason', 'reroute', true);
      update public.reports
         set barangay_id = v_new_id,
             barangay    = coalesce(v_new_name, barangay)
       where id = v_row.id;

      perform public.write_audit('report.rerouted', 'reports', v_row.id,
        jsonb_build_object('from_barangay_id', v_row.barangay_id, 'from_barangay', v_row.barangay,
                           'to_barangay_id', v_new_id, 'to_barangay', v_new_name,
                           'reason', 'barangay routing fix (migration 051/052)'));

      -- new barangay's officials: the report is now in their queue
      perform * from public.ug_notify_batch((select coalesce(jsonb_agg(to_jsonb(ug_rows)),'[]'::jsonb) from (select p.id, 'Report moved to your barangay',
             'Report ' || coalesce(v_row.code, '') || ' (' || coalesce(v_row.hazard_type, '') ||
               ') is located in ' || coalesce(v_new_name, 'your barangay') ||
               ' and is now in your verification queue.',
             'advisory', 'check', 'report_status', v_row.id
        from public.profiles p
       where p.disabled = false and p.role = 'barangay_official' and p.barangay_id = v_new_id) as ug_rows(user_id, title, body, tone, icon, type, report_id)),'{}'::jsonb);

      -- old barangay's officials: it left their queue
      if v_row.barangay_id is not null then
        perform * from public.ug_notify_batch((select coalesce(jsonb_agg(to_jsonb(ug_rows)),'[]'::jsonb) from (select p.id, 'Report moved to another barangay',
               'Report ' || coalesce(v_row.code, '') || ' is located in ' || coalesce(v_new_name, 'another barangay') ||
                 ' and was moved to that barangay''s queue.',
               'advisory', 'check', 'report_status', v_row.id
          from public.profiles p
         where p.disabled = false and p.role = 'barangay_official' and p.barangay_id = v_row.barangay_id) as ug_rows(user_id, title, body, tone, icon, type, report_id)),'{}'::jsonb);
      end if;

      v_moved := v_moved + 1;
    exception when others then
      v_skipped := v_skipped + 1;
      v_errors := v_errors || jsonb_build_array(jsonb_build_object('id', v_id, 'error', sqlerrm));
    end;
  end loop;

  -- reports already acted on whose location points elsewhere: left as-is
  -- (materialized: the bounds filter runs before resolve_barangay, which
  --  raises on invalid coordinates)
  with acted as materialized (
    select r.barangay_id, r.lat, r.lng
      from public.reports r
     where r.status in ('verified', 'dispatched')
       and r.lat between b.min_lat and b.max_lat
       and r.lng between b.min_lng and b.max_lng
  )
  select count(*) into v_held
    from acted a
   where a.barangay_id is distinct from public.resolve_barangay(a.lat, a.lng);

  return jsonb_build_object('moved', v_moved, 'skipped', v_skipped,
                            'held_for_review', v_held, 'errors', v_errors);
end;
$$;
revoke all on function public.reroute_misrouted_reports() from public,anon,authenticated;
grant execute on function public.reroute_misrouted_reports() to authenticated;

-- Latest body from 057_auto_dispatch_tracking_ratings_sos.sql; notification calls only except documented lifecycle changes.
create or replace function public.ug_auto_dispatch(p_report_id uuid, p_teams text[], p_source text)
returns int
language plpgsql
security definer set search_path = public
as $$
declare
  v_row      public.reports;
  v_team     text;
  v_type     text;
  v_unit_id  uuid;
  v_dist     double precision;
  v_eta      timestamptz;
  v_disp     uuid;
  v_instr    text;
  v_by_name  text;
  v_by       uuid;
  v_n        int := 0;
  v_first    boolean := true;
  v_missing  text[] := array[]::text[];
begin
  select * into v_row from public.reports where id = p_report_id for update;
  if v_row.id is null or v_row.status <> 'verified' then
    return 0;
  end if;

  v_by      := case when p_source = 'sos' then null else auth.uid() end;
  v_by_name := case p_source when 'sos' then 'Auto-dispatch (SOS)'
                             when 'manual' then 'Auto-dispatch (' || coalesce((select full_name from public.profiles where id = auth.uid()), '') || ')'
                             else 'Auto-dispatch on verification' end;
  v_instr   := left(
    'Respond to ' || coalesce(nullif(v_row.hazard_other_text, ''), v_row.hazard_type, 'the reported hazard') ||
    ' (' || coalesce(v_row.severity, 'advisory') || ') in ' || coalesce(v_row.barangay, 'the barangay') || '. ' ||
    coalesce(v_row.description, ''), 480);

  if p_teams is null or cardinality(p_teams) = 0 then
    perform * from public.ug_notify_batch((select coalesce(jsonb_agg(to_jsonb(ug_rows)),'[]'::jsonb) from (select p.id, 'Dispatch needed: ' || coalesce(v_row.code, ''),
           'No automatic team for ' || coalesce(v_row.hazard_type, 'this hazard') || '. Choose a team and dispatch it.',
           'warning', 'truck', 'dispatch', v_row.id
      from public.profiles p where p.disabled = false and p.role = 'lgu_ldrrmc') as ug_rows(user_id, title, body, tone, icon, type, report_id)),jsonb_build_object('type','dispatch_needed','priority','urgent','requires_ack',true));
    return 0;
  end if;

  foreach v_team in array p_teams loop
    -- a team already on this report is not sent twice
    if exists (select 1 from public.report_dispatches d
                where d.report_id = p_report_id and d.team = v_team
                  and d.dispatch_status not in ('done', 'declined')) then
      continue;
    end if;

    if v_team = 'Barangay Response Team' then
      if v_row.barangay_id is null then
        continue;
      end if;
      v_unit_id := null;
      v_eta     := now() + interval '15 minutes';
    else
      v_type := case v_team when 'BFP' then 'BFP' when 'PNP' then 'PNP'
                            when 'Rescue Unit' then 'Rescue' when 'Ambulance' then 'Hospital' end;
      v_unit_id := null;
      select u.id,
             case when u.lat is null or u.lng is null or v_row.lat is null or v_row.lng is null then null
                  else public.distance_m(u.lat, u.lng, v_row.lat, v_row.lng) end as dist
        into v_unit_id, v_dist
        from public.dispatch_units u
       where u.active = true and u.unit_type = v_type and u.status <> 'off_duty'
       order by (u.status = 'available') desc, dist asc nulls last, u.created_at
       limit 1;
      if v_unit_id is null then
        v_missing := v_missing || v_team;
        continue;
      end if;
      -- 30 km/h through town, never under 5 minutes; 15 min when unknown
      v_eta := now() + make_interval(mins => case when v_dist is null then 15
                                                 else greatest(5, ceil(v_dist / 500.0)::int) end);
    end if;

    insert into public.report_dispatches
      (report_id, team, instructions, eta, dispatched_by, dispatched_by_name,
       unit_id, target_barangay_id, dispatch_status, auto_dispatched)
    values
      (p_report_id, v_team, v_instr, v_eta, v_by, v_by_name,
       v_unit_id, v_row.barangay_id, 'sent', true)
    returning id into v_disp;

    insert into public.report_dispatch_events (dispatch_id, actor, actor_name, action, note)
    values (v_disp, v_by, v_by_name, 'dispatched', left(v_instr, 240));

    perform public.write_audit('report.auto_dispatched', 'reports', p_report_id,
      jsonb_build_object('dispatch_id', v_disp, 'team', v_team, 'unit_id', v_unit_id,
                         'source', p_source, 'eta', v_eta));

    -- the reporter hears it once, from the first team
    perform public.fanout_dispatch(p_report_id, v_disp, v_team, v_row.barangay_id, v_unit_id,
                                   v_instr, not v_first);
    v_first := false;
    v_n := v_n + 1;
  end loop;

  if v_n > 0 then
    perform set_config('uniguard.reason', 'auto_dispatch', true);
    perform set_config('uniguard.note', 'Auto-dispatched ' || v_n || ' team(s)', true);
    update public.reports set status = 'dispatched' where id = p_report_id;
  end if;

  if cardinality(v_missing) > 0 then
    perform * from public.ug_notify_batch((select coalesce(jsonb_agg(to_jsonb(ug_rows)),'[]'::jsonb) from (select p.id, 'No unit available: ' || coalesce(v_row.code, ''),
           'No available unit for ' || array_to_string(v_missing, ', ') || ' could be sent to ' ||
             coalesce(v_row.barangay, 'the barangay') || '. Dispatch it by hand.',
           'warning', 'truck', 'dispatch', v_row.id
      from public.profiles p where p.disabled = false and p.role = 'lgu_ldrrmc') as ug_rows(user_id, title, body, tone, icon, type, report_id)),jsonb_build_object('type','dispatch_needed','priority','urgent','requires_ack',true));
  end if;

  return v_n;
end;
$$;
revoke all on function public.ug_auto_dispatch(uuid,text[],text) from public,anon,authenticated;

-- Latest body from 057_auto_dispatch_tracking_ratings_sos.sql; notification calls only except documented lifecycle changes.
create or replace function public.ug_auto_dispatch_on_verify()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.verified_by_role in ('barangay_official', 'lgu_ldrrmc') then
    begin
      perform public.ug_auto_dispatch(new.id, public.auto_dispatch_teams(new.hazard_type, new.severity), 'verify');
    exception when others then
      perform * from public.ug_notify_batch((select coalesce(jsonb_agg(to_jsonb(ug_rows)),'[]'::jsonb) from (select p.id, 'Auto-dispatch failed: ' || coalesce(new.code, ''),
             left('Dispatch this report by hand. Reason: ' || sqlerrm, 240),
             'warning', 'truck', 'dispatch', new.id
        from public.profiles p where p.disabled = false and p.role = 'lgu_ldrrmc') as ug_rows(user_id, title, body, tone, icon, type, report_id)),jsonb_build_object('type','dispatch_needed','priority','urgent','requires_ack',true));
    end;
  end if;
  return null;
end;
$$;
revoke all on function public.ug_auto_dispatch_on_verify() from public,anon,authenticated;

notify pgrst,'reload schema';
commit;
