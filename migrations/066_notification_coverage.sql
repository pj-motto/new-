begin;
alter table public.relief_distributions add column if not exists phase text not null default 'scheduled';
do $$ begin
 if not exists(select 1 from pg_constraint where conrelid='public.relief_distributions'::regclass and conname='relief_phase_check') then
  alter table public.relief_distributions add constraint relief_phase_check check(phase in ('scheduled','ongoing','completed','cancelled'));
 end if;
end $$;
create or replace function public.ug_recipients_area(p_barangay_id uuid) returns uuid[] language sql stable security definer set search_path=public as $$
 select coalesce(array_agg(id),'{}'::uuid[]) from public.profiles where not disabled and (role='lgu_ldrrmc' or (barangay_id=p_barangay_id and role in ('citizen','barangay_official')));
$$;
revoke all on function public.ug_recipients_area(uuid) from public,anon,authenticated;
create or replace function public.ug_notify_coverage() returns trigger language plpgsql security definer set search_path=public as $$
declare recipients uuid[]; v_report public.reports; v_actor text; v_body text; v_title text; v_dispatch record; v_id uuid; v_n int;
begin
 if tg_table_name='reports' then
  if tg_op='INSERT' then
   if current_setting('uniguard.sos_submission',true)='1' then return null; end if;
   recipients:=public.ug_recipients_lgu()||public.ug_recipients_barangay(new.barangay_id)||public.ug_recipients_super_admin();
   perform public.ug_notify(recipients,'new_report','New report: '||coalesce(new.code,''),new.hazard_type||' · '||new.barangay,
    new.severity,case when new.severity='emergency' then 'urgent' else 'normal' end,new.severity='emergency','report:'||new.id,new.id,null,null,null,'alert','incident',new.id::text);
  elsif row(new.description,new.lat,new.lng,new.barangay_id,new.hazard_type,new.severity) is distinct from row(old.description,old.lat,old.lng,old.barangay_id,old.hazard_type,old.severity) then
   for v_dispatch in select * from public.report_dispatches where report_id=new.id and dispatch_status not in ('done','declined') loop
    perform public.ug_notify(public.ug_recipients_unit(v_dispatch.unit_id)||public.ug_recipients_barangay(v_dispatch.target_barangay_id),
     'report_updated','Active incident details changed: '||coalesce(new.code,''),new.hazard_type||' · '||new.barangay,'warning','urgent',false,null,new.id,null,v_dispatch.id,null,'alert','incident',new.id::text);
   end loop;
  end if;
 elsif tg_table_name='change_requests' then
  if tg_op='INSERT' then
   perform public.ug_notify(public.ug_recipients_super_admin(),'change_request','Change request awaiting approval',new.requester_name||' · '||new.action||' · '||new.target_table,
    'warning','urgent',true,'change:'||new.id,null,null,null,new.id,'inbox','hotlines',new.id::text);
  end if;
 elsif tg_table_name='relief_distributions' then
  if tg_op='UPDATE' and row(new.phase,new.active,new.distribution_at) is distinct from row(old.phase,old.active,old.distribution_at) then
   perform public.ug_notify(public.ug_recipients_area(new.barangay_id),'relief','Relief update: '||new.title,new.barangay||' · '||new.phase,'advisory','normal',false,null,null,null,null,null,'relief','relief',new.id::text);
   update public.notifications set relief_id=new.id where type='relief' and target_id=new.id::text and created_at=now();
  end if;
 elsif tg_table_name='evacuation_centers' then
  if tg_op='UPDATE' and new.status is distinct from old.status and new.status in ('full','closed') then
   perform public.ug_notify(public.ug_recipients_area(new.barangay_id),'shelter','Shelter '||new.status||': '||new.name,new.barangay||' · '||coalesce(new.note,''),'warning','normal',false,null,null,null,null,null,'shelter','centers',new.id::text);
  end if;
 elsif tg_table_name='road_status' then
  if tg_op='INSERT' or new.status is distinct from old.status then
   perform public.ug_notify(public.ug_recipients_area(new.barangay_id),'road_status','Road '||new.status||': '||new.road_name,new.barangay||' · '||coalesce(new.note,''),'warning','normal',false,null,null,null,null,null,'road','roadwork',new.id::text);
  end if;
 elsif tg_table_name='dispatch_equipment' then
  if tg_op='UPDATE' and (new.status in ('unavailable','maintenance') or new.condition in ('out_of_service','missing','needs_repair'))
    and row(new.status,new.condition) is distinct from row(old.status,old.condition) then
   perform public.ug_notify(public.ug_recipients_lgu()||public.ug_recipients_super_admin()||public.ug_recipients_unit(new.owner_unit_id)||public.ug_recipients_barangay(new.owner_barangay_id),
    'equipment','Equipment needs attention',coalesce(nullif(new.custom_label,''),new.identifier,'Equipment')||' · '||new.status||' · '||new.condition,'warning','normal',false,null,null,null,null,null,'shield','dispatch-units',new.owner_unit_id::text);
  end if;
 elsif tg_table_name='relief_inventory' then
  if tg_op='UPDATE' and new.stock<=new.reorder and (old.stock>old.reorder or (new.stock=0 and old.stock>0)) then
   perform public.ug_notify(public.ug_recipients_lgu()||public.ug_recipients_super_admin(),'inventory_low','Low stock: '||new.name,new.stock||' '||new.unit||' remaining','warning','normal',false,null,null,null,null,null,'relief','relief',new.id::text);
  end if;
 elsif tg_table_name='report_dispatches' then
  if tg_op='UPDATE' and row(new.unit_id,new.target_barangay_id,new.instructions) is distinct from row(old.unit_id,old.target_barangay_id,old.instructions) then
   perform public.ug_notify(public.ug_recipients_unit(old.unit_id)||public.ug_recipients_barangay(old.target_barangay_id),'dispatch_changed','Dispatch assignment changed',coalesce(new.team,'')||' · '||coalesce(new.instructions,''),'warning','urgent',false,null,new.report_id,null,new.id,null,'truck','incident',new.report_id::text);
   if new.unit_id is distinct from old.unit_id then
    perform public.ug_notify(public.ug_recipients_unit(new.unit_id),'dispatch','Incoming reassigned dispatch',new.team||' · '||coalesce(new.instructions,''),'emergency','critical',true,'dispatch-reassign:'||new.id||':'||coalesce(new.unit_id::text,''),new.report_id,null,new.id,null,'truck','dispatch',new.id::text);
   end if;
  elsif tg_op='UPDATE' and new.dispatch_status='declined' and old.dispatch_status<>'declined' then
   perform public.ug_notify(public.ug_recipients_unit(new.unit_id),'dispatch_cancelled','Dispatch closed / declined',new.team||' · '||coalesce(new.decline_reason,''),'warning','normal',false,null,new.report_id,null,new.id,null,'truck','dispatch',new.id::text);
  end if;
 elsif tg_table_name='profiles' then
  if tg_op='INSERT' then
   perform public.ug_notify(array[new.id]||public.ug_recipients_super_admin(),'account','Account created',coalesce(new.full_name,'')||' · '||new.role,'advisory','info',false,'account:'||new.id,null,null,null,null,'users','notifications',new.id::text);
  elsif row(new.role,new.disabled,new.dispatch_unit_id,new.is_super_admin) is distinct from row(old.role,old.disabled,old.dispatch_unit_id,old.is_super_admin) then
   perform public.ug_notify(array[new.id]||public.ug_recipients_super_admin(),'account','Account access updated',coalesce(new.full_name,'')||' · '||new.role||case when new.disabled then ' · disabled' else '' end,'advisory','info',false,null,null,null,null,null,'users','notifications',new.id::text);
  end if;
 end if;
 return null;
end $$;
revoke all on function public.ug_notify_coverage() from public,anon,authenticated;
do $$ declare t text; begin
 foreach t in array array['reports','change_requests','relief_distributions','evacuation_centers','road_status','dispatch_equipment','relief_inventory','report_dispatches','profiles'] loop
  execute format('drop trigger if exists ug_notify_coverage on public.%I',t);
  execute format('create trigger ug_notify_coverage after insert or update on public.%I for each row execute function public.ug_notify_coverage()',t);
 end loop;
end $$;
-- Changing a unit resets human acceptance and closes the former unit's copy.
create or replace function public.ug_dispatch_reassigned() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if new.unit_id is distinct from old.unit_id then
  new.alarm_acked_at:=null;new.alarm_acked_by:=null;
  update public.notifications set acked_at=now(),acked_by=auth.uid() where dispatch_id=old.id and requires_ack and acked_at is null;
 end if;
 return new;
end $$;
revoke all on function public.ug_dispatch_reassigned() from public,anon,authenticated;
drop trigger if exists ug_dispatch_reassigned on public.report_dispatches;
create trigger ug_dispatch_reassigned before update on public.report_dispatches for each row execute function public.ug_dispatch_reassigned();
notify pgrst,'reload schema';
commit;
