-- 011: Locations, not customers. Only the master links them (LOCATIONS_LINK_SPEC.md, owner 12 Nov 2026).
-- Bookings objects only (bk_*): the database is shared with Proview Till. public.hub_call is Bookings' own hub
-- endpoint (replaced here as in 009); everything new is named bk_*.
--
-- The licence portal's licence-hub is the only caller of two new hub actions (LOCATIONS_LINK_PROTOCOL.md):
--   hub_call(token, 'link',   { into: <business A>, from: <business B> })
--       -> { ok, account: A, from: B, moved_sites: [<site id>...], already, renamed_units: [] }
--       B's locations (bk_sites, with their bookings, guests, settings, staff and licences, which are all keyed by the
--       site id) move to A, B's people join A, and B's empty business row is deleted. One transaction; idempotent.
--   hub_call(token, 'unlink', { account: <business A>, site: <site id> })
--       -> { ok, account: <new business>, from: A, site, already, renamed_units: [] }
--       moves one location out into a new business named after it; the people who can see it are copied.
--       Refused when A has only that one location.
-- People on link: the higher role wins (Owner > Admin > Manager > Host > Viewer). Owners and admins see every
-- location anyway; managers of either side get every location of the merged business (owner: "owners and managers of
-- either location get both"); hosts and viewers keep exactly the locations they had.
--
-- Adding and deleting a location: nobody (master included) adds or deletes a single location from the app any more.
-- bk_add_site refuses everyone; the master's direct insert / delete on bk_sites is gone (the master still renames
-- locations and still deletes a whole business, whose locations go with it). The self sign-up
-- (bk_create_my_business: one business, one location) and Add business / hub add_business are unchanged.
-- Every other hub action is exactly the live hub_call, moved to hub_private.bk_hub_call_pre_link.
-- Safe to run more than once. Apply after 010.

create table if not exists hub_private.bk_location_moves (
  id           bigserial primary key,
  at           timestamptz not null default now(),
  action       text not null check (action in ('link', 'unlink')),
  from_account uuid not null,
  into_account uuid not null,
  site         text,
  sites        text[] not null default '{}',
  details      jsonb not null default '{}'::jsonb
);
create index if not exists bk_location_moves_from on hub_private.bk_location_moves (from_account);

-- 1) no adding / deleting single locations from the app
create or replace function public.bk_add_site(p_business uuid, p_name text, p_license text default 'trial')
returns public.bk_sites language plpgsql security definer set search_path = public as $$
begin
  raise exception 'Locations are added in the licence portal (New location), and linked there by Proview.';
end $$;
drop policy if exists "master writes sites" on public.bk_sites;
drop policy if exists "master updates sites" on public.bk_sites;
create policy "master updates sites" on public.bk_sites for update to authenticated
  using (public.bk_is_master()) with check (public.bk_is_master());
revoke insert, delete on public.bk_sites from anon, authenticated;

-- 2) link: B into A
create or replace function hub_private.bk_link_businesses(p_into uuid, p_from uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  a public.bk_businesses; b public.bk_businesses; lg hub_private.bk_location_moves;
  a_sites text[]; b_sites text[]; all_sites text[]; m public.bk_business_members; ex public.bk_business_members;
  nr text; ns text[];
begin
  if p_into = p_from then raise exception 'An account can''t be linked to itself.'; end if;
  select * into a from public.bk_businesses where id = p_into for update;
  if not found then raise exception 'Account not found: %', p_into; end if;
  select * into b from public.bk_businesses where id = p_from for update;
  if not found then
    select * into lg from hub_private.bk_location_moves where action = 'link' and from_account = p_from order by id desc limit 1;
    if lg.id is null then raise exception 'Account not found: %', p_from; end if;
    if lg.into_account <> p_into and not exists (select 1 from hub_private.bk_location_moves l2 where l2.action = 'link'
                                                  and l2.from_account = lg.into_account and l2.into_account = p_into) then
      raise exception '% was already linked into %, not %.', p_from, lg.into_account, p_into;
    end if;
    return jsonb_build_object('ok', true, 'account', p_into::text, 'from', p_from::text, 'already', true,
                              'moved_sites', to_jsonb(lg.sites), 'renamed_units', '[]'::jsonb);
  end if;

  select coalesce(array_agg(id order by created_at, id), '{}') into a_sites from public.bk_sites where business_id = a.id;
  select coalesce(array_agg(id order by created_at, id), '{}') into b_sites from public.bk_sites where business_id = b.id;
  all_sites := a_sites || b_sites;

  -- the locations (everything else in Bookings is keyed by the site id, so it moves with them)
  update public.bk_sites set business_id = a.id where business_id = b.id;

  -- people: B's join A; someone in both keeps the higher role; managers get every location
  for m in select * from public.bk_business_members where business_id = b.id loop
    select * into ex from public.bk_business_members where business_id = a.id and email = m.email;
    if ex.email is null then
      nr := m.role; ns := m.site_ids;
    elsif public.bk_role_rank(m.role) > public.bk_role_rank(ex.role) then
      nr := m.role; ns := array(select distinct x from unnest(coalesce(ex.site_ids, '{}') || coalesce(m.site_ids, '{}')) x);
    else
      nr := ex.role; ns := array(select distinct x from unnest(coalesce(ex.site_ids, '{}') || coalesce(m.site_ids, '{}')) x);
    end if;
    if nr in ('Owner', 'Admin') then ns := '{}'; elsif nr = 'Manager' then ns := all_sites; end if;
    insert into public.bk_business_members (business_id, email, user_id, name, role, site_ids, features, created_at)
    values (a.id, m.email, coalesce(ex.user_id, m.user_id), coalesce(ex.name, m.name), nr, ns,
            case when ex.email is null or public.bk_role_rank(m.role) > public.bk_role_rank(ex.role) then m.features else ex.features end,
            coalesce(least(ex.created_at, m.created_at), m.created_at))
    on conflict (business_id, email) do update
      set role = excluded.role, site_ids = excluded.site_ids, features = excluded.features,
          user_id = coalesce(public.bk_business_members.user_id, excluded.user_id),
          name = coalesce(public.bk_business_members.name, excluded.name);
  end loop;
  -- A's managers get B's locations too
  update public.bk_business_members set site_ids = all_sites where business_id = a.id and role = 'Manager' and site_ids is distinct from all_sites;

  insert into hub_private.bk_location_moves (action, from_account, into_account, sites, details)
  values ('link', b.id, a.id, b_sites, jsonb_build_object('from_name', b.name, 'into_name', a.name,
          'from_contact_email', b.contact_email, 'from_phone', b.phone));
  -- B's people rows go with B (its locations are already A's, so nobody loses access they now have through A)
  delete from public.bk_businesses where id = b.id;
  return jsonb_build_object('ok', true, 'account', a.id::text, 'from', b.id::text, 'already', false,
                            'moved_sites', to_jsonb(b_sites), 'renamed_units', '[]'::jsonb);
end $$;
revoke all on function hub_private.bk_link_businesses(uuid, uuid) from public, anon, authenticated;

-- 3) unlink: one location of A into a new business
create or replace function hub_private.bk_unlink_site(p_account uuid, p_site text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  a public.bk_businesses; si public.bk_sites; n_id uuid; lg hub_private.bk_location_moves; nsites int;
begin
  select * into si from public.bk_sites where id = p_site for update;
  if not found then raise exception 'Location not found: %', p_site; end if;
  select * into a from public.bk_businesses where id = p_account for update;
  if si.business_id is distinct from p_account then
    select * into lg from hub_private.bk_location_moves where action = 'unlink' and from_account = p_account and site = p_site
     order by id desc limit 1;
    if lg.id is not null and lg.into_account = si.business_id then
      return jsonb_build_object('ok', true, 'account', si.business_id::text, 'from', p_account::text, 'site', si.id,
                                'already', true, 'renamed_units', '[]'::jsonb);
    end if;
    if a.id is null then raise exception 'Account not found: %', p_account; end if;
    raise exception 'That location is not in account %.', p_account;
  end if;
  select count(*) into nsites from public.bk_sites where business_id = a.id;
  if nsites <= 1 then raise exception '% has only that one location, so there is nothing to unlink.', a.name; end if;

  insert into public.bk_businesses (name, contact_email, phone, notes, self_signup)
  values (si.name, a.contact_email, a.phone, concat_ws(E'\n', 'Unlinked from ' || a.name || ' in the licence portal', nullif(a.notes, '')), false)
  returning id into n_id;
  update public.bk_sites set business_id = n_id where id = si.id;

  -- the people who can see it are copied (A keeps them)
  insert into public.bk_business_members (business_id, email, user_id, name, role, site_ids, features, created_at)
    select n_id, m.email, m.user_id, m.name, m.role,
           case when m.role in ('Owner', 'Admin') then '{}'::text[] else array[si.id] end, m.features, m.created_at
      from public.bk_business_members m
     where m.business_id = a.id and (m.role in ('Owner', 'Admin') or si.id = any(m.site_ids));
  update public.bk_business_members set site_ids = array_remove(site_ids, si.id) where business_id = a.id and si.id = any(site_ids);
  -- A's people who weren't copied lose this location (venue staff added straight to the location stay)
  delete from public.bk_staff_profiles p
   where p.venue = si.id
     and p.user_id in (select user_id from public.bk_business_members where business_id = a.id and user_id is not null)
     and p.user_id not in (select user_id from public.bk_business_members where business_id = n_id and user_id is not null);
  delete from public.bk_staff_invites i
   where i.venue = si.id
     and lower(i.email) in (select email from public.bk_business_members where business_id = a.id)
     and lower(i.email) not in (select email from public.bk_business_members where business_id = n_id);

  insert into hub_private.bk_location_moves (action, from_account, into_account, site, sites, details)
  values ('unlink', a.id, n_id, si.id, array[si.id], jsonb_build_object('from_name', a.name, 'site_name', si.name));
  return jsonb_build_object('ok', true, 'account', n_id::text, 'from', a.id::text, 'site', si.id,
                            'already', false, 'renamed_units', '[]'::jsonb);
end $$;
revoke all on function hub_private.bk_unlink_site(uuid, text) from public, anon, authenticated;

-- 4) Move the live hub_call aside, untouched, as hub_private.bk_hub_call_pre_link (not callable by the API).
do $$
declare src text := (select prosrc from pg_proc where oid = to_regprocedure('public.hub_call(text,text,jsonb)'));
begin
  if src is null then raise exception 'public.hub_call(text,text,jsonb) is missing.'; end if;
  if position('hub_private.bk_hub_call_pre_link' in src) = 0 then
    drop function if exists hub_private.bk_hub_call_pre_link(text, text, jsonb);
    alter function public.hub_call(text, text, jsonb) rename to bk_hub_call_pre_link;
    alter function public.bk_hub_call_pre_link(text, text, jsonb) set schema hub_private;
  end if;
end $$;
revoke all on function hub_private.bk_hub_call_pre_link(text, text, jsonb) from public, anon, authenticated;

-- 5) hub_call: 'link' and 'unlink' here, every other action exactly as before.
create or replace function public.hub_call(p_token text, p_action text, p_args jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a uuid; b uuid; s text;
begin
  if p_action is distinct from 'link' and p_action is distinct from 'unlink' then
    return hub_private.bk_hub_call_pre_link(p_token, p_action, p_args);
  end if;
  if p_token is null or encode(extensions.digest(p_token, 'sha256'), 'hex') is distinct from (select token_sha256 from hub_private.config where id = 1) then
    raise exception 'not authorised';
  end if;
  if p_action = 'link' then
    if nullif(trim(coalesce(p_args->>'into', '')), '') is null or nullif(trim(coalesce(p_args->>'from', '')), '') is null then
      raise exception 'Say which accounts to link (into and from).';
    end if;
    begin a := trim(p_args->>'into')::uuid; exception when others then raise exception 'Account not found: %', p_args->>'into'; end;
    begin b := trim(p_args->>'from')::uuid; exception when others then raise exception 'Account not found: %', p_args->>'from'; end;
    return hub_private.bk_link_businesses(a, b);
  end if;
  s := trim(coalesce(p_args->>'site', ''));
  if s like 'loc/%' then s := substr(s, 5); end if;
  if nullif(trim(coalesce(p_args->>'account', '')), '') is null or s = '' then
    raise exception 'Say which account and location to unlink.';
  end if;
  begin a := trim(p_args->>'account')::uuid; exception when others then raise exception 'Account not found: %', p_args->>'account'; end;
  return hub_private.bk_unlink_site(a, s);
end $$;
revoke all on function public.hub_call(text, text, jsonb) from public;
grant execute on function public.hub_call(text, text, jsonb) to anon, authenticated;
