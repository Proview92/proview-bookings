-- Tests for 007_add_business.sql. Run together with the migration as ONE query: everything is one
-- transaction that always fails at the end (the results come back in the error message), so the
-- function and every test row are rolled back.
do $T$
declare
  out text := '';
  u_master uuid := (select user_id from public.bk_master_admins where email = 'altun@proviewtech.co.uk');
  u_other uuid := gen_random_uuid(); u_till uuid := gen_random_uuid();
  r jsonb; e text; pw_before text; pw_after text; n int; nb int; w jsonb; uid uuid;
begin
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

  -- a non-master login, and an existing till login (the till's trigger gives it a staff row)
  insert into auth.users (id, email, encrypted_password, aud, role) values
    (u_other, 'bk007-other@test.invalid', extensions.crypt('otherpass', extensions.gen_salt('bf', 4)), 'authenticated', 'authenticated'),
    (u_till,  'bk007-till@test.invalid',  extensions.crypt('tillpass1', extensions.gen_salt('bf', 4)), 'authenticated', 'authenticated');
  select count(*) into n from public.staff where user_id = u_till;
  out := out || format(E'\n%s till login has a till staff row (%s)', case when n = 1 then 'PASS' else 'FAIL' end, n);
  select encrypted_password into pw_before from auth.users where id = u_till;
  select count(*) into nb from public.bk_businesses;

  -- 1. master, new email
  perform pg_temp.as_(u_master, 'altun@proviewtech.co.uk');
  r := public.bk_add_business('BK007 Test Bistro', 'Sam Taylor', ' BK007-New@Test.Invalid ', '07700 900123', 'secret12');
  perform pg_temp.svc();
  out := out || format(E'\n%s master adds (new email): existing=%s', case when (r->>'existing')::boolean = false then 'PASS' else 'FAIL' end, r->>'existing');
  select count(*) into n from public.bk_sites s join public.bk_businesses b on b.id = s.business_id
   where b.id = (r->>'business_id')::uuid and s.name = 'BK007 Test Bistro' and b.name = 'BK007 Test Bistro' and s.license_type = 'trial' and s.license_expires_at > now();
  out := out || format(E'\n%s business + one same-name location on trial (%s)', case when n = 1 then 'PASS' else 'FAIL' end, n);
  select count(*) into n from auth.users u where u.id = (r->>'user_id')::uuid and u.email = 'bk007-new@test.invalid'
     and u.email_confirmed_at is not null and u.encrypted_password = extensions.crypt('secret12', u.encrypted_password)
     and u.raw_user_meta_data->>'full_name' = 'Sam Taylor' and u.raw_user_meta_data->>'mobile' = '07700 900123'
     and exists (select 1 from auth.identities i where i.user_id = u.id and i.provider = 'email');
  out := out || format(E'\n%s login ready: confirmed, password set, name + mobile, email identity (%s)', case when n = 1 then 'PASS' else 'FAIL' end, n);
  select count(*) into n from public.bk_business_members where business_id = (r->>'business_id')::uuid and email = 'bk007-new@test.invalid' and role = 'Owner' and user_id = (r->>'user_id')::uuid;
  out := out || format(E'\n%s member row role Owner (%s)', case when n = 1 then 'PASS' else 'FAIL' end, n);
  select count(*) into n from public.bk_staff_profiles where user_id = (r->>'user_id')::uuid and venue = r->>'site_id' and role = 'Owner';
  out := out || format(E'\n%s per-venue profile synced as Owner (%s)', case when n = 1 then 'PASS' else 'FAIL' end, n);
  uid := (r->>'user_id')::uuid;
  perform pg_temp.as_(uid, 'bk007-new@test.invalid');
  w := public.bk_whoami();
  perform pg_temp.svc();
  out := out || format(E'\n%s new owner whoami: not master, sees only its site as Owner (%s)',
    case when not (w->>'is_master')::boolean and jsonb_array_length(w->'sites') = 1 and w->'sites'->0->>'role' = 'Owner' and w->'sites'->0->>'id' = r->>'site_id' then 'PASS' else 'FAIL' end, w->'sites');

  -- 2. non-master refused, nothing left
  select count(*) into nb from public.bk_businesses;
  perform pg_temp.as_(u_other, 'bk007-other@test.invalid');
  begin
    r := public.bk_add_business('BK007 Sneaky', 'Eve Other', 'bk007-eve@test.invalid', null, 'secret12');
    e := 'no error';
  exception when others then e := sqlerrm; end;
  perform pg_temp.svc();
  select count(*) into n from public.bk_businesses;
  out := out || format(E'\n%s non-master refused (%s), businesses %s -> %s', case when e like 'Only the Proview administrator%' and n = nb then 'PASS' else 'FAIL' end, e, nb, n);
  -- anon has no execute
  begin
    execute 'set local role anon';
    perform public.bk_add_business('BK007 Anon', 'An On', 'bk007-anon@test.invalid', null, 'secret12');
    e := 'no error';
  exception when others then e := sqlerrm; end;
  perform pg_temp.svc();
  out := out || format(E'\n%s anon refused (%s)', case when e like 'permission denied%' then 'PASS' else 'FAIL' end, e);

  -- 3. existing (till) login keeps its password
  perform pg_temp.as_(u_master, 'altun@proviewtech.co.uk');
  r := public.bk_add_business('BK007 Till Owner Ltd', 'Till Person', 'BK007-till@test.invalid', null, 'NEWpass99');
  perform pg_temp.svc();
  select encrypted_password into pw_after from auth.users where id = u_till;
  out := out || format(E'\n%s existing login: existing=%s, same user=%s, password unchanged=%s',
    case when (r->>'existing')::boolean and (r->>'user_id')::uuid = u_till and pw_after = pw_before then 'PASS' else 'FAIL' end,
    r->>'existing', (r->>'user_id')::uuid = u_till, pw_after = pw_before);
  select count(*) into n from public.bk_business_members where business_id = (r->>'business_id')::uuid and user_id = u_till and role = 'Owner';
  out := out || format(E'\n%s existing login made Owner (%s)', case when n = 1 then 'PASS' else 'FAIL' end, n);
  select count(*) into n from auth.users where lower(email) = 'bk007-till@test.invalid';
  out := out || format(E'\n%s no second login made (%s)', case when n = 1 then 'PASS' else 'FAIL' end, n);
  select count(*) into n from public.staff where user_id = u_till;
  out := out || format(E'\n%s till staff row untouched (%s)', case when n = 1 then 'PASS' else 'FAIL' end, n);
  -- existing login, short password typed: still fine (the password isn't used)
  perform pg_temp.as_(u_master, 'altun@proviewtech.co.uk');
  begin r := public.bk_add_business('BK007 Till Two', 'Till Person', 'bk007-till@test.invalid', null, ''); e := 'ok';
  exception when others then e := sqlerrm; end;
  perform pg_temp.svc();
  out := out || format(E'\n%s existing login with empty password typed is accepted (%s)', case when e = 'ok' then 'PASS' else 'FAIL' end, e);

  -- 4. bad input refused, nothing left behind
  select count(*) into nb from public.bk_businesses;
  perform pg_temp.as_(u_master, 'altun@proviewtech.co.uk');
  begin r := public.bk_add_business('BK007 Bad Email', 'Bad Email', 'not-an-email', null, 'secret12'); e := 'no error';
  exception when others then e := sqlerrm; end;
  out := out || format(E'\n%s bad email refused (%s)', case when e = 'Enter a valid email address.' then 'PASS' else 'FAIL' end, e);
  begin r := public.bk_add_business('BK007 Short Pass', 'Short Pass', 'bk007-short@test.invalid', null, '12345'); e := 'no error';
  exception when others then e := sqlerrm; end;
  out := out || format(E'\n%s short password refused (%s)', case when e = 'The password needs at least 6 characters.' then 'PASS' else 'FAIL' end, e);
  begin r := public.bk_add_business('X', 'Some One', 'bk007-x@test.invalid', null, 'secret12'); e := 'no error';
  exception when others then e := sqlerrm; end;
  out := out || format(E'\n%s 1-letter business refused (%s)', case when e = 'Enter the business name.' then 'PASS' else 'FAIL' end, e);
  begin r := public.bk_add_business('BK007 No Name', 'S', 'bk007-x@test.invalid', null, 'secret12'); e := 'no error';
  exception when others then e := sqlerrm; end;
  out := out || format(E'\n%s 1-letter owner name refused (%s)', case when e = 'Enter the owner''s name.' then 'PASS' else 'FAIL' end, e);
  perform pg_temp.svc();
  select count(*) into n from public.bk_businesses;
  out := out || format(E'\n%s no business left behind after refusals (%s -> %s)', case when n = nb then 'PASS' else 'FAIL' end, nb, n);
  select count(*) into n from auth.users where email in ('bk007-short@test.invalid', 'bk007-x@test.invalid');
  out := out || format(E'\n%s no login left behind after refusals (%s)', case when n = 0 then 'PASS' else 'FAIL' end, n);
  select count(*) into n from public.bk_sites where name like 'BK007 Short%' or name like 'BK007 Bad%';
  out := out || format(E'\n%s no location left behind after refusals (%s)', case when n = 0 then 'PASS' else 'FAIL' end, n);

  raise exception 'TEST RESULTS (rolled back):%', out;
end $T$;
