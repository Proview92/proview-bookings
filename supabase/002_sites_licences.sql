-- =====================================================================
--  PROVIEW BOOKINGS — businesses, sites and licences (master admin)
--  Run once in Supabase → SQL Editor after schema.sql. Safe to re-run.
--  Every object starts with bk_ so it never touches the till's tables.
--
--  • A business (client) has one or more sites (venues). Each site has
--    its own licence: trial (3 days), m1, m3, m6, m12, m24, m36,
--    lifetime or custom. After expiry a paid licence keeps working for a
--    7-day grace period; a trial stops when it ends.
--  • Master admins (Proview) see and manage every business and site.
--  • Anyone can sign up online: they create their business and get one
--    site on a free 3-day trial (once per email address).
-- =====================================================================

-- 1. Tables -------------------------------------------------------------
create table if not exists public.bk_master_admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  email      text,
  created_at timestamptz not null default now()
);

create table if not exists public.bk_businesses (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  contact_email text,
  phone         text,
  notes         text,
  self_signup   boolean not null default false,
  created_at    timestamptz not null default now()
);

create table if not exists public.bk_sites (
  id                 text primary key check (id ~ '^[a-z0-9][a-z0-9-]{1,60}$'),   -- the venue ID used everywhere
  business_id        uuid references public.bk_businesses(id) on delete cascade,
  name               text not null,
  license_type       text check (license_type is null or license_type in ('trial','m1','m3','m6','m12','m24','m36','lifetime','custom')),
  license_starts_at  timestamptz,
  license_expires_at timestamptz,          -- null = lifetime
  license_notes      text,
  license_updated_at timestamptz,
  created_at         timestamptz not null default now()
);
create index if not exists bk_sites_business on public.bk_sites(business_id);

-- 2. Who is who -----------------------------------------------------------
create or replace function public.bk_is_master() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.bk_master_admins where user_id = auth.uid())
$$;

-- Master admins count as staff and admins of every venue.
create or replace function public.bk_is_staff(v text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.bk_is_master()
      or exists (select 1 from public.bk_staff_profiles where user_id = auth.uid() and venue = v)
$$;
create or replace function public.bk_is_admin(v text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.bk_is_master()
      or exists (select 1 from public.bk_staff_profiles where user_id = auth.uid() and venue = v and role in ('Admin','Owner','Manager'))
$$;

-- 3. Licences -------------------------------------------------------------
-- Grace period: 7 days for paid licences (keep in sync with LIC_GRACE in index.html); none for trials.
create or replace function public.bk_license_ok(p_type text, p_expires timestamptz) returns boolean
language sql stable as $$
  select p_type is not null
     and (p_type = 'lifetime' or p_expires is null
          or p_expires + case when p_type = 'trial' then interval '0' else interval '7 days' end > now())
$$;

create or replace function public.bk_license_interval(p_type text) returns interval
language sql immutable as $$
  select case p_type
    when 'trial' then interval '3 days'
    when 'm1'  then interval '1 month'   when 'm3'  then interval '3 months'
    when 'm6'  then interval '6 months'  when 'm12' then interval '12 months'
    when 'm24' then interval '24 months' when 'm36' then interval '36 months'
  end
$$;

-- Is this venue allowed to work (take bookings, save changes)?
create or replace function public.bk_site_ok(p_site text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.bk_sites s where s.id = p_site and public.bk_license_ok(s.license_type, s.license_expires_at))
$$;

-- For the public booking page (no personal data).
create or replace function public.bk_site_status(p_site text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('exists', s.id is not null, 'ok', coalesce(public.bk_license_ok(s.license_type, s.license_expires_at), false))
    from (select 1) x left join public.bk_sites s on s.id = p_site
$$;

-- Master admin: set or extend a site's licence.
create or replace function public.bk_set_license(
  p_site text, p_type text, p_extend boolean default false,
  p_expires timestamptz default null, p_notes text default null)
returns public.bk_sites language plpgsql security definer set search_path = public as $$
declare s public.bk_sites; base timestamptz; new_exp timestamptz;
begin
  if not public.bk_is_master() then raise exception 'Only the Proview administrator can change licences.'; end if;
  select * into s from public.bk_sites where id = p_site for update;
  if not found then raise exception 'Site not found'; end if;
  if p_type = 'lifetime' then new_exp := null;
  elsif p_type = 'custom' then
    if p_expires is null then raise exception 'Choose an end date.'; end if;
    new_exp := p_expires;
  elsif public.bk_license_interval(p_type) is not null then
    base := case when p_extend and coalesce(s.license_type,'') <> 'lifetime'
                      and s.license_expires_at is not null and s.license_expires_at > now()
                 then s.license_expires_at else now() end;
    new_exp := base + public.bk_license_interval(p_type);
  else raise exception 'Unknown licence type %', p_type;
  end if;
  update public.bk_sites
     set license_type = p_type,
         license_starts_at = case when p_extend and s.license_starts_at is not null then s.license_starts_at else now() end,
         license_expires_at = new_exp,
         license_notes = coalesce(nullif(trim(p_notes), ''), license_notes),
         license_updated_at = now()
   where id = p_site returning * into s;
  return s;
end $$;

-- A URL-safe, unique venue ID from a name, e.g. "Bella Pizza" → bella-pizza, bella-pizza-2 …
create or replace function public.bk_new_site_id(p_name text) returns text
language plpgsql security definer set search_path = public as $$
declare base text; cand text; n int := 1;
begin
  base := trim(both '-' from regexp_replace(lower(coalesce(p_name,'')), '[^a-z0-9]+', '-', 'g'));
  base := left(case when length(base) < 2 then 'venue' else base end, 50);
  cand := base;
  while exists (select 1 from public.bk_sites where id = cand) or exists (select 1 from public.bk_venue_state where id = cand) loop
    n := n + 1; cand := base || '-' || n;
  end loop;
  return cand;
end $$;

-- Master admin: add a site to a business. The business contact gets Admin access to it.
create or replace function public.bk_add_site(p_business uuid, p_name text, p_license text default 'trial')
returns public.bk_sites language plpgsql security definer set search_path = public as $$
declare s public.bk_sites; b public.bk_businesses; nm text := left(trim(coalesce(p_name,'')), 80);
begin
  if not public.bk_is_master() then raise exception 'Only the Proview administrator can add sites.'; end if;
  select * into b from public.bk_businesses where id = p_business;
  if not found then raise exception 'Business not found'; end if;
  if length(nm) < 2 then raise exception 'Enter the site name.'; end if;
  insert into public.bk_sites (id, business_id, name) values (public.bk_new_site_id(nm), p_business, nm) returning * into s;
  if p_license is not null then s := public.bk_set_license(s.id, p_license); end if;
  if b.contact_email is not null then
    insert into public.bk_staff_invites (email, venue, role) values (lower(b.contact_email), s.id, 'Admin') on conflict do nothing;
  end if;
  return s;
end $$;

-- Online sign-up: a new account creates its business with one site on a 3-day trial.
create or replace function public.bk_create_my_business(p_business text, p_site text default null, p_phone text default null)
returns text language plpgsql security definer set search_path = public as $$
declare bid uuid; sid text; em text := lower(auth.jwt() ->> 'email');
        bn text := left(trim(coalesce(p_business,'')), 80);
        sn text := left(trim(coalesce(nullif(trim(p_site),''), p_business, '')), 80);
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  if length(bn) < 2 then raise exception 'Please enter your business name.'; end if;
  if exists (select 1 from public.bk_staff_profiles where user_id = auth.uid()) then
    raise exception 'Your account already belongs to a business.';
  end if;
  if exists (select 1 from public.bk_businesses where lower(contact_email) = em and self_signup) then
    raise exception 'This email address has already used its free trial. Call Proview to buy a licence.';
  end if;
  insert into public.bk_businesses (name, contact_email, phone, self_signup, notes)
  values (bn, em, nullif(left(trim(coalesce(p_phone,'')), 30), ''), true, 'Signed up online')
  returning id into bid;
  sid := public.bk_new_site_id(sn);
  insert into public.bk_sites (id, business_id, name, license_type, license_starts_at, license_expires_at, license_updated_at)
  values (sid, bid, sn, 'trial', now(), now() + interval '3 days', now());
  insert into public.bk_staff_invites (email, venue, role) values (em, sid, 'Admin') on conflict (email, venue) do update set role = 'Admin';
  return sid;
end $$;

-- Who am I, and which sites can I open?
create or replace function public.bk_whoami() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'user_id', auth.uid(),
    'email', auth.jwt() ->> 'email',
    'is_master', public.bk_is_master(),
    'sites', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', s.id, 'name', s.name, 'business_id', s.business_id, 'business', b.name,
               'role', coalesce(p.role, case when public.bk_is_master() then 'Admin' end),
               'license_type', s.license_type, 'license_expires_at', s.license_expires_at)
             order by lower(b.name), lower(s.name))
        from public.bk_sites s
        left join public.bk_businesses b on b.id = s.business_id
        left join public.bk_staff_profiles p on p.venue = s.id and p.user_id = auth.uid()
       where public.bk_is_master() or p.user_id is not null), '[]'::jsonb))
$$;

-- Deleting a site removes its bookings data and logins too.
create or replace function public.bk_site_deleted() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  delete from public.bk_venue_state where id = old.id;
  delete from public.bk_venue_public where id = old.id;
  delete from public.bk_staff_profiles where venue = old.id;
  delete from public.bk_staff_invites where venue = old.id;
  return old;
end $$;
drop trigger if exists bk_on_site_delete on public.bk_sites;
create trigger bk_on_site_delete after delete on public.bk_sites for each row execute function public.bk_site_deleted();

-- 4. Row level security ---------------------------------------------------
alter table public.bk_master_admins enable row level security;
alter table public.bk_businesses    enable row level security;
alter table public.bk_sites         enable row level security;

drop policy if exists "master reads masters" on public.bk_master_admins;
create policy "master reads masters" on public.bk_master_admins for select to authenticated using (public.bk_is_master());

drop policy if exists "read businesses" on public.bk_businesses;
drop policy if exists "master writes businesses" on public.bk_businesses;
create policy "read businesses" on public.bk_businesses for select to authenticated
  using (public.bk_is_master() or exists (select 1 from public.bk_sites s where s.business_id = bk_businesses.id and public.bk_is_staff(s.id)));
create policy "master writes businesses" on public.bk_businesses for all to authenticated
  using (public.bk_is_master()) with check (public.bk_is_master());

drop policy if exists "read sites" on public.bk_sites;
drop policy if exists "master writes sites" on public.bk_sites;
create policy "read sites" on public.bk_sites for select to authenticated using (public.bk_is_staff(id));
create policy "master writes sites" on public.bk_sites for all to authenticated
  using (public.bk_is_master()) with check (public.bk_is_master());

-- Master admins can see every login (for user counts).
drop policy if exists "master sees profiles" on public.bk_staff_profiles;
create policy "master sees profiles" on public.bk_staff_profiles for select to authenticated using (public.bk_is_master());

-- Enforcement: an unlicensed venue can't save changes or take online requests.
drop policy if exists "staff insert state" on public.bk_venue_state;
drop policy if exists "staff write state"  on public.bk_venue_state;
create policy "staff insert state" on public.bk_venue_state for insert to authenticated
  with check (public.bk_is_staff(id) and (public.bk_is_master() or public.bk_site_ok(id)));
create policy "staff write state" on public.bk_venue_state for update to authenticated
  using (public.bk_is_staff(id)) with check (public.bk_is_staff(id) and (public.bk_is_master() or public.bk_site_ok(id)));

drop policy if exists "guests send requests" on public.bk_inbox;
create policy "guests send requests" on public.bk_inbox for insert to anon, authenticated
  with check (kind in ('booking','enquiry','queue','signup','cancel') and processed = false and public.bk_site_ok(venue));

-- 5. Access ----------------------------------------------------------------
grant select on public.bk_master_admins to authenticated;
grant select, insert, update, delete on public.bk_businesses, public.bk_sites to authenticated;
grant all on public.bk_master_admins, public.bk_businesses, public.bk_sites to service_role;
revoke all on function public.bk_set_license(text, text, boolean, timestamptz, text) from public, anon;
revoke all on function public.bk_add_site(uuid, text, text) from public, anon;
revoke all on function public.bk_create_my_business(text, text, text) from public, anon;
revoke all on function public.bk_new_site_id(text) from public, anon, authenticated;
grant execute on function public.bk_set_license(text, text, boolean, timestamptz, text) to authenticated;
grant execute on function public.bk_add_site(uuid, text, text) to authenticated;
grant execute on function public.bk_create_my_business(text, text, text) to authenticated;
grant execute on function public.bk_whoami() to authenticated;
grant execute on function public.bk_is_master() to authenticated;
grant execute on function public.bk_site_ok(text) to anon, authenticated;
grant execute on function public.bk_site_status(text) to anon, authenticated;
grant execute on function public.bk_license_ok(text, timestamptz) to anon, authenticated;

-- 6. Existing data ----------------------------------------------------------
-- Proview's own venue keeps working with a lifetime licence.
insert into public.bk_businesses (id, name, contact_email, notes)
select '00000000-0000-4000-8000-000000000001', 'Proview Kitchen', 'altun@proviewtech.co.uk', 'Proview demo venue'
where not exists (select 1 from public.bk_businesses where id = '00000000-0000-4000-8000-000000000001');
insert into public.bk_sites (id, business_id, name, license_type, license_starts_at, license_expires_at, license_updated_at)
values ('proview-kitchen', '00000000-0000-4000-8000-000000000001', 'Proview Kitchen', 'lifetime', now(), null, now())
on conflict (id) do nothing;

-- The master admin (Proview). Add more with the same line and another email.
insert into public.bk_master_admins (user_id, email)
select id, email from auth.users where lower(email) = 'altun@proviewtech.co.uk'
on conflict (user_id) do nothing;
