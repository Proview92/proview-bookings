-- =====================================================================
-- 007: "+ Add business" on the Locations page (ADD_BUSINESS_SPEC, 10 Nov 2026), as Proview Signage
-- (signage migration 038, add_business / add_user). Touches only bk_* objects: this database and
-- auth.users are shared with the till.
--
-- bk_add_business (Proview master only), all-or-nothing:
--   1. the business (bk_businesses) and one location (bk_sites) with the same name, on the usual
--      3-day trial licence (as bk_add_site / sign-up); extend it in the licence portal;
--   2. the owner login:
--      - new email: a ready-to-use login (email confirmed, password set, name and mobile kept),
--        no email sent;
--      - email that already has a login (Bookings or till): NOT touched, their password stays;
--   3. that person becomes the business Owner (bk_business_members; the members trigger writes the
--      per-venue invite / profile rows).
-- Any error (bad email, short password, not the master...) undoes the whole thing.
-- =====================================================================

create or replace function public.bk_add_business(p_business text, p_name text, p_email text, p_mobile text, p_password text)
returns jsonb
language plpgsql security definer
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

  -- the business and its location
  insert into public.bk_businesses (name, contact_email, phone, self_signup, notes)
  values (bn, em, mob, false, 'Added by Proview')
  returning id into bid;
  sid := public.bk_new_site_id(bn);
  insert into public.bk_sites (id, business_id, name, license_type, license_starts_at, license_expires_at, license_updated_at)
  values (sid, bid, bn, 'trial', now(), now() + public.bk_license_interval('trial'), now());

  -- the owner login
  select id into uid from auth.users where lower(email) = em and not coalesce(is_anonymous, false) order by created_at limit 1;
  if uid is not null then
    existing := true;   -- already has a login (here or on the till): never touch their password
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

  -- Owner of the whole business (all its sites); the trigger syncs bk_staff_invites / bk_staff_profiles.
  insert into public.bk_business_members (business_id, email, user_id, name, role, site_ids, features)
  values (bid, em, uid, nm, 'Owner', '{}', '{}'::jsonb);

  return jsonb_build_object('business_id', bid, 'site_id', sid, 'user_id', uid, 'email', em, 'existing', existing);
end;
$$;
revoke all on function public.bk_add_business(text, text, text, text, text) from public, anon;
grant execute on function public.bk_add_business(text, text, text, text, text) to authenticated;
