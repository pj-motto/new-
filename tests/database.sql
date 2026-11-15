-- Disposable database only. Tests roll back every fixture.
\set ON_ERROR_STOP on
begin;
create function pg_temp.assert(ok boolean,label text) returns void language plpgsql as $$begin if ok is distinct from true then raise exception 'FAIL: %',label; end if; raise notice 'PASS: %',label;end $$;
insert into auth.users(id,email,raw_user_meta_data)
select ('10000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid,'test'||i||'@example.invalid',jsonb_build_object('full_name','Test '||i,'barangay','Poblacion') from generate_series(1,7)i;
insert into public.dispatch_units(id,name,unit_type,status,active) values('20000000-0000-0000-0000-000000000001','Test BFP','BFP','available',true);
update public.profiles set role=case right(id::text,1) when '1' then 'citizen' when '2' then 'lgu_ldrrmc' when '3' then 'barangay_official' when '4' then 'barangay_official' when '5' then 'dispatch_team' when '6' then 'lgu_ldrrmc' else 'lgu_ldrrmc' end,
 is_super_admin=right(id::text,1)='6',disabled=right(id::text,1)='7',
 barangay_id=(select id from public.barangays where name=case when right(profiles.id::text,1)='4' then 'Aliwekwek' else 'Poblacion' end),
 dispatch_unit_id=case when right(id::text,1)='5' then '20000000-0000-0000-0000-000000000001'::uuid else null end,
 unit_role=case when right(id::text,1)='5' then 'member' else '' end where id::text like '10000000-%';
select pg_temp.assert('10000000-0000-0000-0000-000000000002'::uuid=any(public.ug_recipients_lgu()),'T1 duty LGU recipients');
select pg_temp.assert(not ('10000000-0000-0000-0000-000000000006'::uuid=any(public.ug_recipients_lgu())),'T2 Super Admin separate');
select pg_temp.assert(not ('10000000-0000-0000-0000-000000000007'::uuid=any(public.ug_recipients_lgu())),'T3 disabled recipients skipped');
select public.ug_notify(array['10000000-0000-0000-0000-000000000002'::uuid,'10000000-0000-0000-0000-000000000002'::uuid,null],'test','Test',repeat('x',300),'advisory','normal',true,'dedupe-test');
select public.ug_notify(public.ug_recipients_lgu(),'test','Test',repeat('x',300),'advisory','normal',true,'dedupe-test');
select pg_temp.assert((select count(*)=1 and max(length(body))=240 from notifications where dedupe_key='dedupe-test' and user_id='10000000-0000-0000-0000-000000000002'),'T4 dedupe and truncation');
set local role authenticated;
select set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000001',true);
select public.submit_sos(null,null,20,'Test emergency','fire') as sos_result \gset
reset role;
select :'sos_result'::jsonb->>'id' as sos_id \gset
select pg_temp.assert((select priority='critical' and requires_ack from notifications where sos_id=:'sos_id' and user_id='10000000-0000-0000-0000-000000000002'),'T5 SOS duty critical');
select pg_temp.assert((select priority='urgent' and requires_ack from notifications where sos_id=:'sos_id' and user_id='10000000-0000-0000-0000-000000000006'),'T6 Super Admin silent urgent backstop');
select pg_temp.assert(exists(select 1 from notifications where sos_id=:'sos_id' and user_id='10000000-0000-0000-0000-000000000003') and not exists(select 1 from notifications where sos_id=:'sos_id' and user_id='10000000-0000-0000-0000-000000000004'),'T7 SOS barangay scope');
set local role authenticated;
select set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000002',true);
update notifications set read_at=now() where sos_id=:'sos_id';
select pg_temp.assert(exists(select 1 from notifications where sos_id=:'sos_id' and requires_ack and acked_at is null),'T8 read-all preserves pending');
do $$begin
 begin update public.notifications set priority='info';raise exception 'Guard did not reject';exception when insufficient_privilege then null;end;
 begin perform public.set_alert_settings('{"sos_ack_timeout_s":20}');raise exception 'LGU settings write was allowed';exception when insufficient_privilege then null;end;
end $$;
reset role;
select set_config('request.jwt.claim.sub','',true);
update sos_log set created_at=now()-interval '2 minutes' where id=:'sos_id';
select ug_check_sos_escalation();select ug_check_sos_escalation();
select pg_temp.assert((select count(*)=1 from notifications where type='sos_escalation' and sos_id=:'sos_id' and user_id='10000000-0000-0000-0000-000000000006'),'T9 escalation once');
set local role authenticated;
select set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000002',true);
select public.update_sos_status(:'sos_id','acknowledged');
reset role;
select pg_temp.assert(not exists(select 1 from notifications where sos_id=:'sos_id' and type in ('sos','sos_escalation') and requires_ack and acked_at is null),'T10 SOS handled auto-acks every copy');
select pg_temp.assert((select acked_by='10000000-0000-0000-0000-000000000002' and acked_by_name='Test 2' and acked_at is not null from sos_log where id=:'sos_id'),'T11 named SOS timeline');
select set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000001',true);
insert into reports(hazard_type,barangay,severity,lat,lng,description) values('Fire','Poblacion','emergency',16.014,120.229,'Dispatch test') returning id as report_id \gset
select set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000002',true);
select public.advance_report_status(:'report_id','verified','Test');
select id as dispatch_id from report_dispatches where report_id=:'report_id' and unit_id='20000000-0000-0000-0000-000000000001' \gset
select pg_temp.assert(exists(select 1 from notifications where dispatch_id=:'dispatch_id' and type='dispatch' and requires_ack and priority='critical'),'T12 unit critical notification linked');
set local role authenticated;
select set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000005',true);
select public.update_dispatch_location(:'dispatch_id',16.02,120.23,10);
select pg_temp.assert((select dispatch_status='acknowledged' and alarm_acked_at is null from report_dispatches where id=:'dispatch_id'),'T13 GPS status does not acknowledge alarm');
select public.dispatch_ack_alarm(:'dispatch_id');
select public.dispatch_ack_alarm(:'dispatch_id');
reset role;
select pg_temp.assert((select alarm_acked_by='10000000-0000-0000-0000-000000000005' and alarm_acked_at is not null from report_dispatches where id=:'dispatch_id'),'T14 human unit ack timestamp');
select pg_temp.assert(not exists(select 1 from notifications where dispatch_id=:'dispatch_id' and requires_ack and acked_at is null),'T15 unit alarm auto-ack all devices');
set local role authenticated;
select set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000005',true);
select public.update_dispatch_location(:'dispatch_id',16.019,120.23,10);
reset role;
select pg_temp.assert(exists(select 1 from notifications where report_id=:'report_id' and type='dispatch_status' and title='Responder en route' and user_id='10000000-0000-0000-0000-000000000001'),'T16 citizen en-route notification');
set local role authenticated;
select set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000006',true);
select public.set_alert_settings('{"sos_ack_timeout_s":30,"super_admin_sos_alarm":"every"}');
do $$begin
 begin perform public.set_alert_settings('{"sos_ack_timeout_s":1}');raise exception 'Invalid settings accepted';exception when check_violation then null;end;
end $$;
reset role;
select pg_temp.assert((select sos_ack_timeout_s=30 and super_admin_sos_alarm='every' from ug_alert_settings),'T17 settings validation and Super Admin access');
select set_config('request.jwt.claim.sub','',true);
insert into notifications(user_id,title,body,requires_ack,created_at,read_at) values('10000000-0000-0000-0000-000000000002','Keep pending','',true,now()-interval '91 days',now()),('10000000-0000-0000-0000-000000000002','Delete old','',false,now()-interval '91 days',now());
select ug_cleanup_notifications();
select pg_temp.assert(exists(select 1 from notifications where title='Keep pending') and not exists(select 1 from notifications where title='Delete old'),'T18 retention preserves old pending');
-- Notification coverage and live tracking follow the same disposable fixtures.
select pg_temp.assert(exists(select 1 from notifications where type='new_report' and report_id=:'report_id' and user_id='10000000-0000-0000-0000-000000000002'),'T19 new reports notify duty LGU');
set local role authenticated;
select set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000003',true);
select (public.submit_change_request('emergency_hotlines','add',null,'{}','{"agency_name":"Test hotline","contact_number":"09123456789"}','Test request')).id as change_id \gset
reset role;
select pg_temp.assert(exists(select 1 from notifications where change_request_id=:'change_id' and requires_ack and priority='urgent' and user_id='10000000-0000-0000-0000-000000000006'),'T20 approval request notifies Super Admin');
set local role authenticated;
select set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000006',true);
select public.reject_change_request(:'change_id','Test rejected');
reset role;
select pg_temp.assert(not exists(select 1 from notifications where change_request_id=:'change_id' and requires_ack and acked_at is null),'T21 handled approval auto-acks pending');
select set_config('request.jwt.claim.sub','',true);
insert into evacuation_centers(name,barangay_id,barangay,status) values('Test shelter',(select id from barangays where name='Poblacion'),'Poblacion','open') returning id as center_id \gset
update evacuation_centers set status='full' where id=:'center_id';
select pg_temp.assert(exists(select 1 from notifications where type='shelter' and target_id=:'center_id' and user_id='10000000-0000-0000-0000-000000000001'),'T22 full shelter notifies scoped residents');
insert into road_status(road_name,barangay_id,barangay,status) values('Test road',(select id from barangays where name='Poblacion'),'Poblacion','passable') returning id as road_id \gset
update road_status set status='blocked' where id=:'road_id';
select pg_temp.assert(exists(select 1 from notifications where type='road_status' and target_id=:'road_id' and title like 'Road blocked%'),'T23 road status notification');
insert into relief_inventory(id,name,category,stock,reorder,unit) values('test-rice','Test rice','Food',10,5,'packs') returning id as inventory_id \gset
update relief_inventory set stock=4 where id=:'inventory_id';
select pg_temp.assert(exists(select 1 from notifications where type='inventory_low' and target_id=:'inventory_id'),'T24 low stock notification');
insert into relief_distributions(title,barangay,barangay_id) values('Test relief','Poblacion',(select id from barangays where name='Poblacion')) returning id as relief_id \gset
update relief_distributions set phase='ongoing' where id=:'relief_id';
select pg_temp.assert(exists(select 1 from notifications where type='relief' and relief_id=:'relief_id'),'T25 relief phase notification');
select pg_temp.assert(exists(select 1 from dispatch_locations where dispatch_id=:'dispatch_id'),'T26 GPS history recorded');
update report_dispatches set last_loc_at=now()-interval '4 minutes' where id=:'dispatch_id';
select ug_check_tracking();select ug_check_tracking();
select pg_temp.assert((select count(*)=1 from notifications where type='lost_signal' and dispatch_id=:'dispatch_id' and user_id='10000000-0000-0000-0000-000000000002'),'T27 lost signal once per outage');
set local role authenticated;
select set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000005',true);
select public.update_dispatch_location(:'dispatch_id',16.019,120.23,10);
reset role;
select pg_temp.assert(not exists(select 1 from notifications where type='lost_signal' and dispatch_id=:'dispatch_id' and requires_ack and acked_at is null),'T28 signal recovery acknowledges all copies');
select pg_temp.assert((select signal_lost_at is null and signal_restored_at is not null and alarm_acked_at is not null from report_dispatches where id=:'dispatch_id'),'T29 GPS recovery preserves human acknowledgement');
set local role authenticated;
select set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000004',true);
select pg_temp.assert(not exists(select 1 from dispatch_locations where dispatch_id=:'dispatch_id'),'T30 other barangay cannot read location trail');
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000001',true);
select pg_temp.assert(exists(select 1 from dispatch_locations where dispatch_id=:'dispatch_id'),'T31 reporter may read own response trail');
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000005',true);
select public.update_dispatch_location(:'dispatch_id',16.014,120.229,300);
select pg_temp.assert((select dispatch_status='en_route' from report_dispatches where id=:'dispatch_id'),'T32 poor accuracy cannot confirm arrival');
select public.update_dispatch_location(:'dispatch_id',16.014,120.229,10);
select pg_temp.assert((select dispatch_status='on_scene' from report_dispatches where id=:'dispatch_id'),'T33 accurate fix within arrival radius advances status');
reset role;
select pg_temp.assert(not has_function_privilege('authenticated','public.ug_notify(uuid[],text,text,text,text,text,boolean,text,uuid,uuid,uuid,uuid,text,text,text)','execute'),'T34 notification fanout not client executable');
select pg_temp.assert(not has_table_privilege('authenticated','public.ug_private_config','select') and not has_table_privilege('authenticated','public.ug_alert_settings','update'),'T35 private config and protected settings grants');
-- Existing client-facing fan-out RPCs retain their signatures and permissions.
set local role authenticated;
select set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000002',true);
insert into advisories(author_id,title,body,severity,citywide) values(auth.uid(),'Test advisory','Advisory body','warning',true) returning id as advisory_id \gset
select public.fanout_advisory(:'advisory_id');select public.fanout_advisory(:'advisory_id');
reset role;
select pg_temp.assert((select count(*)=1 from notifications where advisory_id=:'advisory_id' and user_id='10000000-0000-0000-0000-000000000001'),'T36 advisory fan-out executable and deduplicated');
set local role authenticated;
select set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000002',true);
insert into road_work_posts(author_id,title,barangay,citywide) values(auth.uid(),'Test works','Poblacion',true) returning id as road_work_id \gset
select public.fanout_road_work(:'road_work_id');
reset role;
select pg_temp.assert(exists(select 1 from notifications where road_work_id=:'road_work_id' and user_id='10000000-0000-0000-0000-000000000001'),'T37 road-work fan-out still executable');
set local role authenticated;
select set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000001',true);
do $$declare v uuid;begin select id into v from public.advisories where title='Test advisory';begin perform public.fanout_advisory(v);raise exception 'Citizen broadcast allowed';exception when insufficient_privilege then null;end;end $$;
reset role;
select pg_temp.assert(true,'T38 citizen cannot invoke broadcast fan-out');
-- Resolution closes linked alarms, including the independent unit alarm.
select set_config('request.jwt.claim.sub','',true);
update sos_log set report_id=:'report_id' where id=:'sos_id';
update report_dispatches set alarm_acked_at=null,alarm_acked_by=null where id=:'dispatch_id';
set local role authenticated;
select set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000002',true);
select public.update_sos_status(:'sos_id','resolved');
reset role;
select pg_temp.assert((select alarm_acked_at is not null from report_dispatches where id=:'dispatch_id'),'T39 SOS resolution closes linked unit alarm');
select set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000001',true);
insert into reports(hazard_type,barangay,severity,lat,lng,description) values('Flood','Poblacion','warning',16.014,120.229,'Overdue test') returning id as overdue_id \gset
select set_config('request.jwt.claim.sub','',true);
update reports set created_at=now()-interval '61 minutes' where id=:'overdue_id';
select ug_check_one_hour_escalation();select ug_check_one_hour_escalation();
select pg_temp.assert((select count(*)=1 from notifications where type='escalation_1h' and report_id=:'overdue_id' and user_id='10000000-0000-0000-0000-000000000002'),'T40 one-hour escalation once per report');
select set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000001',true);
select public.submit_sos(null,null,20,'No arrival test','medical') as noarrival_result \gset
reset role;
select :'noarrival_result'::jsonb->>'id' as noarrival_id \gset
select set_config('request.jwt.claim.sub','',true);
update sos_log set status='acknowledged',created_at=now()-interval '11 minutes',report_id=:'overdue_id' where id=:'noarrival_id';
select ug_check_sos_escalation();
select pg_temp.assert(exists(select 1 from notifications where type='sos_no_arrival' and sos_id=:'noarrival_id' and requires_ack),'T41 acknowledged SOS without arrival escalates');
rollback;
