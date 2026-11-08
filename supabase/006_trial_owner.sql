-- =====================================================================
-- 006: 3-day free trial self-signup makes the creator the business Owner
-- (TRIAL_SPEC, 8 Nov 2026). Touches only bk_* objects.
--
-- Before: bk_create_my_business added an 'Admin' invite, so the creator became an Admin member.
-- Now:    the creator is added straight to bk_business_members as 'Owner'. The members trigger
--         (bk_members_after -> bk_sync_member) then writes the per-venue invite/profile rows with
--         role 'Owner', so whoami, RLS and the edge functions all see an Owner.
-- Unchanged: one trial per email (bk_businesses.self_signup + contact_email), refuses people who
--         already belong to a business or have an invite/membership, trial = existing 'trial'
--         licence on the site ending now() + 3 days.
-- =====================================================================

create or replace function public.bk_create_my_business(p_business text, p_site text default null, p_phone text default null)
returns text language plpgsql security definer set search_path = public as $$
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
  if exists (select 1 from public.bk_businesses where lower(contact_email) = em and self_signup) then
    raise exception 'This email address has already used its free trial. Buy a licence at license.proviewcrm.co.uk or call Proview on 020 8935 5495.';
  end if;
  insert into public.bk_businesses (name, contact_email, phone, self_signup, notes)
  values (bn, em, nullif(left(trim(coalesce(p_phone,'')), 30), ''), true, 'Signed up online')
  returning id into bid;
  sid := public.bk_new_site_id(sn);
  insert into public.bk_sites (id, business_id, name, license_type, license_starts_at, license_expires_at, license_updated_at)
  values (sid, bid, sn, 'trial', now(), now() + interval '3 days', now());
  -- Owner of the whole business (all sites); the trigger syncs bk_staff_invites / bk_staff_profiles.
  insert into public.bk_business_members (business_id, email, user_id, name, role, site_ids, features)
  values (bid, em, auth.uid(), null, 'Owner', '{}', '{}'::jsonb);
  return sid;
end $$;

revoke all on function public.bk_create_my_business(text, text, text) from public, anon;
grant execute on function public.bk_create_my_business(text, text, text) to authenticated;
