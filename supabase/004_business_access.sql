-- =====================================================================
--  PROVIEW BOOKINGS: business-level access, per-site scope and feature switches
--  Run after 002_sites_licences.sql. Safe to re-run. Only bk_* objects.
--
--  • bk_business_members: one row per person per business (keyed by email, linked to the login).
--      Owner / Admin   → every site of the business (including sites added later), every feature,
--                        can manage users.
--      Manager         → only the sites in site_ids. Can manage Host/Viewer logins on those sites
--                        unless features.users = false.
--      Host / Viewer   → (Staff) only the sites in site_ids.
--    features: {"campaigns":false,...}. A missing key = the role's default (see bk_feature_default),
--    which is what the person could do before this change, so nobody loses access on deploy.
--  • When a member row exists for a business it decides that person's access there. The older
--    per-venue bk_staff_profiles / bk_staff_invites rows are kept in step automatically, so the edge
--    functions, "Sign in with Proview account" and older app versions keep working.
--  • Feature switches are enforced in the database: the venue inbox, campaigns, user management,
--    and a guard on bk_venue_state that keeps the parts of the venue data a person isn't allowed to
--    change (their change is undone and the original wins on every device).
--
--  Feature keys (keep in step with FEATURES in index.html):
--    bookings   Bookings, Table status, Timeline, Floor view (bookings and walk-ins)
--    enquiries  Group enquiries
--    queue      Queue / waitlist
--    messages   Guest messages (two-way texts)
--    guests     Guests & marketing page (guest book, occasions, tags, sign-up form)
--    campaigns  Email campaigns
--    reviews    Reviews
--    preorders  Pre-orders (and menus)
--    reports    Insights
--    staff      Staff & rota (team, shifts, checklists)
--    kitchen    Kitchen screen
--    settings   Settings (venue details, hours, floor plan, booking rules, types, templates)
--    users      Users (invite people, set role, sites and features)
-- =====================================================================

-- 1. Members ---------------------------------------------------------------
create table if not exists public.bk_business_members (
  business_id uuid not null references public.bk_businesses(id) on delete cascade,
  email       text not null check (email = lower(email) and email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  user_id     uuid references auth.users(id) on delete set null,
  name        text,
  role        text not null default 'Host' check (role in ('Owner','Admin','Manager','Host','Viewer')),
  site_ids    text[] not null default '{}',
  features    jsonb not null default '{}'::jsonb check (jsonb_typeof(features) = 'object'),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  updated_by  uuid,
  primary key (business_id, email)
);
create index if not exists bk_business_members_user on public.bk_business_members(user_id);
alter table public.bk_business_members enable row level security;

create or replace function public.bk_role_rank(r text) returns int language sql immutable as $$
  select case r when 'Owner' then 5 when 'Admin' then 4 when 'Manager' then 3 when 'Host' then 2 when 'Viewer' then 1 else 0 end $$;

create or replace function public.bk_norm_role(r text) returns text language sql immutable as $$
  select case when r in ('Owner','Admin','Manager','Host','Viewer') then r else 'Host' end $$;

create or replace function public.bk_feature_keys() returns text[] language sql immutable as $$
  select array['bookings','enquiries','queue','messages','guests','campaigns','reviews','preorders','reports','staff','kitchen','settings','users'] $$;

-- What a role gets when its features object has no entry for a feature (= behaviour before this change).
create or replace function public.bk_feature_default(p_role text, p_feature text) returns boolean language sql immutable as $$
  select case
    when p_role in ('Owner','Admin','Manager') then true
    else p_feature not in ('users','campaigns') end $$;     -- staff could never manage logins or campaigns

-- 2. Who has access to a site, as what --------------------------------------
-- {role, features, via} for the signed-in person at site v, or null. Master is handled by callers.
create or replace function public.bk_access(v text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare b uuid; m public.bk_business_members; p public.bk_staff_profiles;
begin
  if auth.uid() is null then return null; end if;
  select s.business_id into b from public.bk_sites s where s.id = v;
  if b is not null then
    select * into m from public.bk_business_members where business_id = b and user_id = auth.uid();
    if found then
      if m.role in ('Owner','Admin') or v = any(m.site_ids) then
        return jsonb_build_object('role', m.role, 'features', m.features, 'via', 'member');
      end if;
      return null;                                   -- the member row decides for this business
    end if;
  end if;
  select * into p from public.bk_staff_profiles where user_id = auth.uid() and venue = v;
  if found then return jsonb_build_object('role', p.role, 'features', '{}'::jsonb, 'via', 'profile'); end if;
  return null;
end $$;

create or replace function public.bk_is_staff(v text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.bk_is_master() or public.bk_access(v) is not null $$;

-- Unchanged meaning: Owner, Admin or Manager of this venue (Manager only on their own sites).
create or replace function public.bk_is_admin(v text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.bk_is_master() or coalesce(public.bk_access(v) ->> 'role', '') in ('Admin','Owner','Manager') $$;

create or replace function public.bk_has_feature(v text, f text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare a jsonb;
begin
  if auth.uid() is null then return false; end if;
  if public.bk_is_master() then return true; end if;
  a := public.bk_access(v);
  if a is null then return false; end if;
  if a ->> 'role' in ('Owner','Admin') then return true; end if;
  return coalesce((a -> 'features' ->> f)::boolean, public.bk_feature_default(a ->> 'role', f));
exception when invalid_text_representation then
  return public.bk_feature_default(a ->> 'role', f);
end $$;

-- The signed-in person's role in a business ('Master' for Proview), or null.
create or replace function public.bk_business_role(b uuid) returns text
language plpgsql stable security definer set search_path = public as $$
declare r text;
begin
  if auth.uid() is null then return null; end if;
  if public.bk_is_master() then return 'Master'; end if;
  select role into r from public.bk_business_members where business_id = b and user_id = auth.uid();
  if found then return r; end if;
  select p.role into r from public.bk_staff_profiles p join public.bk_sites s on s.id = p.venue
   where p.user_id = auth.uid() and s.business_id = b order by public.bk_role_rank(p.role) desc limit 1;
  return r;
end $$;

create or replace function public.bk_can_manage_users(b uuid) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare r text; m public.bk_business_members;
begin
  r := public.bk_business_role(b);
  if r in ('Master','Owner','Admin') then return true; end if;
  if r = 'Manager' then
    select * into m from public.bk_business_members where business_id = b and user_id = auth.uid();
    if not found then return true; end if;            -- legacy Manager profile: could manage invites before
    return coalesce((m.features ->> 'users')::boolean, true);
  end if;
  return false;
end $$;

-- 3. Keep the older per-venue rows in step ----------------------------------
-- Makes bk_staff_invites / bk_staff_profiles for this person match their member row
-- (used by the edge functions, Proview sign-in and older app versions).
create or replace function public.bk_sync_member(p_business uuid, p_email text) returns void
language plpgsql security definer set search_path = public as $$
declare m public.bk_business_members; targets text[]; em text := lower(p_email); uid uuid;
begin
  perform set_config('bk.sync', '1', true);
  select * into m from public.bk_business_members where business_id = p_business and email = em;
  if not found then targets := '{}';
  elsif m.role in ('Owner','Admin') then select coalesce(array_agg(id), '{}') into targets from public.bk_sites where business_id = p_business;
  else select coalesce(array_agg(id), '{}') into targets from public.bk_sites where business_id = p_business and id = any(m.site_ids);
  end if;
  select id into uid from auth.users where lower(email) = em order by created_at limit 1;
  delete from public.bk_staff_invites i using public.bk_sites s
   where s.id = i.venue and s.business_id = p_business and lower(i.email) = em and not (i.venue = any(targets));
  if uid is not null then
    delete from public.bk_staff_profiles p using public.bk_sites s
     where s.id = p.venue and s.business_id = p_business and p.user_id = uid and not (p.venue = any(targets));
  end if;
  if m.email is not null and cardinality(targets) > 0 then
    insert into public.bk_staff_invites (email, venue, role) select em, t, m.role from unnest(targets) t
    on conflict (email, venue) do update set role = excluded.role where public.bk_staff_invites.role is distinct from excluded.role;
    if uid is not null then   -- bk_apply_invite only fires on real changes
      insert into public.bk_staff_profiles (user_id, venue, role) select uid, t, m.role from unnest(targets) t
      on conflict (user_id, venue) do update set role = excluded.role where public.bk_staff_profiles.role is distinct from excluded.role;
    end if;
  end if;
  perform set_config('bk.sync', '', true);
end $$;

create or replace function public.bk_members_before() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.email := lower(trim(new.email));
  if new.user_id is null then select id into new.user_id from auth.users where lower(email) = new.email order by created_at limit 1; end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists bk_members_before on public.bk_business_members;
create trigger bk_members_before before insert or update on public.bk_business_members
  for each row execute function public.bk_members_before();

create or replace function public.bk_members_after() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('bk.sync', true), '') = '1' then return null; end if;
  if tg_op = 'DELETE' then perform public.bk_sync_member(old.business_id, old.email);
  else perform public.bk_sync_member(new.business_id, new.email); end if;
  return null;
end $$;
drop trigger if exists bk_members_after on public.bk_business_members;
create trigger bk_members_after after insert or update or delete on public.bk_business_members
  for each row execute function public.bk_members_after();

-- An invite made the old way (older app, sign-up, master adding a site) adds that site to the person's membership.
create or replace function public.bk_invite_to_member() returns trigger
language plpgsql security definer set search_path = public as $$
declare b uuid;
begin
  if coalesce(current_setting('bk.sync', true), '') = '1' then return new; end if;
  select business_id into b from public.bk_sites where id = new.venue;
  if b is null then return new; end if;
  insert into public.bk_business_members (business_id, email, role, site_ids)
  values (b, lower(new.email), public.bk_norm_role(new.role), array[new.venue])
  on conflict (business_id, email) do update
    set site_ids = case when new.venue = any(public.bk_business_members.site_ids) then public.bk_business_members.site_ids
                        else public.bk_business_members.site_ids || new.venue end;
  return new;
end $$;
drop trigger if exists bk_on_invite_member on public.bk_staff_invites;
create trigger bk_on_invite_member after insert on public.bk_staff_invites
  for each row execute function public.bk_invite_to_member();

-- New sites (or sites moved to another business): Owners/Admins get them automatically.
create or replace function public.bk_site_members() returns trigger
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if tg_op = 'UPDATE' and new.business_id is not distinct from old.business_id then return null; end if;
  for r in select business_id, email from public.bk_business_members
            where business_id = new.business_id and role in ('Owner','Admin')
               or (tg_op = 'UPDATE' and business_id = old.business_id) loop
    perform public.bk_sync_member(r.business_id, r.email);
  end loop;
  return null;
end $$;
drop trigger if exists bk_on_site_members on public.bk_sites;
create trigger bk_on_site_members after insert or update of business_id on public.bk_sites
  for each row execute function public.bk_site_members();

-- Deleting a site also takes it off everyone's site list.
create or replace function public.bk_site_deleted() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  delete from public.bk_venue_state where id = old.id;
  delete from public.bk_venue_public where id = old.id;
  delete from public.bk_staff_profiles where venue = old.id;
  delete from public.bk_staff_invites where venue = old.id;
  perform set_config('bk.sync', '1', true);
  update public.bk_business_members set site_ids = array_remove(site_ids, old.id) where old.id = any(site_ids);
  perform set_config('bk.sync', '', true);
  return old;
end $$;

-- New logins pick up their invites and memberships.
create or replace function public.bk_claim_invites() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.bk_staff_profiles (user_id, venue, role)
  select new.id, i.venue, i.role from public.bk_staff_invites i where lower(i.email) = lower(new.email)
  on conflict do nothing;
  perform set_config('bk.sync', '1', true);
  update public.bk_business_members set user_id = new.id where email = lower(new.email) and user_id is null;
  perform set_config('bk.sync', '', true);
  return new;
end $$;

-- 4. Existing people become members (nobody loses access) -------------------
insert into public.bk_business_members (business_id, email, user_id, role, site_ids)
select s.business_id, lower(u.email), p.user_id,
       (array_agg(p.role order by public.bk_role_rank(p.role) desc))[1],
       array_agg(distinct p.venue)
  from public.bk_staff_profiles p join public.bk_sites s on s.id = p.venue join auth.users u on u.id = p.user_id
 where s.business_id is not null and u.email is not null
 group by s.business_id, lower(u.email), p.user_id
on conflict (business_id, email) do nothing;
insert into public.bk_business_members (business_id, email, role, site_ids)
select s.business_id, lower(i.email), public.bk_norm_role((array_agg(i.role order by public.bk_role_rank(i.role) desc))[1]), array_agg(distinct i.venue)
  from public.bk_staff_invites i join public.bk_sites s on s.id = i.venue
 where s.business_id is not null
 group by s.business_id, lower(i.email)
on conflict (business_id, email) do nothing;

-- 5. Users page (RPC only: nobody writes the table directly) ----------------
create or replace function public.bk_list_members(p_business uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r text; me public.bk_business_members;
begin
  if not public.bk_can_manage_users(p_business) then raise exception 'Only owners and admins can manage users.'; end if;
  r := public.bk_business_role(p_business);
  select * into me from public.bk_business_members where business_id = p_business and user_id = auth.uid();
  return jsonb_build_object(
    'my_role', r,
    'sites', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name) order by lower(s.name))
                        from public.bk_sites s where s.business_id = p_business
                         and (r <> 'Manager' or me.email is null or s.id = any(me.site_ids))), '[]'::jsonb),
    'members', coalesce((select jsonb_agg(jsonb_build_object('email', m.email, 'name', m.name, 'role', m.role, 'site_ids', m.site_ids,
                                  'features', m.features, 'joined', m.user_id is not null, 'me', m.user_id = auth.uid()) order by public.bk_role_rank(m.role) desc, m.email)
                         from public.bk_business_members m where m.business_id = p_business
                          and (r <> 'Manager' or m.user_id = auth.uid() or (m.role in ('Host','Viewer') and (me.email is null or m.site_ids && me.site_ids)))), '[]'::jsonb));
end $$;

create or replace function public.bk_save_member(p_business uuid, p_email text, p_role text, p_site_ids text[], p_features jsonb, p_name text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r text; em text := lower(trim(coalesce(p_email,''))); me public.bk_business_members; t public.bk_business_members;
        sites text[]; feats jsonb := '{}'::jsonb; k text; v jsonb; out public.bk_business_members;
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  if not public.bk_can_manage_users(p_business) then raise exception 'Only owners and admins can manage users.'; end if;
  if em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a valid email address.'; end if;
  if p_role not in ('Owner','Admin','Manager','Host','Viewer') then raise exception 'Choose a role.'; end if;
  if not public.bk_is_master() and em = lower(coalesce(auth.jwt() ->> 'email', '')) then raise exception 'You can''t change your own access. Ask another owner or admin.'; end if;
  r := public.bk_business_role(p_business);
  select * into me from public.bk_business_members where business_id = p_business and user_id = auth.uid();
  select * into t from public.bk_business_members where business_id = p_business and email = em;
  if t.user_id is not null and t.user_id = auth.uid() and r <> 'Master' then raise exception 'You can''t change your own access.'; end if;
  if r = 'Admin' and (p_role = 'Owner' or t.role = 'Owner') then raise exception 'Only an owner can add or change owners.'; end if;
  if r = 'Manager' and (p_role not in ('Host','Viewer') or coalesce(t.role, 'Host') not in ('Host','Viewer')) then
    raise exception 'Managers can only add and change staff logins.';
  end if;
  -- sites: only this business's, and a manager only their own
  select coalesce(array_agg(distinct s.id), '{}') into sites from public.bk_sites s
   where s.business_id = p_business and s.id = any(coalesce(p_site_ids, '{}'))
     and (r <> 'Manager' or me.email is null or s.id = any(me.site_ids));
  if r = 'Manager' and t.email is not null then      -- keep the target's sites the manager can't see
    sites := sites || coalesce((select array_agg(x) from unnest(t.site_ids) x where me.email is not null and not (x = any(me.site_ids))), '{}');
  end if;
  if p_role not in ('Owner','Admin') then
    if jsonb_typeof(coalesce(p_features, '{}'::jsonb)) <> 'object' then raise exception 'features must be an object'; end if;
    for k, v in select * from jsonb_each(coalesce(p_features, '{}'::jsonb)) loop
      if k = any(public.bk_feature_keys()) and jsonb_typeof(v) = 'boolean' then
        -- a manager can't hand out what they don't have
        if r = 'Manager' and me.email is not null and v = 'true'::jsonb
           and not coalesce((me.features ->> k)::boolean, public.bk_feature_default('Manager', k)) then v := 'false'::jsonb; end if;
        feats := feats || jsonb_build_object(k, v);
      end if;
    end loop;
  end if;
  insert into public.bk_business_members as m (business_id, email, name, role, site_ids, features, updated_by)
  values (p_business, em, nullif(left(trim(coalesce(p_name,'')), 80), ''), p_role, case when p_role in ('Owner','Admin') then '{}' else sites end, feats, auth.uid())
  on conflict (business_id, email) do update
    set name = coalesce(excluded.name, m.name), role = excluded.role, site_ids = excluded.site_ids,
        features = excluded.features, updated_by = excluded.updated_by
  returning * into out;
  return to_jsonb(out);
end $$;

create or replace function public.bk_remove_member(p_business uuid, p_email text) returns void
language plpgsql security definer set search_path = public as $$
declare r text; em text := lower(trim(coalesce(p_email,''))); me public.bk_business_members; t public.bk_business_members;
begin
  if not public.bk_can_manage_users(p_business) then raise exception 'Only owners and admins can manage users.'; end if;
  r := public.bk_business_role(p_business);
  select * into t from public.bk_business_members where business_id = p_business and email = em;
  if not found then return; end if;
  if r <> 'Master' and (t.user_id = auth.uid() or em = lower(coalesce(auth.jwt() ->> 'email', ''))) then raise exception 'You can''t remove yourself.'; end if;
  if r = 'Admin' and t.role = 'Owner' then raise exception 'Only an owner can remove an owner.'; end if;
  if r = 'Manager' then
    select * into me from public.bk_business_members where business_id = p_business and user_id = auth.uid();
    if t.role not in ('Host','Viewer') then raise exception 'Managers can only remove staff logins.'; end if;
    if me.email is not null and not (t.site_ids <@ me.site_ids) then raise exception 'This person also works at sites you don''t manage.'; end if;
  end if;
  delete from public.bk_business_members where business_id = p_business and email = em;   -- trigger removes their venue logins
end $$;

drop policy if exists "bk members read" on public.bk_business_members;
create policy "bk members read" on public.bk_business_members for select to authenticated
  using (user_id = auth.uid() or public.bk_is_master() or public.bk_business_role(business_id) in ('Owner','Admin'));
revoke all on public.bk_business_members from anon, authenticated;
grant select on public.bk_business_members to authenticated;
grant all on public.bk_business_members to service_role;

-- 6. Who am I: now with business role and features per site ----------------
create or replace function public.bk_whoami() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare is_m boolean := public.bk_is_master();
begin
  if auth.uid() is null then return null; end if;
  return jsonb_build_object(
    'user_id', auth.uid(),
    'email', auth.jwt() ->> 'email',
    'is_master', is_m,
    'feature_keys', to_jsonb(public.bk_feature_keys()),
    'sites', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', s.id, 'name', s.name, 'business_id', s.business_id, 'business', b.name,
               'role', case when is_m then coalesce(x.a ->> 'role', 'Admin') else x.a ->> 'role' end,
               'features', (select jsonb_object_agg(f, public.bk_has_feature(s.id, f)) from unnest(public.bk_feature_keys()) f),
               'license_type', s.license_type, 'license_expires_at', s.license_expires_at)
             order by lower(b.name), lower(s.name))
        from public.bk_sites s
        left join public.bk_businesses b on b.id = s.business_id
        cross join lateral (select public.bk_access(s.id) a) x
       where is_m or x.a is not null), '[]'::jsonb),
    'businesses', coalesce((
      select jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name, 'role', public.bk_business_role(b.id),
                                          'can_manage_users', public.bk_can_manage_users(b.id)) order by lower(b.name))
        from public.bk_businesses b
       where (not is_m and (exists (select 1 from public.bk_business_members m where m.business_id = b.id and m.user_id = auth.uid())
                            or exists (select 1 from public.bk_sites s where s.business_id = b.id and public.bk_access(s.id) is not null)))
          or (is_m and exists (select 1 from public.bk_sites s where s.business_id = b.id))), '[]'::jsonb));
end $$;

-- Someone already invited to a business can't start a separate trial business by accident.
create or replace function public.bk_create_my_business(p_business text, p_site text default null, p_phone text default null)
returns text language plpgsql security definer set search_path = public as $$
declare bid uuid; sid text; em text := lower(auth.jwt() ->> 'email');
        bn text := left(trim(coalesce(p_business,'')), 80);
        sn text := left(trim(coalesce(nullif(trim(p_site),''), p_business, '')), 80);
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  if length(bn) < 2 then raise exception 'Please enter your business name.'; end if;
  if exists (select 1 from public.bk_staff_profiles where user_id = auth.uid())
     or exists (select 1 from public.bk_business_members where user_id = auth.uid() or email = em) then
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

-- 7. Feature checks on the server ------------------------------------------
-- Inbox: which feature handles each kind of guest request.
create or replace function public.bk_inbox_feature(p_kind text) returns text language sql immutable as $$
  select case p_kind when 'booking' then 'bookings' when 'cancel' then 'bookings' when 'enquiry' then 'enquiries'
                     when 'queue' then 'queue' when 'signup' then 'guests' when 'sms' then 'messages' else 'bookings' end $$;

drop policy if exists "staff read inbox"   on public.bk_inbox;
drop policy if exists "staff update inbox" on public.bk_inbox;
create policy "staff read inbox" on public.bk_inbox for select to authenticated
  using (public.bk_is_staff(venue) and public.bk_has_feature(venue, public.bk_inbox_feature(kind)));
create policy "staff update inbox" on public.bk_inbox for update to authenticated
  using (public.bk_is_staff(venue) and public.bk_has_feature(venue, public.bk_inbox_feature(kind)))
  with check (public.bk_is_staff(venue) and public.bk_has_feature(venue, public.bk_inbox_feature(kind)));

-- Campaigns: managers and above with the campaigns feature.
drop policy if exists bk_campaigns_read on public.bk_campaigns;
drop policy if exists bk_campaigns_add  on public.bk_campaigns;
drop policy if exists bk_campaigns_edit on public.bk_campaigns;
drop policy if exists bk_campaigns_del  on public.bk_campaigns;
create policy bk_campaigns_read on public.bk_campaigns for select to authenticated
  using (public.bk_is_admin(venue) and public.bk_has_feature(venue, 'campaigns'));
create policy bk_campaigns_add on public.bk_campaigns for insert to authenticated
  with check (public.bk_is_admin(venue) and public.bk_has_feature(venue, 'campaigns') and status = 'draft');
create policy bk_campaigns_edit on public.bk_campaigns for update to authenticated
  using (public.bk_is_admin(venue) and public.bk_has_feature(venue, 'campaigns') and status in ('draft','scheduled'))
  with check (public.bk_is_admin(venue) and public.bk_has_feature(venue, 'campaigns') and status in ('draft','scheduled','cancelled'));
create policy bk_campaigns_del on public.bk_campaigns for delete to authenticated
  using (public.bk_is_admin(venue) and public.bk_has_feature(venue, 'campaigns') and status = 'draft');
drop policy if exists bk_campaign_rcpt_read on public.bk_campaign_recipients;
create policy bk_campaign_rcpt_read on public.bk_campaign_recipients for select to authenticated
  using (public.bk_is_admin(venue) and public.bk_has_feature(venue, 'campaigns'));
drop policy if exists bk_unsub_read on public.bk_unsubscribes;
create policy bk_unsub_read on public.bk_unsubscribes for select to authenticated
  using (public.bk_is_admin(venue) and public.bk_has_feature(venue, 'campaigns'));
create or replace function public.bk_campaign_stats(p_venue text)
 returns table(campaign_id uuid, total integer, sent integer, failed integer, skipped integer, pending integer, opened integer, clicked integer, unsubscribed integer)
 language sql stable security definer set search_path = public as $$
  select r.campaign_id, count(*)::int,
    count(*) filter (where r.status = 'sent')::int, count(*) filter (where r.status = 'failed')::int,
    count(*) filter (where r.status = 'skipped')::int, count(*) filter (where r.status = 'pending')::int,
    count(r.opened_at)::int, count(r.clicked_at)::int, count(r.unsub_at)::int
  from public.bk_campaign_recipients r
  where r.venue = p_venue and public.bk_is_admin(p_venue) and public.bk_has_feature(p_venue, 'campaigns')
  group by r.campaign_id $$;

-- Old-style invites: needs the users feature, can't touch your own login, only owners/admins hand out Owner/Admin.
drop policy if exists "admins manage invites" on public.bk_staff_invites;
create policy "admins manage invites" on public.bk_staff_invites for all to authenticated
  using (public.bk_is_admin(venue) and public.bk_has_feature(venue, 'users'))
  with check (public.bk_is_admin(venue) and public.bk_has_feature(venue, 'users')
              and (public.bk_is_master() or (lower(email) <> lower(coalesce(auth.jwt() ->> 'email', ''))
                   and (role not in ('Owner','Admin') or coalesce(public.bk_access(venue) ->> 'role', '') in ('Owner','Admin')))));

-- 8. Venue data guard -------------------------------------------------------
-- The venue's working data is one JSON document that every device merges (items carry _u stamps,
-- deletions go in _del, other keys use _m stamps). For a person without a feature, the parts that
-- belong to it are put back as they were, stamped newer so the original wins on every device, and
-- _g is stamped so the app knows to reload.
create or replace function public.bk_guard_prot(x jsonb, kinds text[]) returns boolean language sql immutable as $$
  select kinds is null or coalesce(x ->> 'kind', 'booking') = any(kinds) $$;

create or replace function public.bk_guard_items(o jsonb, n jsonb, kinds text[], ms bigint, od_del jsonb, nd_del jsonb, dedup_src boolean)
returns jsonb language plpgsql stable set search_path = public as $$
declare res jsonb; del jsonb := coalesce(nd_del, '{}'::jsonb); odd jsonb := coalesce(od_del, '{}'::jsonb); iid text;
begin
  if o is null or jsonb_typeof(o) <> 'array' then o := '[]'::jsonb; end if;
  if n is null or jsonb_typeof(n) <> 'array' then n := '[]'::jsonb; end if;
  with ol as (select distinct on (x ->> 'id') x, x ->> 'id' id from jsonb_array_elements(o) x where x ? 'id' order by x ->> 'id'),
       nl as (select t.x, t.x ->> 'id' id, t.ord from jsonb_array_elements(n) with ordinality t(x, ord)),
       j  as (select nl.ord, nl.id, nl.x nx, ol.x ox,
                     (ol.x is not null and public.bk_guard_prot(ol.x, kinds)) po, public.bk_guard_prot(nl.x, kinds) pn
                from nl left join ol on ol.id = nl.id),
       kept as (select ord, id,
                  case when po then
                         case when (ox - '_u' - 'guest') = (nx - '_u' - 'guest') then
                                case when (ox -> 'guest') is not distinct from (nx -> 'guest') then ox
                                     else ox || jsonb_build_object('guest', nx -> 'guest', '_u', ms) end
                              else ox || jsonb_build_object('_u', ms) end
                       when pn then case when ox is not null then ox || jsonb_build_object('_u', ms) end
                       else nx end v,
                  (po and (ox - '_u' - 'guest') <> (nx - '_u' - 'guest')) or (not po and pn) rev,
                  (not po and pn and ox is null) dropped
                from j),
       gone as (select ol.id, ol.x,
                  (dedup_src and ol.x ->> 'src' is not null and exists (select 1 from nl where nl.x ->> 'src' = ol.x ->> 'src')) dedup
                from ol where public.bk_guard_prot(ol.x, kinds) and not exists (select 1 from nl where nl.id = ol.id))
  select jsonb_build_object(
           'arr', coalesce((select jsonb_agg(v order by ord) from kept where v is not null), '[]'::jsonb)
               || coalesce((select jsonb_agg(x || jsonb_build_object('_u', ms)) from gone where not dedup), '[]'::jsonb),
           'changed', exists (select 1 from kept where rev) or exists (select 1 from gone where not dedup),
           'drops', coalesce((select jsonb_agg(id) from kept where dropped and id is not null), '[]'::jsonb),
           'prot', coalesce((select jsonb_agg(ol.id) from ol where public.bk_guard_prot(ol.x, kinds)
                              and not exists (select 1 from gone where gone.id = ol.id and gone.dedup)), '[]'::jsonb))
    into res;
  for iid in select jsonb_array_elements_text(res -> 'drops') loop del := del || jsonb_build_object(iid, ms); end loop;
  for iid in select jsonb_array_elements_text(res -> 'prot') loop        -- nobody can tombstone what they can't change
    if odd ? iid then del := del || jsonb_build_object(iid, odd -> iid); else del := del - iid; end if;
  end loop;
  return jsonb_build_object('arr', res -> 'arr', 'del', del, 'changed', (res ->> 'changed')::boolean);
end $$;

create or replace function public.bk_venue_state_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare a jsonb; od jsonb; nd jsonb; ms bigint; del jsonb; mm jsonb; changed boolean := false; r jsonb;
        kinds text[] := '{}'; k text; f text; pair text[]; os jsonb; ns jsonb; ov jsonb; nv jsonb;
        has_settings boolean; has_users boolean;
        id_keys text[][] := array[['staff','staff'],['shifts','staff'],['taskTemplates','staff'],['reviews','reviews'],['chats','messages'],
                                  ['menus','preorders'],['types','settings'],['schedules','settings'],['overrides','settings'],['combos','settings'],
                                  ['decor','settings'],['guestTags','settings'],['partyTags','settings']];
        plain_keys text[][] := array[['areas','settings'],['quickReplies','settings'],['signup','guests']];
begin
  if tg_op <> 'UPDATE' or auth.uid() is null or public.bk_is_master() then return new; end if;
  a := public.bk_access(new.id);
  if a is null or a ->> 'role' in ('Owner','Admin') then return new; end if;   -- RLS refuses strangers
  od := coalesce(old.data, '{}'::jsonb); nd := coalesce(new.data, '{}'::jsonb);
  if jsonb_typeof(nd) <> 'object' or jsonb_typeof(od) <> 'object' then return new; end if;
  ms := (extract(epoch from clock_timestamp()) * 1000)::bigint;
  del := case when jsonb_typeof(nd -> '_del') = 'object' then nd -> '_del' else '{}'::jsonb end;
  mm  := case when jsonb_typeof(nd -> '_m')   = 'object' then nd -> '_m'   else '{}'::jsonb end;

  -- bookings / enquiries / queue live together in parties, told apart by kind
  if not public.bk_has_feature(new.id, 'bookings')  then kinds := kinds || array['booking','walkin']; end if;
  if not public.bk_has_feature(new.id, 'enquiries') then kinds := kinds || array['enquiry']; end if;
  if not public.bk_has_feature(new.id, 'queue')     then kinds := kinds || array['queue']; end if;
  if cardinality(kinds) > 0 then
    r := public.bk_guard_items(od -> 'parties', nd -> 'parties', kinds, ms, od -> '_del', del, true);
    if nd ? 'parties' or od ? 'parties' then nd := jsonb_set(nd, '{parties}', r -> 'arr'); end if;
    del := r -> 'del'; changed := changed or (r ->> 'changed')::boolean;
  end if;

  foreach pair slice 1 in array id_keys loop
    k := pair[1]; f := pair[2];
    if (od ? k or nd ? k) and not public.bk_has_feature(new.id, f) then
      r := public.bk_guard_items(od -> k, nd -> k, null, ms, od -> '_del', del, false);
      nd := jsonb_set(nd, array[k], r -> 'arr'); del := r -> 'del'; changed := changed or (r ->> 'changed')::boolean;
    end if;
  end loop;

  foreach pair slice 1 in array plain_keys loop
    k := pair[1]; f := pair[2];
    if not public.bk_has_feature(new.id, f) then
      if (od -> k) is distinct from (nd -> k) then
        nd := case when od ? k then jsonb_set(nd, array[k], od -> k) else nd - k end;
        mm := mm || jsonb_build_object(k, ms); changed := true;
      elsif (od -> '_m' -> k) is distinct from (mm -> k) then
        mm := case when od -> '_m' ? k then mm || jsonb_build_object(k, od -> '_m' -> k) else mm - k end;
      end if;
    end if;
  end loop;

  -- settings: everything except a few switches that are used from other pages
  has_settings := public.bk_has_feature(new.id, 'settings');
  if not has_settings and jsonb_typeof(od -> 'settings') = 'object' and jsonb_typeof(nd -> 'settings') = 'object' then
    os := od -> 'settings'; ns := nd -> 'settings';
    ov := os;
    if ns -> 'prefs' -> 'dark' is not null and jsonb_typeof(ov -> 'prefs') = 'object' then ov := jsonb_set(ov, '{prefs,dark}', ns -> 'prefs' -> 'dark'); end if;
    if public.bk_has_feature(new.id, 'queue') and ns -> 'queue' -> 'closed' is not null and jsonb_typeof(ov -> 'queue') = 'object' then ov := jsonb_set(ov, '{queue,closed}', ns -> 'queue' -> 'closed'); end if;
    if public.bk_has_feature(new.id, 'reviews') and ns ? 'reviews' then ov := jsonb_set(ov, '{reviews}', ns -> 'reviews'); end if;
    if public.bk_has_feature(new.id, 'preorders') and ns ? 'preorders' then ov := jsonb_set(ov, '{preorders}', ns -> 'preorders'); end if;
    if ov is distinct from ns then nd := jsonb_set(nd, '{settings}', ov); mm := mm || jsonb_build_object('settings', ms); changed := true; end if;
  end if;

  -- venue details belong to settings; venue.users (the team list) to users
  has_users := public.bk_has_feature(new.id, 'users');
  if (not has_settings or not has_users) and jsonb_typeof(od -> 'venue') = 'object' and jsonb_typeof(nd -> 'venue') = 'object' then
    ov := od -> 'venue'; nv := nd -> 'venue';
    if not has_settings then
      ns := ov;
      if has_users then ns := case when nv ? 'users' then jsonb_set(ns, '{users}', nv -> 'users') else ns - 'users' end; end if;
    else
      ns := case when ov ? 'users' then jsonb_set(nv, '{users}', ov -> 'users') else nv - 'users' end;
    end if;
    if ns is distinct from nv then nd := jsonb_set(nd, '{venue}', ns); mm := mm || jsonb_build_object('venue', ms); changed := true; end if;
  end if;

  nd := jsonb_set(nd, '{_del}', del);
  nd := jsonb_set(nd, '{_m}', mm);
  if changed then nd := jsonb_set(nd, '{_g}', to_jsonb(ms)); end if;
  new.data := nd;
  return new;
end $$;
drop trigger if exists bk_venue_state_guard on public.bk_venue_state;
create trigger bk_venue_state_guard before update on public.bk_venue_state
  for each row execute function public.bk_venue_state_guard();

-- 9. Grants -----------------------------------------------------------------
revoke all on function public.bk_access(text), public.bk_has_feature(text, text), public.bk_business_role(uuid),
                       public.bk_can_manage_users(uuid), public.bk_list_members(uuid),
                       public.bk_save_member(uuid, text, text, text[], jsonb, text), public.bk_remove_member(uuid, text) from public, anon;
revoke all on function public.bk_sync_member(uuid, text), public.bk_guard_items(jsonb, jsonb, text[], bigint, jsonb, jsonb, boolean) from public, anon, authenticated;
grant execute on function public.bk_access(text), public.bk_has_feature(text, text), public.bk_business_role(uuid),
                          public.bk_can_manage_users(uuid), public.bk_list_members(uuid),
                          public.bk_save_member(uuid, text, text, text[], jsonb, text), public.bk_remove_member(uuid, text),
                          public.bk_whoami() to authenticated;
grant execute on function public.bk_feature_keys(), public.bk_feature_default(text, text), public.bk_inbox_feature(text),
                          public.bk_role_rank(text), public.bk_norm_role(text), public.bk_guard_prot(jsonb, text[]) to anon, authenticated;
