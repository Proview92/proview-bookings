-- "Sign in with Proview account": one-time assertion log (used only by the sso-login edge function).
create table if not exists public.sso_used (
  jti   text primary key,
  email text,
  at    timestamptz not null default now()
);
alter table public.sso_used enable row level security;
revoke all on public.sso_used from public, anon, authenticated;
grant all on public.sso_used to service_role;
-- Who may sign in to Bookings with their Proview account: master admins and Admin/Owner/Manager
-- staff (or someone holding such an invite, whose login is then created). Staff keep their own login.
create or replace function public.sso_entitled(p_email text) returns jsonb
language plpgsql stable security definer set search_path = public, auth as $$
declare uid uuid; em text := lower(trim(p_email));
begin
  select id into uid from auth.users where lower(email) = em order by created_at limit 1;
  if uid is not null then
    if exists (select 1 from public.bk_master_admins where user_id = uid)
       or exists (select 1 from public.bk_staff_profiles where user_id = uid and role in ('Admin','Owner','Manager')) then
      return jsonb_build_object('ok', true, 'user_id', uid);
    end if;
    if exists (select 1 from public.bk_staff_profiles where user_id = uid) then
      return jsonb_build_object('ok', false, 'reason', 'This is a staff login in Bookings. Sign in there with your Bookings email and password.');
    end if;
  end if;
  if exists (select 1 from public.bk_staff_invites where lower(email) = em and role in ('Admin','Owner','Manager')) then
    return jsonb_build_object('ok', true, 'user_id', uid, 'create', uid is null);
  end if;
  return jsonb_build_object('ok', false, 'reason', 'No Proview Bookings account for this email.');
end $$;
revoke all on function public.sso_entitled(text) from public, anon, authenticated;
grant execute on function public.sso_entitled(text) to service_role;
