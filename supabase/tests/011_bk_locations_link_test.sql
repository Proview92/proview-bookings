-- Tests for 011_bk_locations_link.sql (hub_call 'link' / 'unlink'). One DO block that always fails at the end (the
-- results come back in the error message), so every test row is rolled back. Before 011 is applied, replace the
-- --MIGRATION-- line with: execute $mig$ <contents of 011_bk_locations_link.sql> $mig$;
do $T$
declare
  out text := '';
  tok text := 'll-test-token-' || gen_random_uuid();
  u1 uuid := gen_random_uuid(); u2 uuid := gen_random_uuid(); u3 uuid := gen_random_uuid(); um uuid := gen_random_uuid();
  e1 text := 'll-own-a-' || substr(md5(random()::text), 1, 6) || '@example.com';
  e2 text := 'll-own-b-' || substr(md5(random()::text), 1, 6) || '@example.com';
  e3 text := 'll-host-b-' || substr(md5(random()::text), 1, 6) || '@example.com';
  ba uuid; bb uuid; sa text := 'll-alpha-' || substr(md5(random()::text), 1, 6); sb text := 'll-beta-' || substr(md5(random()::text), 1, 6);
  n_before int; n_after int; j jsonb; j2 jsonb; lst jsonb; msg text; nid uuid; ok boolean;
begin
  update hub_private.config set token_sha256 = encode(extensions.digest(tok, 'sha256'), 'hex') where id = 1;
  n_before := jsonb_array_length(public.hub_call(tok, 'list', '{}')->'units');

  --MIGRATION--

  n_after := jsonb_array_length(public.hub_call(tok, 'list', '{}')->'units');
  out := out || format(E'%s list unchanged after the migration (%s units)\n', case when n_before = n_after then 'PASS' else 'FAIL' end, n_after);
  out := out || format(E'%s old hub_call kept as hub_private.bk_hub_call_pre_link; link functions not callable by the API\n',
    case when to_regprocedure('hub_private.bk_hub_call_pre_link(text,text,jsonb)') is not null
          and not has_function_privilege('anon', 'hub_private.bk_hub_call_pre_link(text,text,jsonb)', 'execute')
          and not has_function_privilege('authenticated', 'hub_private.bk_link_businesses(uuid,uuid)', 'execute') then 'PASS' else 'FAIL' end);
  begin perform public.hub_call('wrong', 'link', '{}'); ok := false; exception when others then ok := sqlerrm = 'not authorised'; end;
  out := out || format(E'%s link with a wrong token: refused\n', case when ok then 'PASS' else 'FAIL' end);

  -- adding a location is refused for everyone, the master included
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at) values
    (u1, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', e1, now(), now()),
    (u2, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', e2, now(), now()),
    (u3, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', e3, now(), now()),
    (um, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'll-master-' || um || '@example.com', now(), now());
  insert into public.bk_master_admins (user_id, email) values (um, 'll-master-' || um || '@example.com');
  insert into public.bk_businesses (name, contact_email) values ('LL Cafe Alpha', e1) returning id into ba;
  insert into public.bk_businesses (name, contact_email) values ('LL Cafe Beta', e2) returning id into bb;
  insert into public.bk_sites (id, business_id, name) values (sa, ba, 'LL Cafe Alpha'), (sb, bb, 'LL Cafe Beta');
  insert into public.bk_venue_state (id, data) values (sb, '{"ll":"beta bookings"}');
  perform set_config('request.jwt.claims', json_build_object('sub', um, 'role', 'authenticated', 'email', 'll-master-' || um || '@example.com')::text, true);
  perform set_config('request.jwt.claim.sub', um::text, true);
  begin perform public.bk_add_site(ba, 'Second site', null); msg := null; exception when others then msg := sqlerrm; end;
  out := out || format(E'%s bk_add_site refused for the master (%s)\n', case when msg like 'Locations are added in the licence portal%' then 'PASS' else 'FAIL' end, msg);
  perform set_config('request.jwt.claims', '', true); perform set_config('request.jwt.claim.sub', '', true);
  out := out || format(E'%s nobody can insert or delete a bk_sites row through the API (no insert/delete policy or grant)\n',
    case when not exists (select 1 from pg_policies where tablename = 'bk_sites' and cmd in ('INSERT', 'DELETE', 'ALL'))
          and not has_table_privilege('authenticated', 'public.bk_sites', 'insert')
          and not has_table_privilege('authenticated', 'public.bk_sites', 'delete')
          and exists (select 1 from pg_policies where tablename = 'bk_sites' and cmd = 'UPDATE') then 'PASS' else 'FAIL' end);

  -- people: e1 Owner of A and Host of B; e2 Owner of B; e3 Host of B (B's site only)
  insert into public.bk_business_members (business_id, email, user_id, role, site_ids, features) values
    (ba, e1, u1, 'Owner', '{}', '{}'), (bb, e1, u1, 'Host', array[sb], '{}'), (bb, e2, u2, 'Owner', '{}', '{}'), (bb, e3, u3, 'Host', array[sb], '{}');

  -- 1. link B into A
  j := public.hub_call(tok, 'link', jsonb_build_object('into', ba, 'from', bb));
  out := out || format(E'%s link answer: ok, account A, moved_sites [B''s site] (%s)\n',
    case when (j->>'ok')::boolean and j->>'account' = ba::text and j->'moved_sites' = jsonb_build_array(sb) and not (j->>'already')::boolean
         then 'PASS' else 'FAIL' end, j);
  out := out || format(E'%s B''s business is gone; its location (with its bookings data) is in A\n',
    case when not exists (select 1 from public.bk_businesses where id = bb) and (select business_id from public.bk_sites where id = sb) = ba
          and (select data->>'ll' from public.bk_venue_state where id = sb) = 'beta bookings' then 'PASS' else 'FAIL' end);
  out := out || format(E'%s people: B''s owner is an owner of A; e1 kept Owner (higher); e3 Host of B''s location only\n',
    case when (select role from public.bk_business_members where business_id = ba and email = e2) = 'Owner'
          and (select role from public.bk_business_members where business_id = ba and email = e1) = 'Owner'
          and (select role = 'Host' and site_ids = array[sb] from public.bk_business_members where business_id = ba and email = e3) then 'PASS' else 'FAIL' end);
  out := out || format(E'%s owners of either side are staff at both locations; the host only at B''s\n',
    case when (select count(*) from public.bk_staff_profiles where user_id = u2 and venue in (sa, sb)) = 2
          and (select count(*) from public.bk_staff_profiles where user_id = u1 and venue in (sa, sb)) = 2
          and (select array_agg(venue) from public.bk_staff_profiles where user_id = u3) = array[sb] then 'PASS' else 'FAIL' end);
  lst := public.hub_call(tok, 'list', '{}');
  out := out || format(E'%s list: B''s location unit under A, B''s account gone\n',
    case when exists (select 1 from jsonb_array_elements(lst->'units') u where u->>'id' = sb and u->>'account_id' = ba::text)
          and not exists (select 1 from jsonb_array_elements(lst->'accounts') a where a->>'id' = bb::text) then 'PASS' else 'FAIL' end);

  -- 2. idempotent; refusals
  j2 := public.hub_call(tok, 'link', jsonb_build_object('into', ba, 'from', bb));
  out := out || format(E'%s link again: ok, already (%s)\n', case when (j2->>'already')::boolean and j2->'moved_sites' = jsonb_build_array(sb) then 'PASS' else 'FAIL' end, j2);
  begin perform public.hub_call(tok, 'link', jsonb_build_object('into', ba, 'from', ba)); msg := null; exception when others then msg := sqlerrm; end;
  out := out || format(E'%s link to itself refused (%s)\n', case when msg like '%itself%' then 'PASS' else 'FAIL' end, msg);
  begin perform public.hub_call(tok, 'link', jsonb_build_object('into', gen_random_uuid(), 'from', ba)); msg := null; exception when others then msg := sqlerrm; end;
  out := out || format(E'%s link into a missing account refused (%s)\n', case when msg like 'Account not found:%' then 'PASS' else 'FAIL' end, msg);
  begin perform public.hub_call(tok, 'link', jsonb_build_object('into', ba, 'from', 'not-a-uuid')); msg := null; exception when others then msg := sqlerrm; end;
  out := out || format(E'%s link from a bad id refused (%s)\n', case when msg like 'Account not found:%' then 'PASS' else 'FAIL' end, msg);

  -- 3. unlink B's location again
  j := public.hub_call(tok, 'unlink', jsonb_build_object('account', ba, 'site', sb));
  nid := (j->>'account')::uuid;
  out := out || format(E'%s unlink answer: ok, new account, same site id (%s)\n',
    case when (j->>'ok')::boolean and nid is not null and nid <> ba and j->>'site' = sb then 'PASS' else 'FAIL' end, j);
  out := out || format(E'%s new business named after the location, holding only it\n',
    case when (select name from public.bk_businesses where id = nid) = 'LL Cafe Beta'
          and (select array_agg(id) from public.bk_sites where business_id = nid) = array[sb] then 'PASS' else 'FAIL' end);
  out := out || format(E'%s people who could see it copied (owners e1, e2; host e3); A keeps its owners\n',
    case when (select count(*) from public.bk_business_members where business_id = nid and email in (e1, e2, e3)) = 3
          and (select count(*) from public.bk_business_members where business_id = ba and role = 'Owner' and email in (e1, e2)) = 2 then 'PASS' else 'FAIL' end);
  out := out || format(E'%s staff: e3 still at the location; owners still at both\n',
    case when exists (select 1 from public.bk_staff_profiles where user_id = u3 and venue = sb)
          and (select count(*) from public.bk_staff_profiles where user_id = u2 and venue in (sa, sb)) = 2 then 'PASS' else 'FAIL' end);
  j2 := public.hub_call(tok, 'unlink', jsonb_build_object('account', ba, 'site', sb));
  out := out || format(E'%s unlink again: ok, already, same new account (%s)\n', case when (j2->>'already')::boolean and j2->>'account' = nid::text then 'PASS' else 'FAIL' end, j2);
  begin perform public.hub_call(tok, 'unlink', jsonb_build_object('account', ba, 'site', sa)); msg := null; exception when others then msg := sqlerrm; end;
  out := out || format(E'%s unlink of the only location refused (%s)\n', case when msg like '%only that one location%' then 'PASS' else 'FAIL' end, msg);
  begin perform public.hub_call(tok, 'unlink', jsonb_build_object('account', ba, 'site', 'no-such-site')); msg := null; exception when others then msg := sqlerrm; end;
  out := out || format(E'%s unlink of a missing location refused (%s)\n', case when msg like 'Location not found:%' then 'PASS' else 'FAIL' end, msg);
  begin perform public.hub_call(tok, 'unlink', jsonb_build_object('account', nid, 'site', sa)); msg := null; exception when others then msg := sqlerrm; end;
  out := out || format(E'%s unlink of another account''s location refused (%s)\n', case when msg like 'That location is not in account%' then 'PASS' else 'FAIL' end, msg);

  raise exception E'011 test (rolled back):\n%', out;
end $T$;
