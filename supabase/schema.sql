-- Proview Bookings: Supabase setup
-- Run this once in Supabase → SQL Editor → New query → Run.

-- 1. Tables ---------------------------------------------------------------

-- The full working data for each venue (bookings, guests, staff, settings).
create table if not exists public.venue_state (
  id          text primary key,            -- venue ID, e.g. 'proview-kitchen'
  data        jsonb not null,
  updated_at  timestamptz not null default now(),
  updated_by  uuid
);

-- A cut-down, guest-safe copy used by the public booking page (no names, emails or phone numbers).
create table if not exists public.venue_public (
  id          text primary key,
  data        jsonb not null,
  updated_at  timestamptz not null default now()
);

-- Requests from guests (online bookings, enquiries, queue joins, sign-ups, cancellations, SMS replies).
create table if not exists public.inbox (
  id          uuid primary key default gen_random_uuid(),
  venue       text not null references public.venue_public(id) on delete cascade,
  kind        text not null check (kind in ('booking','enquiry','queue','signup','cancel','sms')),
  payload     jsonb not null check (octet_length(payload::text) < 8000),
  created_at  timestamptz not null default now(),
  processed   boolean not null default false
);
create index if not exists inbox_venue_open on public.inbox (venue) where not processed;

-- Who may sign in to which venue.
create table if not exists public.staff_invites (
  email  text not null,
  venue  text not null,
  role   text not null default 'Host',
  primary key (email, venue)
);
create table if not exists public.staff_profiles (
  user_id  uuid not null references auth.users(id) on delete cascade,
  venue    text not null,
  role     text not null default 'Host',
  primary key (user_id, venue)
);

-- 2. Staff accounts come from invites ---------------------------------------
create or replace function public.claim_invites() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.staff_profiles (user_id, venue, role)
  select new.id, i.venue, i.role from public.staff_invites i where lower(i.email) = lower(new.email)
  on conflict do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.claim_invites();

create or replace function public.is_staff(v text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff_profiles where user_id = auth.uid() and venue = v)
$$;
create or replace function public.is_admin(v text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff_profiles where user_id = auth.uid() and venue = v and role in ('Admin','Owner','Manager'))
$$;

-- Invites added after someone already has an account still give them access.
create or replace function public.apply_invite() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.staff_profiles (user_id, venue, role)
  select u.id, new.venue, new.role from auth.users u where lower(u.email) = lower(new.email)
  on conflict (user_id, venue) do update set role = excluded.role;
  return new;
end $$;
drop trigger if exists on_invite on public.staff_invites;
create trigger on_invite after insert or update on public.staff_invites
  for each row execute function public.apply_invite();

-- 3. Row level security -----------------------------------------------------
alter table public.venue_state    enable row level security;
alter table public.venue_public   enable row level security;
alter table public.inbox          enable row level security;
alter table public.staff_invites  enable row level security;
alter table public.staff_profiles enable row level security;

drop policy if exists "staff read state"   on public.venue_state;
drop policy if exists "staff write state"  on public.venue_state;
drop policy if exists "staff insert state" on public.venue_state;
create policy "staff read state"   on public.venue_state for select to authenticated using (public.is_staff(id));
create policy "staff insert state" on public.venue_state for insert to authenticated with check (public.is_staff(id));
create policy "staff write state"  on public.venue_state for update to authenticated using (public.is_staff(id)) with check (public.is_staff(id));

drop policy if exists "anyone reads public" on public.venue_public;
drop policy if exists "staff publish"       on public.venue_public;
drop policy if exists "staff republish"     on public.venue_public;
create policy "anyone reads public" on public.venue_public for select to anon, authenticated using (true);
create policy "staff publish"       on public.venue_public for insert to authenticated with check (public.is_staff(id));
create policy "staff republish"     on public.venue_public for update to authenticated using (public.is_staff(id)) with check (public.is_staff(id));

drop policy if exists "guests send requests" on public.inbox;
drop policy if exists "staff read inbox"     on public.inbox;
drop policy if exists "staff update inbox"   on public.inbox;
create policy "guests send requests" on public.inbox for insert to anon, authenticated
  with check (kind in ('booking','enquiry','queue','signup','cancel') and processed = false);
create policy "staff read inbox"     on public.inbox for select to authenticated using (public.is_staff(venue));
create policy "staff update inbox"   on public.inbox for update to authenticated using (public.is_staff(venue));

drop policy if exists "admins manage invites" on public.staff_invites;
create policy "admins manage invites" on public.staff_invites for all to authenticated using (public.is_admin(venue)) with check (public.is_admin(venue));
drop policy if exists "see own profile" on public.staff_profiles;
create policy "see own profile" on public.staff_profiles for select to authenticated using (user_id = auth.uid());

-- Light rate limit on public requests: max 20 per venue per minute.
create or replace function public.inbox_rate_limit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from public.inbox where venue = new.venue and created_at > now() - interval '1 minute') >= 20 then
    raise exception 'Too many requests, please try again in a minute';
  end if;
  return new;
end $$;
drop trigger if exists inbox_rate on public.inbox;
create trigger inbox_rate before insert on public.inbox for each row execute function public.inbox_rate_limit();

-- 4. Live updates -----------------------------------------------------------
alter publication supabase_realtime add table public.venue_state;
alter publication supabase_realtime add table public.inbox;

-- 5. Your first login -------------------------------------------------------
-- Replace the email and venue ID below with yours, then run this line.
-- The venue ID must match the one you type into Proview Bookings → Settings → Integrations → Cloud sync.
insert into public.staff_invites (email, venue, role) values ('you@yourcompany.co.uk', 'proview-kitchen', 'Admin')
on conflict do nothing;
-- The public booking page needs a row to exist before the first publish; the app creates it when you first sign in.
