-- 010: the master's "+ Add business" can start the business on a 3-day trial (ADD_BUSINESS_D_SPEC, owner decision
-- 11 Nov 2026: "Bring back a trial here only"). Bookings objects only (bk_*): the database is shared with Proview Till.
--
-- Everything else stays no-trial (migration 008): self-signup, bk_add_business itself, bk_add_site and the licence
-- portal's New customer still start with no licence. Only the master, from the Add business dialog, can choose
-- "3-day trial" for a business they have just added; the app calls this straight after bk_add_business.
--
-- Bookings licences are per location (bk_sites.license_type / license_starts_at / license_expires_at), so
-- bk_master_trial(p_business) gives every location of that business that has NO licence yet the existing 'trial'
-- licence type from now to now + 3 days (bk_license_interval('trial')). A location that already has a licence
-- (paid, lifetime, or an earlier trial) is never touched. The app's usual trial handling applies: "Trial ends ..."
-- banner, then the no-licence lock with Buy a licence online when it runs out (no grace days for a trial).
-- bk_sites_no_trial only acts on INSERT, so it does not undo this UPDATE; bk_sites_licence_guard lets it through
-- because this function runs as its owner (security definer).
-- Returns { applied, expires_at, sites } (applied false, expires_at null when nothing was changed).
-- Safe to run more than once.

create or replace function public.bk_master_trial(p_business uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare e timestamptz := now() + public.bk_license_interval('trial'); n int;
begin
  if auth.uid() is null or not public.bk_is_master() then
    raise exception 'Only the Proview administrator can start a trial.';
  end if;
  if not exists (select 1 from public.bk_businesses where id = p_business) then raise exception 'Business not found.'; end if;
  update public.bk_sites
     set license_type = 'trial', license_starts_at = now(), license_expires_at = e, license_updated_at = now(),
         license_notes = '3-day trial started by Proview (Add business)'
   where business_id = p_business and license_type is null and license_expires_at is null;
  get diagnostics n = row_count;
  return jsonb_build_object('applied', n > 0, 'expires_at', case when n > 0 then e end, 'sites', n);
end $$;

revoke all on function public.bk_master_trial(uuid) from public, anon;
grant execute on function public.bk_master_trial(uuid) to authenticated;
