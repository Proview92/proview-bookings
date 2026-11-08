-- Tests for 005_guest_privacy.sql. Everything runs in one transaction that is rolled back at the
-- end (the results come back in the final error message), so no test data can be left behind.
do $T$
declare
  out text := '';
  u_owner uuid := gen_random_uuid(); u_hostng uuid := gen_random_uuid(); u_hostfull uuid := gen_random_uuid();
  u_hostng2 uuid := gen_random_uuid(); u_kit uuid := gen_random_uuid(); u_owner2 uuid := gen_random_uuid();
  u_mgr2 uuid := gen_random_uuid(); u_master uuid := gen_random_uuid();
  b1 uuid; b2 uuid; va text := 'bk005-test-a1'; va2 text := 'bk005-test-a2'; vb text := 'bk005-test-b1';
  doc jsonb; r jsonb; t text; n int; ok boolean; x jsonb; ts text; gid text; gid2 text; e text;
begin
  -- helpers (run as postgres)
  create or replace function pg_temp.as_(uid uuid, em text) returns void language plpgsql as $f$
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated', 'email', em)::text, true);
    perform set_config('request.jwt.claim.sub', uid::text, true);
    execute 'set local role authenticated';
  end $f$;
  create or replace function pg_temp.svc() returns void language plpgsql as $f$
  begin
    execute 'reset role';
    perform set_config('request.jwt.claims', '', true);
    perform set_config('request.jwt.claim.sub', '', true);
  end $f$;

  -- ---------- test data ----------
  insert into auth.users (id, email) values
    (u_owner, 'bk005-owner@test.invalid'), (u_hostng, 'bk005-host-noguests@test.invalid'), (u_hostfull, 'bk005-host-full@test.invalid'),
    (u_hostng2, 'bk005-host-noguests2@test.invalid'), (u_kit, 'bk005-kitchen@test.invalid'), (u_owner2, 'bk005-owner2@test.invalid'),
    (u_mgr2, 'bk005-mgr-a2@test.invalid'), (u_master, 'bk005-master@test.invalid');
  insert into public.bk_master_admins (user_id, email) values (u_master, 'bk005-master@test.invalid');
  insert into public.bk_businesses (name) values ('BK005 Test A') returning id into b1;
  insert into public.bk_businesses (name) values ('BK005 Test B') returning id into b2;
  insert into public.bk_sites (id, business_id, name, license_type) values (va, b1, 'A1', 'lifetime'), (va2, b1, 'A2', 'lifetime'), (vb, b2, 'B1', 'lifetime');
  insert into public.bk_business_members (business_id, email, role, site_ids, features) values
    (b1, 'bk005-owner@test.invalid', 'Owner', '{}', '{}'),
    (b1, 'bk005-host-noguests@test.invalid', 'Host', array[va], '{"guests":false,"reports":false,"preorders":false,"kitchen":false}'),
    (b1, 'bk005-host-full@test.invalid', 'Host', array[va], '{}'),
    (b1, 'bk005-host-noguests2@test.invalid', 'Host', array[va], '{"guests":false}'),
    (b1, 'bk005-kitchen@test.invalid', 'Host', array[va], '{"preorders":false,"reports":false}'),
    (b1, 'bk005-mgr-a2@test.invalid', 'Manager', array[va2], '{}'),
    (b2, 'bk005-owner2@test.invalid', 'Owner', '{}', '{}');
  insert into public.bk_venue_public (id, data) values (va, '{}'), (vb, '{}');

  -- an "old style" document written with full guest records (as the service would / an old app)
  doc := jsonb_build_object(
    '_m', '{}'::jsonb, '_del', '{}'::jsonb,
    'guestTags', '[{"id":"vip","name":"VIP","cat":"Special"},{"id":"ga-nuts","name":"Nuts","cat":"Allergies"}]'::jsonb,
    'guests', jsonb_build_array(
       jsonb_build_object('id','tg1','name','Charlotte Testperson','email','charlotte@test.invalid','phone','07700 900111','notes','Secret note','tags','["vip","ga-nuts"]'::jsonb,'marketing',true,'birthday','1990-05-01','_u',1000),
       jsonb_build_object('id','tg2','name','Dmitri Example','email','dmitri@test.invalid','phone','07700900222','notes','','tags','[]'::jsonb,'marketing',false,'_u',1000),
       jsonb_build_object('id','tg3','name','Unbooked Signup','email','signup@test.invalid','phone','07700900333','notes','','tags','[]'::jsonb,'marketing',true,'_u',1000)),
    'parties', jsonb_build_array(
       jsonb_build_object('id','tp1','kind','booking','guest','tg1','name','','size',4,'date','2026-11-01','time','19:00','status','finished','spend',212.5,'deposit',20,'depositRef','cs_test_1','preorder',true,'preItems','{"mi1":2}'::jsonb,'notes','Window please','tags','[]'::jsonb,'_u',1000),
       jsonb_build_object('id','tp2','kind','booking','guest','tg2','name','','size',2,'date','2026-11-01','time','20:00','status','finished','spend',80,'deposit',0,'preorder',false,'tags','[]'::jsonb,'_u',1000)),
    'chats', '[]'::jsonb,
    'menus', '[{"id":"m1","name":"Set menu","active":true,"items":[{"id":"mi1","name":"Soup","section":"Starters","price":7.5,"desc":"Leek"}],"_u":1000}]'::jsonb,
    'notes', '[{"id":"n1","text":"New online booking: Charlotte Testperson, party of 4"}]'::jsonb,
    'settings', '{"preorders":{"deposit":5}}'::jsonb);
  insert into public.bk_venue_state (id, data, updated_at) values (va, doc, now()), (vb, doc, now());
  update public.bk_venue_state set data = public.bk_shorten_note_names(doc) where id = va;   -- same as the migration step

  -- ---------- migration / service write ----------
  select data into doc from public.bk_venue_state where id = va;
  select count(*) into n from public.bk_guests where venue = va;
  out := out || format(E'\n%s migration: 3 guests moved to bk_guests (got %s)', case when n = 3 then 'PASS' else 'FAIL' end, n);
  t := doc::text;
  ok := t !~ 'charlotte@test|07700 900111|Secret note|dmitri@test|1990-05-01|Testperson';
  out := out || format(E'\n%s migration: document holds no email/phone/notes/birthday/full name', case when ok then 'PASS' else 'FAIL' end);
  ok := jsonb_array_length(doc -> 'guests') = 2 and (doc -> 'guests' -> 0 ->> 'name') = 'Charlotte T.' and (doc -> 'guests' -> 0 -> 'tags') = '["ga-nuts"]'::jsonb;
  out := out || format(E'\n%s migration: cards only for booked guests, "Charlotte T." with allergy tag only (%s)', case when ok then 'PASS' else 'FAIL' end, doc -> 'guests' -> 0);
  ok := (doc -> 'notes' -> 0 ->> 'text') = 'New online booking: Charlotte T., party of 4';
  out := out || format(E'\n%s migration: notification text shortened', case when ok then 'PASS' else 'FAIL' end);

  -- ---------- owner sees everything ----------
  perform pg_temp.as_(u_owner, 'bk005-owner@test.invalid');
  select count(*) into n from public.bk_guests where venue = va and email_key is not null and phone_key is not null;
  r := public.bk_venue_get(va);
  select count(*) into n from (select 1 from public.bk_guests where venue = va and data ->> 'email' <> '') z;
  x := public.bk_report_money(va, '2026-11-01', '2026-11-01');
  select count(*) into e from public.bk_venue_state where id = va;
  perform pg_temp.svc();
  out := out || format(E'\n%s owner: reads all 3 guests with email/phone from bk_guests', case when n = 3 then 'PASS' else 'FAIL' end);
  ok := (r -> 'data' -> 'parties' -> 0 ->> 'spend') = '212.5' and (r -> 'data' -> 'menus' -> 0 -> 'items' -> 0 ->> 'price') = '7.5' and r -> 'data' -> 'parties' -> 0 ? 'preItems';
  out := out || format(E'\n%s owner: bk_venue_get returns spend, deposits, menus with prices, pre-orders', case when ok then 'PASS' else 'FAIL' end);
  ok := (x ->> 'takings')::numeric = 292.5 and (x ->> 'deposits')::numeric = 20 and (x ->> 'per_head')::numeric = 48.75;
  out := out || format(E'\n%s owner: bk_report_money takings 292.5 / deposits 20 / per head 48.75 (%s)', case when ok then 'PASS' else 'FAIL' end, x);
  out := out || format(E'\n%s owner: direct select of bk_venue_state allowed', case when e = '1' then 'PASS' else 'FAIL' end);

  -- ---------- master sees everything ----------
  perform pg_temp.as_(u_master, 'bk005-master@test.invalid');
  select count(*) into n from public.bk_guests where venue in (va, vb);
  r := public.bk_venue_get(vb);
  perform pg_temp.svc();
  out := out || format(E'\n%s master: reads guests of both businesses (%s) and B''s document', case when n = 6 and r is not null then 'PASS' else 'FAIL' end, n);

  -- ---------- host without guests/reports/preorders/kitchen ----------
  insert into public.bk_inbox (venue, kind, payload) values
    (va, 'booking', '{"name":"Erin Newguest","email":"erin@test.invalid","phone":"07700900444","size":2,"date":"2026-12-01","time":"19:00","mkt":true}'),
    (va, 'booking', '{"name":"Charlotte Testperson","email":"CHARLOTTE@test.invalid","phone":"","size":3,"date":"2026-12-02","time":"19:00"}'),
    (va, 'signup',  '{"name":"Sig Nup","email":"signup2@test.invalid","phone":"07700900555"}');
  perform pg_temp.as_(u_hostng, 'bk005-host-noguests@test.invalid');
  select count(*) into n from public.bk_guests;
  select count(*) into e from public.bk_venue_state where id = va;
  r := public.bk_venue_get(va);
  t := r::text;
  out := out || format(E'\n%s guests off: bk_guests returns 0 rows (got %s)', case when n = 0 then 'PASS' else 'FAIL' end, n);
  out := out || format(E'\n%s guests off (+reports/preorders off): direct select of bk_venue_state returns 0 rows (got %s)', case when e = '0' then 'PASS' else 'FAIL' end, e);
  ok := t !~ '@test\.invalid|0770|Secret note|Testperson' and (r -> 'data' -> 'parties')::text !~ '"spend"|"deposit"|depositRef|preItems' and t !~ '"price"' and (r -> 'data' -> 'menus') = '[]'::jsonb
        and (r -> 'data' -> 'parties' -> 0 ->> '_dep') = 'true' and (r -> 'data' -> 'guests' -> 0 ->> 'name') = 'Charlotte T.';
  out := out || format(E'\n%s guests off: bk_venue_get has no email/phone/notes, no spend/deposit/menus/pre-orders, deposit flag and short names', case when ok then 'PASS' else 'FAIL' end);
  select count(*) into n from public.bk_inbox where venue = va;
  out := out || format(E'\n%s guests off: bk_inbox direct read returns 0 rows (got %s)', case when n = 0 then 'PASS' else 'FAIL' end, n);
  begin x := public.bk_report_money(va, '2026-11-01', '2026-11-30'); ok := false; exception when others then ok := true; end;
  out := out || format(E'\n%s reports off: bk_report_money refused', case when ok then 'PASS' else 'FAIL' end);
  -- online bookings through the inbox RPC
  x := public.bk_inbox_take(va);
  t := x::text;
  ok := jsonb_array_length(x) = 2 and t !~ '@test\.invalid|0770|Newguest|Testperson' and (x -> 0 -> 'payload' ->> 'guest_id') is not null
        and (x -> 0 -> 'payload' -> 'guest' ->> 'name') = 'Erin N.' and (x -> 1 -> 'payload' ->> 'guest_id') = 'tg1';
  out := out || format(E'\n%s guests off: bk_inbox_take gives 2 bookings (not the sign-up) with guest id + short name, no contact details; repeat guest matched by email (%s)', case when ok then 'PASS' else 'FAIL' end, left(t, 300));
  gid := x -> 0 -> 'payload' ->> 'guest_id';
  -- a booking typed in by the host
  begin
    x := public.bk_guest_attach(va, '{"name":"Frank Walkup","phone":"07700 900666","email":"frank@test.invalid"}');
    gid2 := x ->> 'id'; t := x::text;
    ok := t !~ '0770|frank@' and (x -> 'guest' ->> 'name') = 'Frank W.';
  exception when others then ok := false; get stacked diagnostics t = message_text; end;
  out := out || format(E'\n%s guests off: bk_guest_attach creates a guest, returns only id + card (%s)', case when ok then 'PASS' else 'FAIL' end, t);
  x := public.bk_guest_attach(va, '{"name":"Someone","phone":"+44 7700 900222"}');
  out := out || format(E'\n%s guests off: bk_guest_attach matches an existing guest by phone, returns no details (%s)', case when x ->> 'id' = 'tg2' and x::text !~ '0770|dmitri' then 'PASS' else 'FAIL' end, x);
  -- save the document with two new bookings (from the redacted copy) + a status change
  doc := r -> 'data';
  doc := jsonb_set(doc, '{parties}', (doc -> 'parties') || jsonb_build_array(
            jsonb_build_object('id','tp3','kind','booking','guest',gid,'name','','size',2,'date','2026-12-01','time','19:00','status','booked','deposit',0,'preorder',false,'tags','[]'::jsonb,'_u',2000),
            jsonb_build_object('id','tp4','kind','booking','guest',gid2,'name','','size',5,'date','2026-12-03','time','18:00','status','booked','deposit',10,'preorder',true,'preItems','{"mi1":5}'::jsonb,'tags','[]'::jsonb,'_u',2000)));
  doc := jsonb_set(doc, '{parties,0,notes}', '"Window please, birthday"');
  doc := jsonb_set(doc, '{parties,0,_u}', '2000');
  select r ->> 'updated_at' into ts;
  x := public.bk_venue_put(va, doc, ts);
  ok := x is not null;
  r := public.bk_venue_get(va);
  perform pg_temp.svc();
  out := out || format(E'\n%s guests off: can save new bookings through bk_venue_put', case when ok then 'PASS' else 'FAIL' end);
  select data into doc from public.bk_venue_state where id = va;
  ok := (select count(*) from jsonb_array_elements(doc -> 'parties') p where p ->> 'id' in ('tp3','tp4')) = 2
        and (select count(*) from jsonb_array_elements(doc -> 'guests') g where g ->> 'id' in (gid, gid2)) = 2;
  out := out || format(E'\n%s guests off: stored bookings point at the new guests, cards added to the document', case when ok then 'PASS' else 'FAIL' end);
  x := (select p from jsonb_array_elements(doc -> 'parties') p where p ->> 'id' = 'tp1');
  ok := (x ->> 'spend') = '212.5' and (x ->> 'deposit') = '20' and (x ->> 'depositRef') = 'cs_test_1' and (x -> 'preItems') = '{"mi1":2}'::jsonb
        and (x ->> 'preorder') = 'true' and (x ->> 'notes') = 'Window please, birthday' and not x ? '_dep';
  out := out || format(E'\n%s guests off: their edit kept spend/deposit/pre-order they were never sent; their change (notes) saved; _dep not stored', case when ok then 'PASS' else 'FAIL' end);
  ok := (doc -> 'menus' -> 0 -> 'items' -> 0 ->> 'price') = '7.5';
  out := out || format(E'\n%s preorders off: menus with prices still stored after their save', case when ok then 'PASS' else 'FAIL' end);
  x := (select p from jsonb_array_elements(doc -> 'parties') p where p ->> 'id' = 'tp4');
  ok := (x ->> 'deposit') = '10' and not x ? 'preItems' and (x ->> 'preorder') = 'false';
  out := out || format(E'\n%s preorders off: new booking keeps its deposit, pre-order items dropped', case when ok then 'PASS' else 'FAIL' end);
  ok := doc ->> '_g' is null;
  out := out || format(E'\n%s redaction refill is silent (no "changes not saved" stamp)', case when ok then 'PASS' else 'FAIL' end);
  select count(*) into n from public.bk_guests where venue = va and id in (gid, gid2) and data ->> 'phone' <> '';
  out := out || format(E'\n%s attached guests stored with their phone in bk_guests (%s/2)', case when n = 2 then 'PASS' else 'FAIL' end, n);
  select (data ->> 'marketing') into t from public.bk_guests where venue = va and id = gid;
  out := out || format(E'\n%s online opt-in recorded on the new guest', case when t = 'true' then 'PASS' else 'FAIL' end);
  -- bill total typed in by someone without reports: write-only
  perform pg_temp.as_(u_hostng, 'bk005-host-noguests@test.invalid');
  r := public.bk_venue_get(va); doc := r -> 'data';
  doc := jsonb_set(doc, '{parties}', (select jsonb_agg(case when p ->> 'id' = 'tp3' then p || '{"spend":55,"status":"finished","_u":3000}'::jsonb else p end) from jsonb_array_elements(doc -> 'parties') p));
  x := public.bk_venue_put(va, doc, r ->> 'updated_at');
  r := public.bk_venue_get(va);
  perform pg_temp.svc();
  select (p ->> 'spend') into t from public.bk_venue_state s, jsonb_array_elements(s.data -> 'parties') p where s.id = va and p ->> 'id' = 'tp3';
  ok := t = '55' and r::text !~ '"spend"';
  out := out || format(E'\n%s reports off: can record a bill total (stored %s) but never reads it back', case when ok then 'PASS' else 'FAIL' end, t);

  -- ---------- old app (guests off) writes guest details back ----------
  perform pg_temp.as_(u_hostng2, 'bk005-host-noguests2@test.invalid');
  select data, updated_at::text into doc, ts from public.bk_venue_state where id = va;        -- reports+preorders on: direct read allowed
  out := out || format(E'\n%s guests off (reports+preorders on): direct read allowed for older app, document has no contact details', case when doc is not null and doc::text !~ '@test\.invalid|0770' then 'PASS' else 'FAIL' end);
  doc := jsonb_set(doc, '{guests}', (doc -> 'guests') || jsonb_build_array(
            jsonb_build_object('id','tg1','name','Charlotte T.','phone','07999 999999','email','attacker@test.invalid','notes','overwritten','tags','[]'::jsonb,'marketing',false,'_u',9000),
            jsonb_build_object('id','tgnew','name','Gina Oldapp','phone','07700900777','email','gina@test.invalid','notes','','tags','[]'::jsonb,'marketing',false,'_u',9000)));
  doc := jsonb_set(doc, '{parties}', (doc -> 'parties') || jsonb_build_array(jsonb_build_object('id','tp5','kind','booking','guest','tgnew','size',2,'date','2026-12-05','time','19:00','status','booked','tags','[]'::jsonb,'_u',9000)));
  doc := jsonb_set(doc, '{_del}', (doc -> '_del') || '{"tg2":99999999999999}'::jsonb);
  update public.bk_venue_state set data = doc, updated_at = now() where id = va and updated_at = ts::timestamptz;
  get diagnostics n = row_count;
  select data into doc from public.bk_venue_state where id = va;
  select count(*) into e from public.bk_guests;
  perform pg_temp.svc();
  out := out || format(E'\n%s old app, guests off: write accepted (%s row)', case when n = 1 then 'PASS' else 'FAIL' end, n);
  ok := doc::text !~ '@test\.invalid|0770|0799|overwritten|Oldapp';
  out := out || format(E'\n%s old app, guests off: guest details stripped from the stored document', case when ok then 'PASS' else 'FAIL' end);
  select data into x from public.bk_guests where venue = va and id = 'tg1';
  ok := x ->> 'email' = 'charlotte@test.invalid' and x ->> 'phone' = '07700 900111' and x ->> 'notes' = 'Secret note';
  out := out || format(E'\n%s old app, guests off: could not change an existing guest', case when ok then 'PASS' else 'FAIL' end);
  ok := exists (select 1 from public.bk_guests where venue = va and id = 'tg2') and not (doc -> '_del') ? 'tg2';
  out := out || format(E'\n%s old app, guests off: could not delete a guest (tombstone removed)', case when ok then 'PASS' else 'FAIL' end);
  ok := exists (select 1 from public.bk_guests where venue = va and id = 'tgnew' and data ->> 'phone' = '07700900777')
        and (select g ->> 'name' from jsonb_array_elements(doc -> 'guests') g where g ->> 'id' = 'tgnew') = 'Gina O.';
  out := out || format(E'\n%s old app, guests off: new guest for a new booking filed in bk_guests, card in document', case when ok then 'PASS' else 'FAIL' end);
  out := out || format(E'\n%s old app, guests off: still can''t read bk_guests (%s rows)', case when e = '0' then 'PASS' else 'FAIL' end, e);

  -- ---------- old app (guests on) edits + deletes a guest in the document ----------
  perform pg_temp.as_(u_hostfull, 'bk005-host-full@test.invalid');
  select data, updated_at::text into doc, ts from public.bk_venue_state where id = va;
  doc := jsonb_set(doc, '{guests}', (select jsonb_agg(case when g ->> 'id' = 'tg1' then g || '{"phone":"07700 900999","notes":"Prefers booth","_u":10000}'::jsonb else g end) from jsonb_array_elements(doc -> 'guests') g));
  doc := jsonb_set(doc, '{guests}', (doc -> 'guests') || jsonb_build_array(jsonb_build_object('id','tg2b','name','Dmitri Example','email','DMITRI@test.invalid','phone','','tags','[]'::jsonb,'notes','','marketing',true,'_u',10000)));
  doc := jsonb_set(doc, '{parties}', (doc -> 'parties') || jsonb_build_array(jsonb_build_object('id','tp6','kind','booking','guest','tg2b','size',2,'date','2026-12-06','time','19:00','status','booked','tags','[]'::jsonb,'_u',10000)));
  doc := jsonb_set(doc, '{_del}', (doc -> '_del') || '{"tg3":99999999999999}'::jsonb);
  update public.bk_venue_state set data = doc, updated_at = now() where id = va and updated_at = ts::timestamptz;
  select data into doc from public.bk_venue_state where id = va;
  select data into x from public.bk_guests where venue = va and id = 'tg1';
  perform pg_temp.svc();
  ok := x ->> 'phone' = '07700 900999' and x ->> 'notes' = 'Prefers booth' and x ->> 'email' = 'charlotte@test.invalid' and x ->> 'name' = 'Charlotte Testperson'
        and x -> 'tags' @> '["vip"]'::jsonb;
  out := out || format(E'\n%s old app, guests on: edit on the card saved to bk_guests, full name/email/other tags kept (%s)', case when ok then 'PASS' else 'FAIL' end, x);
  ok := not exists (select 1 from public.bk_guests where venue = va and id = 'tg3');
  out := out || format(E'\n%s old app, guests on: deleting a guest removes it from bk_guests', case when ok then 'PASS' else 'FAIL' end);
  ok := not exists (select 1 from public.bk_guests where venue = va and id = 'tg2b')
        and (select p ->> 'guest' from jsonb_array_elements(doc -> 'parties') p where p ->> 'id' = 'tp6') = 'tg2'
        and (select data ->> 'marketing' from public.bk_guests where venue = va and id = 'tg2') = 'true';
  out := out || format(E'\n%s old app, guests on: duplicate guest (same email) merged, booking re-pointed', case when ok then 'PASS' else 'FAIL' end);
  ok := doc::text !~ '@test\.invalid|0770|Prefers booth';
  out := out || format(E'\n%s old app, guests on: document still holds no details', case when ok then 'PASS' else 'FAIL' end);

  -- ---------- new app, guests on: table read/write ----------
  perform pg_temp.as_(u_hostfull, 'bk005-host-full@test.invalid');
  update public.bk_guests set data = data || '{"notes":"VIP regular","_u":20000}'::jsonb where venue = va and id = 'tg1';
  get diagnostics n = row_count;
  update public.bk_guests set data = data || '{"notes":"stale copy","_u":5}'::jsonb where venue = va and id = 'tg1';
  select data ->> 'notes' into t from public.bk_guests where venue = va and id = 'tg1';
  perform pg_temp.svc();
  out := out || format(E'\n%s guests on: can edit guests in bk_guests; an older copy doesn''t overwrite a newer one (%s)', case when n = 1 and t = 'VIP regular' then 'PASS' else 'FAIL' end, t);

  -- ---------- kitchen without preorders ----------
  perform pg_temp.as_(u_kit, 'bk005-kitchen@test.invalid');
  r := public.bk_venue_get(va);
  perform pg_temp.svc();
  ok := (r -> 'data' -> 'menus' -> 0 -> 'items' -> 0 ->> 'name') = 'Soup' and not (r -> 'data' -> 'menus' -> 0 -> 'items' -> 0) ? 'price'
        and (r -> 'data' -> 'parties' -> 0 -> 'preItems') = '{"mi1":2}'::jsonb and r::text !~ '"spend"';
  out := out || format(E'\n%s kitchen on, preorders off: menu item names + pre-order quantities, no prices or spend', case when ok then 'PASS' else 'FAIL' end);

  -- ---------- cancellations check the email on the server ----------
  insert into public.bk_inbox (venue, kind, payload) values (va, 'cancel', '{"id":"tp1","email":"charlotte@TEST.invalid"}'), (va, 'cancel', '{"id":"tp2","email":"wrong@test.invalid"}');
  perform pg_temp.as_(u_hostng, 'bk005-host-noguests@test.invalid');
  x := public.bk_inbox_take(va);
  perform pg_temp.svc();
  ok := jsonb_array_length(x) = 2 and (x -> 0 -> 'payload' ->> 'email_ok') = 'true' and (x -> 1 -> 'payload' ->> 'email_ok') = 'false' and x::text !~ '@';
  out := out || format(E'\n%s guests off: cancellations verified on the server (email_ok true/false), email not returned', case when ok then 'PASS' else 'FAIL' end);

  -- ---------- other business / other site ----------
  perform pg_temp.as_(u_owner2, 'bk005-owner2@test.invalid');
  select count(*) into n from public.bk_guests where venue = va;
  select count(*) into e from public.bk_venue_state where id = va;
  ok := true;
  begin r := public.bk_venue_get(va); ok := false; exception when others then null; end;
  begin x := public.bk_guest_attach(va, '{"name":"X Y","phone":"07700900888"}'); ok := false; exception when others then null; end;
  begin x := public.bk_inbox_take(va); ok := false; exception when others then null; end;
  begin x := public.bk_report_money(va, '2026-11-01', '2026-11-30'); ok := false; exception when others then null; end;
  begin x := public.bk_venue_put(va, '{}'::jsonb, null); ok := false; exception when others then null; end;
  select count(*) into t from public.bk_venue_ping where id = va;
  perform pg_temp.svc();
  out := out || format(E'\n%s other business: bk_guests %s rows, venue_state %s rows, ping %s rows', case when n = 0 and e = '0' and t = '0' then 'PASS' else 'FAIL' end, n, e, t);
  out := out || format(E'\n%s other business: bk_venue_get/put, bk_guest_attach, bk_inbox_take, bk_report_money all refused', case when ok then 'PASS' else 'FAIL' end);
  perform pg_temp.as_(u_mgr2, 'bk005-mgr-a2@test.invalid');
  select count(*) into n from public.bk_guests where venue = va;
  ok := true; begin r := public.bk_venue_get(va); ok := false; exception when others then null; end;
  perform pg_temp.svc();
  out := out || format(E'\n%s manager of another site in the same business: no guests (%s), no document', case when n = 0 and ok then 'PASS' else 'FAIL' end, n);
  perform pg_temp.as_(u_owner, 'bk005-owner@test.invalid');
  select count(*) into n from public.bk_guests where venue = vb;
  perform pg_temp.svc();
  out := out || format(E'\n%s owner of A can''t read B''s guests (%s)', case when n = 0 then 'PASS' else 'FAIL' end, n);
  perform pg_temp.as_(u_hostng, 'bk005-host-noguests@test.invalid');
  select count(*) into n from public.bk_venue_ping where id = va;
  perform pg_temp.svc();
  out := out || format(E'\n%s guests off: change ping visible (%s)', case when n = 1 then 'PASS' else 'FAIL' end, n);

  -- ---------- unsubscribe from campaigns ----------
  n := public.bk_guest_marketing_off(va, 'CHARLOTTE@test.invalid');
  out := out || format(E'\n%s unsubscribe unticks marketing in bk_guests (%s)', case when n = 1 and (select data ->> 'marketing' from public.bk_guests where venue = va and id = 'tg1') = 'false' then 'PASS' else 'FAIL' end, n);

  raise exception 'TEST RESULTS (rolled back):%', out;
end $T$;
