-- Transport simulation only, in disposable vanilla PostgreSQL. Always rollback.
\set ON_ERROR_STOP on
begin;
do $$begin if exists(select 1 from pg_extension where extname='pg_net') then raise exception 'Run only in the isolated test database without pg_net';end if;end $$;
create function pg_temp.assert(ok boolean,label text) returns void language plpgsql as $$begin if ok is distinct from true then raise exception 'FAIL: %',label;end if;raise notice 'PASS: %',label;end $$;
create schema net;
create table net.test_requests(id bigint generated always as identity,url text,headers jsonb,body jsonb);
create function net.http_post(url text,headers jsonb,body jsonb) returns bigint language plpgsql as $$declare n bigint;begin insert into net.test_requests(url,headers,body) values(url,headers,body) returning id into n;return n;end $$;
insert into auth.users(id,email) values('90000000-0000-0000-0000-000000000001','push1@example.invalid'),('90000000-0000-0000-0000-000000000002','push2@example.invalid');
insert into public.ug_private_config(key,value) values('push_function_url','https://test.invalid/functions/v1/push-dispatch'),('internal_secret','isolated-test-only'),('app_public_url','https://test.invalid') on conflict(key) do update set value=excluded.value;
select public.ug_notify(array['90000000-0000-0000-0000-000000000001'::uuid,'90000000-0000-0000-0000-000000000002'::uuid],'test','Grouped','Body','emergency','critical',true,'push-test');
select pg_temp.assert((select count(*)=1 from net.test_requests),'P1 one HTTP request per recipient group');
select pg_temp.assert((select jsonb_array_length(body->'userIds')=2 and jsonb_array_length(body->'notificationIds')=2 from net.test_requests),'P2 grouped recipient and notification IDs');
select pg_temp.assert((select bool_and(push_count=1 and last_push_at is not null) from notifications where dedupe_key='push-test'),'P3 attempts reserved atomically');
update notifications set last_push_at=now()-interval '2 minutes',created_at=now()-interval '3 minutes' where dedupe_key='push-test';
select ug_repush_pending();
select pg_temp.assert((select count(*)=4 from net.test_requests),'P4 repeat group plus one SMS request per recipient');
select pg_temp.assert((select bool_and(push_count=2 and sms_sent_at is not null) from notifications where dedupe_key='push-test'),'P5 bounded push and single SMS attempt metadata');
select ug_repush_pending();
select pg_temp.assert((select count(*)=4 from net.test_requests),'P6 immediate retry cannot duplicate push or SMS');
update notifications set push_count=60,last_push_at=now()-interval '2 minutes' where dedupe_key='push-test';
select ug_repush_pending();
select pg_temp.assert((select count(*)=4 from net.test_requests),'P7 maximum 60 repeat attempts');
create or replace function net.http_post(url text,headers jsonb,body jsonb) returns bigint language plpgsql as $$begin raise exception 'Simulated transport outage';end $$;
select public.ug_notify(array['90000000-0000-0000-0000-000000000001'::uuid],'test','Still stored','Body');
select pg_temp.assert(exists(select 1 from notifications where title='Still stored'),'P8 transport failure never loses notification');
rollback;
