-- 008: no free trials (NO_TRIAL_SPEC, owner 11 Nov 2026: "make all businesses start with inactive, they must purchase a
-- license" / "No trials at all"). Bookings objects only (bk_*): the database is shared with Proview Till.
--
-- A new business and its first location, and any location added later, start with NO licence: the app's existing
-- "no licence" lock (staff locked out, online booking paused) with Buy a licence online (Stripe links from the licence
-- hub's hub_plans) and the licence portal / 020 8935 5495. The owner can still sign in and reach that screen.
--
-- Trial paths closed here:
--   bk_create_my_business  self-signup "Set up your business": the location was 'trial' for 3 days; now no licence, and
--                          the one-trial-per-email check (an earlier self-signup business with the same email) is gone.
--   bk_add_business        the master's + Add business: the location was 'trial' for 3 days; now no licence.
--   bk_add_site            older "add a location" (p_license defaulted to 'trial'): now no licence (p_license ignored).
--   bk_sites_no_trial      new trigger: any other insert into bk_sites (e.g. a future hub_call 'add_business') with
--                          license_type 'trial' is stored with no licence instead.
-- Existing businesses and locations are not changed: a location on a trial today keeps its current expiry.
-- The licence portal can still set 'trial' by hand (hub_call 'set' updates, it never inserts).
-- Safe to run more than once.

-- 1) Any new location starts without a trial.
create or replace function public.bk_sites_no_trial()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.license_type = 'trial' then
    new.license_type := null; new.license_starts_at := null; new.license_expires_at := null;
    new.license_updated_at := null;
  end if;
  return new;
end $$;

drop trigger if exists bk_sites_no_trial on public.bk_sites;
create trigger bk_sites_no_trial before insert on public.bk_sites
  for each row execute function public.bk_sites_no_trial();

-- 2) Self-signup: business + first location (no licence) + you as Owner.
create or replace function public.bk_create_my_business(p_business text, p_site text default null, p_phone text default null)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare bid uuid; sid text; em text := lower(auth.jwt() ->> 'email');
        bn text := left(trim(coalesce(p_business,'')), 80);
        sn text := left(trim(coalesce(nullif(trim(p_site),''), p_business, '')), 80);
begin
  if auth.uid() is null or coalesce(em, '') = '' then raise exception 'Please sign in first.'; end if;
  if length(bn) < 2 then raise exception 'Please enter your business name.'; end if;
  if exists (select 1 from public.bk_staff_profiles where user_id = auth.uid())
     or exists (select 1 from public.bk_staff_invites where lower(email) = em)
     or exists (select 1 from public.bk_business_members where user_id = auth.uid() or email = em) then
    raise exception 'Your account already belongs to a business.';
  end if;
  insert into public.bk_businesses (name, contact_email, phone, self_signup, notes)
  values (bn, em, nullif(left(trim(coalesce(p_phone,'')), 30), ''), true, 'Signed up online')
  returning id into bid;
  sid := public.bk_new_site_id(sn);
  insert into public.bk_sites (id, business_id, name) values (sid, bid, sn);   -- no licence until one is bought
  insert into public.bk_business_members (business_id, email, user_id, name, role, site_ids, features)
  values (bid, em, auth.uid(), null, 'Owner', '{}', '{}'::jsonb);
  return sid;
end $$;

-- 3) The master's + Add business: as before, but the location starts with no licence.
create or replace function public.bk_add_business(p_business text, p_name text, p_email text, p_mobile text, p_password text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  bn  text := left(trim(coalesce(p_business, '')), 80);
  nm  text := nullif(left(trim(coalesce(p_name, '')), 80), '');
  em  text := lower(trim(coalesce(p_email, '')));
  mob text := nullif(left(trim(coalesce(p_mobile, '')), 30), '');
  bid uuid; sid text; uid uuid; existing boolean := false;
begin
  if auth.uid() is null or not public.bk_is_master() then
    raise exception 'Only the Proview administrator can add businesses.';
  end if;
  if length(bn) < 2 then raise exception 'Enter the business name.'; end if;
  if length(coalesce(nm, '')) < 2 then raise exception 'Enter the owner''s name.'; end if;
  if em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a valid email address.'; end if;

  insert into public.bk_businesses (name, contact_email, phone, self_signup, notes)
  values (bn, em, mob, false, 'Added by Proview')
  returning id into bid;
  sid := public.bk_new_site_id(bn);
  insert into public.bk_sites (id, business_id, name) values (sid, bid, bn);   -- no licence until one is bought

  select id into uid from auth.users where lower(email) = em and not coalesce(is_anonymous, false) order by created_at limit 1;
  if uid is not null then
    existing := true;
  else
    if length(coalesce(p_password, '')) < 6 then raise exception 'The password needs at least 6 characters.'; end if;
    uid := gen_random_uuid();
    insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
                            raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                            confirmation_token, recovery_token, email_change, email_change_token_new)
    values (uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', em,
            extensions.crypt(p_password, extensions.gen_salt('bf', 10)), now(),
            '{"provider":"email","providers":["email"]}'::jsonb,
            jsonb_strip_nulls(jsonb_build_object('full_name', nm, 'mobile', mob)), now(), now(), '', '', '', '');
    insert into auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
    values (gen_random_uuid(), uid, uid::text, 'email',
            jsonb_build_object('sub', uid::text, 'email', em, 'email_verified', true, 'phone_verified', false), now(), now(), now());
  end if;

  insert into public.bk_business_members (business_id, email, user_id, name, role, site_ids, features)
  values (bid, em, uid, nm, 'Owner', '{}', '{}'::jsonb);

  return jsonb_build_object('business_id', bid, 'site_id', sid, 'user_id', uid, 'email', em, 'existing', existing);
end;
$$;

-- 4) Older "add a location" (master only): no licence; p_license is kept in the signature but ignored.
create or replace function public.bk_add_site(p_business uuid, p_name text, p_license text default 'trial')
returns public.bk_sites
language plpgsql
security definer
set search_path = public
as $$
declare s public.bk_sites; b public.bk_businesses; nm text := left(trim(coalesce(p_name,'')), 80);
begin
  if not public.bk_is_master() then raise exception 'Only the Proview administrator can add sites.'; end if;
  select * into b from public.bk_businesses where id = p_business;
  if not found then raise exception 'Business not found'; end if;
  if length(nm) < 2 then raise exception 'Enter the site name.'; end if;
  insert into public.bk_sites (id, business_id, name, license_notes)
  values (public.bk_new_site_id(nm), p_business, nm, 'No licence yet — buy online or set it at license.proviewcrm.co.uk')
  returning * into s;
  if b.contact_email is not null then
    insert into public.bk_staff_invites (email, venue, role) values (lower(b.contact_email), s.id, 'Admin') on conflict do nothing;
  end if;
  return s;
end $$;
