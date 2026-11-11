-- Tests for 008_no_trial.sql. One DO block that always fails at the end (the results come back in the error message),
-- so every test row is rolled back. Before 008 is applied, run it with the migration executed first
-- (replace the --MIGRATION-- line with: execute $mig$ <contents of 008_no_trial.sql> $mig$;).
do $T$
declare
  out text := '';
  u_master uuid := (select user_id from public.bk_master_admins where email = 'altun@proviewtech.co.uk');
  u_self uuid := gen_random_uuid(); u_again uuid := gen_random_uuid(); u_other uuid := gen_random_uuid();
  before_s text; after_s text; r jsonb; w jsonb; sid text; e text; bid uuid; s public.bk_sites; ok boolean;
begin
  select md5(coalesce(string_agg(id || coalesce(license_type, '-') || coalesce(license_starts_at::text, '-') || coalesce(license_expires_at::text, '-'), ',' order by id), ''))
    into before_s from public.bk_sites;

  --MIGRATION--

  insert into auth.users (id, email, aud, role) values
    (u_self, 'bk008-self@test.invalid', 'authenticated', 'authenticated'),
    (u_again, 'bk008-again@test.invalid', 'authenticated', 'authenticated'),
    (u_other, 'bk008-other@test.invalid', 'authenticated', 'authenticated');
  -- bk008-again already had a self-signup business (the old one-trial-per-email rule)
  insert into public.bk_businesses (name, contact_email, self_signup, notes) values ('BK008 Old', 'bk008-again@test.invalid', true, 'test');

  -- ---------- 1. the master's + Add business
  perform set_config('request.jwt.claims', json_build_object('sub', u_master, 'role', 'authenticated', 'email', 'altun@proviewtech.co.uk')::text, true);
  perform set_config('request.jwt.claim.sub', u_master::text, true);
  execute 'set local role authenticated';
  r := public.bk_add_business('BK008 Master Biz', 'Owner Person', 'bk008-owner@test.invalid', null, 'secret123');
  execute 'reset role';
  select * into s from public.bk_sites where id = r->>'site_id';
  out := out || format(E'\n%s master + Add business: location %s has no licence (%s / %s), bk_site_ok %s',
    case when s.license_type is null and s.license_expires_at is null and not public.bk_site_ok(s.id) then 'PASS' else 'FAIL' end,
    s.id, coalesce(s.license_type, 'none'), coalesce(s.license_expires_at::text, 'none'), public.bk_site_ok(s.id));
  -- the new Owner signs in: sees the location (to reach the buy screen) with no licence
  perform set_config('request.jwt.claims', json_build_object('sub', r->>'user_id', 'role', 'authenticated', 'email', 'bk008-owner@test.invalid')::text, true);
  perform set_config('request.jwt.claim.sub', r->>'user_id', true);
  execute 'set local role authenticated';
  w := public.bk_whoami();
  execute 'reset role';
  out := out || format(E'\n%s new Owner can sign in and sees the location as Owner with no licence (%s)',
    case when jsonb_array_length(w->'sites') = 1 and w->'sites'->0->>'role' = 'Owner' and w->'sites'->0->>'license_type' is null then 'PASS' else 'FAIL' end,
    w->'sites');

  -- ---------- 2. self-signup ("Set up your business")
  perform set_config('request.jwt.claims', json_build_object('sub', u_self, 'role', 'authenticated', 'email', 'bk008-self@test.invalid')::text, true);
  perform set_config('request.jwt.claim.sub', u_self::text, true);
  execute 'set local role authenticated';
  sid := public.bk_create_my_business('BK008 Self Biz', null, '0700');
  w := public.bk_whoami();
  execute 'reset role';
  select * into s from public.bk_sites where id = sid;
  out := out || format(E'\n%s self-signup: business + location, no licence (%s), Owner (%s)',
    case when s.license_type is null and s.license_expires_at is null and w->'sites'->0->>'role' = 'Owner' then 'PASS' else 'FAIL' end,
    coalesce(s.license_type, 'none'), w->'sites'->0->>'role');
  out := out || format(E'\n%s self-signup: bk_site_status says not ok (%s)', case when not (public.bk_site_status(sid)->>'ok')::boolean then 'PASS' else 'FAIL' end, public.bk_site_status(sid));

  -- an email that already had a self-signup business can set one up again (no licence)
  perform set_config('request.jwt.claims', json_build_object('sub', u_again, 'role', 'authenticated', 'email', 'bk008-again@test.invalid')::text, true);
  perform set_config('request.jwt.claim.sub', u_again::text, true);
  execute 'set local role authenticated';
  ok := true; sid := null;
  begin sid := public.bk_create_my_business('BK008 Again Biz', null, null); exception when others then ok := false; e := sqlerrm; end;
  execute 'reset role';
  out := out || format(E'\n%s self-signup with an email that had a trial: allowed, no licence %s',
    case when ok and (select license_type from public.bk_sites where id = sid) is null then 'PASS' else 'FAIL' end, coalesce(e, ''));

  -- ---------- 3. older function: bk_add_site (p_license defaulted to 'trial') = a new location for an existing business
  bid := (r->>'business_id')::uuid;
  perform set_config('request.jwt.claims', json_build_object('sub', u_master, 'role', 'authenticated', 'email', 'altun@proviewtech.co.uk')::text, true);
  perform set_config('request.jwt.claim.sub', u_master::text, true);
  execute 'set local role authenticated';
  s := public.bk_add_site(bid, 'BK008 Second Place');
  execute 'reset role';
  out := out || format(E'\n%s new location (bk_add_site, default ''trial''): no licence (%s)', case when s.license_type is null and s.license_expires_at is null then 'PASS' else 'FAIL' end, coalesce(s.license_type, 'none'));

  -- ---------- 4. any other insert (e.g. a hub path) with 'trial' is stored with no licence
  insert into public.bk_sites (id, business_id, name, license_type, license_starts_at, license_expires_at, license_updated_at)
  values ('bk008-direct', bid, 'BK008 Direct', 'trial', now(), now() + interval '3 days', now()) returning * into s;
  out := out || format(E'\n%s direct insert with ''trial'': stored with no licence (%s)', case when s.license_type is null and s.license_expires_at is null then 'PASS' else 'FAIL' end, coalesce(s.license_type, 'none'));
  insert into public.bk_sites (id, business_id, name, license_type, license_starts_at, license_expires_at) values ('bk008-paid', bid, 'BK008 Paid', 'm12', now(), now() + interval '12 months') returning * into s;
  out := out || format(E'\n%s direct insert with a paid licence (licence hub / Stripe): kept (%s)', case when s.license_type = 'm12' then 'PASS' else 'FAIL' end, coalesce(s.license_type, 'none'));
  -- the licence portal can still set a trial by hand (update, not insert)
  update public.bk_sites set license_type = 'trial', license_starts_at = now(), license_expires_at = now() + interval '3 days' where id = 'bk008-direct' returning * into s;
  out := out || format(E'\n%s licence portal can still set ''trial'' by hand (%s)', case when s.license_type = 'trial' then 'PASS' else 'FAIL' end, coalesce(s.license_type, 'none'));

  -- ---------- 5. a non-master is still refused
  perform set_config('request.jwt.claims', json_build_object('sub', u_other, 'role', 'authenticated', 'email', 'bk008-other@test.invalid')::text, true);
  perform set_config('request.jwt.claim.sub', u_other::text, true);
  execute 'set local role authenticated';
  ok := true; e := null;
  begin perform public.bk_add_business('BK008 Sneaky', 'X Person', 'bk008-x@test.invalid', null, 'secret123'); exception when others then ok := false; e := sqlerrm; end;
  out := out || format(E'\n%s non-master bk_add_business refused (%s)', case when not ok then 'PASS' else 'FAIL' end, coalesce(e, 'allowed'));
  ok := true; e := null;
  begin perform public.bk_add_site(bid, 'BK008 Sneaky Site'); exception when others then ok := false; e := sqlerrm; end;
  out := out || format(E'\n%s non-master bk_add_site refused (%s)', case when not ok then 'PASS' else 'FAIL' end, coalesce(e, 'allowed'));
  ok := true; e := null;
  begin insert into public.bk_sites (id, business_id, name, license_type) values ('bk008-sneaky', bid, 'Sneaky', 'm12'); exception when others then ok := false; e := sqlerrm; end;
  out := out || format(E'\n%s non-master cannot insert a licensed location (%s)', case when not ok then 'PASS' else 'FAIL' end, coalesce(e, 'allowed'));
  execute 'reset role';

  -- ---------- 6. existing locations (incl. ones on a trial today) unchanged
  select md5(coalesce(string_agg(id || coalesce(license_type, '-') || coalesce(license_starts_at::text, '-') || coalesce(license_expires_at::text, '-'), ',' order by id), ''))
    into after_s from public.bk_sites
   where business_id not in (select id from public.bk_businesses where name like 'BK008 %');
  out := out || format(E'\n%s existing locations unchanged (%s on a trial today keep their expiry)',
    case when before_s = after_s then 'PASS' else 'FAIL' end,
    (select count(*) from public.bk_sites where license_type = 'trial' and license_expires_at > now() and id not like 'bk008-%'));

  raise exception 'ROLLED BACK. Results:%', out;
end $T$;
