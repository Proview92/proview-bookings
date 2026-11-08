-- =====================================================================
--  PROVIEW BOOKINGS 005: guest details, pre-orders and money leave the shared venue document
--  Run after 004_business_access.sql. Safe to re-run. Only bk_* objects.
--
--  Why: each venue's working data is one JSON document (bk_venue_state.data) that every device
--  reads in full. 004 stopped people CHANGING the parts they lack a feature for, but they could
--  still READ everything. After this migration "feature off" means the server doesn't send it:
--
--  • Guests: personal details (name, phone, email, notes, tags, marketing opt-in, birthday...)
--    live in bk_guests (RLS: staff of the venue WITH the guests feature). The document keeps a
--    cut-down card per guest that has a booking or a chat: first name + initial, allergy tags
--    (needed for safe service) and empty phone/email/notes. The trigger rebuilds those cards on
--    every save, so guest details can never be stored in the document again, whoever writes it.
--    People without the guests feature add guests through bk_guest_attach (create or match by
--    email/phone, fill blanks only, nothing read back) and bk_inbox_take (online bookings).
--  • Pre-orders: people without preorders get the document without menus and party pre-order
--    items (with kitchen but not preorders: menu item names only, no prices, for the kitchen
--    screen). Their saves can't change them (the stored values are put back).
--  • Money: people without reports get parties without spend/deposit/depositRef (a "_dep" flag
--    says a deposit was paid). They may still record a bill total (write-only). Money figures for
--    Insights come from bk_report_money, which needs the reports feature.
--  • Direct SELECT on bk_venue_state now needs reports + preorders; everyone else reads and writes
--    through bk_venue_get / bk_venue_put, and is told about changes through bk_venue_ping.
--  • bk_inbox rows hold guests' contact details: direct reads need the guests feature too.
--  Older app versions keep working: guest records they write into the document are moved into
--  bk_guests (or dropped if the writer lacks the guests feature and the guest already exists).
-- =====================================================================

-- 1. Helpers ---------------------------------------------------------------
create or replace function public.bk_ms(x jsonb) returns numeric language sql immutable as $$
  select case when jsonb_typeof(x) = 'number' then (x #>> '{}')::numeric else 0 end $$;

-- "Charles Whitmore" -> "Charles W."  (what people without the guests feature see)
create or replace function public.bk_short_name(n text) returns text language sql immutable as $$
  select case when cardinality(p) <= 1 then left(coalesce(p[1], ''), 40)
              else left(p[1], 40) || ' ' || upper(left(p[cardinality(p)], 1)) || '.' end
    from (select regexp_split_to_array(btrim(coalesce(n, '')), '\s+') p) x $$;

-- Phone numbers match on their last 10 digits (07700 900105 = +44 7700 900105)
create or replace function public.bk_phone_key(x text) returns text language sql immutable as $$
  select case when length(d) >= 10 then right(d, 10) else nullif(d, '') end
    from (select regexp_replace(coalesce(x, ''), '\D', '', 'g') d) s $$;

-- Ids of the guest tags in the Allergies category
create or replace function public.bk_allergy_tags(d jsonb) returns jsonb language sql immutable as $$
  select coalesce(jsonb_agg(t -> 'id'), '[]'::jsonb)
    from jsonb_array_elements(case when jsonb_typeof(d -> 'guestTags') = 'array' then d -> 'guestTags' else '[]'::jsonb end) t
   where t ->> 'cat' = 'Allergies' $$;

-- The cut-down guest card kept in the shared document
create or replace function public.bk_guest_stub(p_id text, d jsonb, alg jsonb) returns jsonb language sql immutable as $$
  select jsonb_build_object('id', p_id, 'name', public.bk_short_name(d ->> 'name'), 'phone', '', 'email', '', 'notes', '',
           'marketing', false, 'created', '', '_u', case when jsonb_typeof(d -> '_u') = 'number' then d -> '_u' else '0'::jsonb end,
           'tags', coalesce((select jsonb_agg(t) from jsonb_array_elements(case when jsonb_typeof(d -> 'tags') = 'array' then d -> 'tags' else '[]'::jsonb end) t
                              where t in (select jsonb_array_elements(coalesce(alg, '[]'::jsonb)))), '[]'::jsonb)) $$;

-- 2. Guest book table -------------------------------------------------------
create table if not exists public.bk_guests (
  venue       text not null,
  id          text not null check (length(id) between 1 and 64),
  data        jsonb not null default '{}'::jsonb check (jsonb_typeof(data) = 'object' and octet_length(data::text) < 32000),
  email_key   text generated always as (nullif(lower(btrim(data ->> 'email')), '')) stored,
  phone_key   text generated always as (public.bk_phone_key(data ->> 'phone')) stored,
  updated_at  timestamptz not null default now(),
  updated_by  uuid,
  primary key (venue, id)
);
create index if not exists bk_guests_email on public.bk_guests (venue, email_key) where email_key is not null;
create index if not exists bk_guests_phone on public.bk_guests (venue, phone_key) where phone_key is not null;
alter table public.bk_guests enable row level security;

create or replace function public.bk_guests_before() returns trigger
language plpgsql set search_path = public as $$
begin
  new.data := new.data - 'id';
  if tg_op = 'UPDATE' and public.bk_ms(new.data -> '_u') < public.bk_ms(old.data -> '_u') then
    new.data := old.data;                       -- an older copy: keep the newer one (and tell devices)
  end if;
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end $$;
drop trigger if exists bk_guests_before on public.bk_guests;
create trigger bk_guests_before before insert or update on public.bk_guests
  for each row execute function public.bk_guests_before();

drop policy if exists bk_guests_read on public.bk_guests;
drop policy if exists bk_guests_add  on public.bk_guests;
drop policy if exists bk_guests_edit on public.bk_guests;
drop policy if exists bk_guests_del  on public.bk_guests;
create policy bk_guests_read on public.bk_guests for select to authenticated
  using (public.bk_is_staff(venue) and public.bk_has_feature(venue, 'guests'));
create policy bk_guests_add on public.bk_guests for insert to authenticated
  with check (public.bk_is_staff(venue) and public.bk_has_feature(venue, 'guests') and (public.bk_is_master() or public.bk_site_ok(venue)));
create policy bk_guests_edit on public.bk_guests for update to authenticated
  using (public.bk_is_staff(venue) and public.bk_has_feature(venue, 'guests'))
  with check (public.bk_is_staff(venue) and public.bk_has_feature(venue, 'guests') and (public.bk_is_master() or public.bk_site_ok(venue)));
create policy bk_guests_del on public.bk_guests for delete to authenticated
  using (public.bk_is_staff(venue) and public.bk_has_feature(venue, 'guests'));
revoke all on public.bk_guests from public, anon, authenticated;
grant select, insert, update, delete on public.bk_guests to authenticated;
grant all on public.bk_guests to service_role;

-- 3. Adding guests without reading the guest book ----------------------------
create or replace function public.bk_guest_find(p_venue text, p_email text, p_phone text) returns text
language sql stable security definer set search_path = public as $$
  select g.id from public.bk_guests g
   where g.venue = p_venue
     and ((nullif(lower(btrim(coalesce(p_email, ''))), '') is not null and g.email_key = lower(btrim(p_email)))
       or (public.bk_phone_key(p_phone) is not null and g.phone_key = public.bk_phone_key(p_phone)))
   order by (g.email_key is not distinct from nullif(lower(btrim(coalesce(p_email, ''))), '')) desc, g.id
   limit 1 $$;

-- Internal: adds the guest, or fills the blanks on the guest with the same email/phone. Returns the id.
create or replace function public.bk_guest_put_contact(p_venue text, p_id text, p jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare gid text; em text := lower(btrim(coalesce(p ->> 'email', ''))); ph text := btrim(coalesce(p ->> 'phone', ''));
        cur jsonb; upd jsonb; k text; ms bigint := (extract(epoch from clock_timestamp()) * 1000)::bigint;
begin
  if jsonb_typeof(p) <> 'object' then p := '{}'::jsonb; end if;
  gid := public.bk_guest_find(p_venue, em, ph);
  if gid is null then
    gid := coalesce(nullif(left(p_id, 64), ''), 'g' || substr(md5(random()::text || clock_timestamp()::text), 1, 10));
    insert into public.bk_guests (venue, id, data)
    values (p_venue, gid, jsonb_build_object('name', 'Guest', 'phone', '', 'email', '', 'tags', '[]'::jsonb, 'notes', '',
                                             'marketing', false, 'created', to_char(current_date, 'YYYY-MM-DD'))
                          || (p - 'id')
                          || jsonb_build_object('name', coalesce(nullif(left(btrim(coalesce(p ->> 'name', '')), 80), ''), 'Guest'),
                                                'email', em, 'phone', left(ph, 40),
                                                '_u', case when jsonb_typeof(p -> '_u') = 'number' then p -> '_u' else to_jsonb(ms) end))
    on conflict (venue, id) do nothing;
    return gid;
  end if;
  select data into cur from public.bk_guests where venue = p_venue and id = gid for update;
  upd := cur;
  foreach k in array array['phone', 'email', 'birthday', 'anniversary'] loop      -- fill blanks only
    if coalesce(btrim(cur ->> k), '') = '' and coalesce(btrim(p ->> k), '') <> '' then
      upd := upd || jsonb_build_object(k, case when k = 'email' then em else left(btrim(p ->> k), 40) end);
    end if;
  end loop;
  if (p ->> 'marketing') = 'true' and (cur ->> 'marketing') is distinct from 'true' then upd := upd || '{"marketing":true}'::jsonb; end if;
  if upd is distinct from cur then
    update public.bk_guests set data = upd || jsonb_build_object('_u', greatest(ms, public.bk_ms(cur -> '_u') + 1)) where venue = p_venue and id = gid;
  end if;
  return gid;
end $$;

-- For the booking screen: anyone who takes bookings can add a guest (or attach to the matching one)
-- with a name, phone and email. Returns the id and, without the guests feature, only the cut-down card.
create or replace function public.bk_guest_attach(p_venue text, p_guest jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare gid text; d jsonb; doc jsonb; c jsonb;
begin
  if auth.uid() is null or not public.bk_is_staff(p_venue)
     or not (public.bk_has_feature(p_venue, 'bookings') or public.bk_has_feature(p_venue, 'enquiries')
             or public.bk_has_feature(p_venue, 'queue') or public.bk_has_feature(p_venue, 'guests')) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  if not (public.bk_is_master() or public.bk_site_ok(p_venue)) then raise exception 'This site''s licence has ended.' using errcode = '42501'; end if;
  if jsonb_typeof(p_guest) <> 'object' then raise exception 'Enter the guest''s name'; end if;
  c := jsonb_build_object('name', left(btrim(coalesce(p_guest ->> 'name', '')), 80), 'phone', left(btrim(coalesce(p_guest ->> 'phone', '')), 40),
                          'email', left(lower(btrim(coalesce(p_guest ->> 'email', ''))), 120), 'marketing', (p_guest ->> 'marketing') = 'true');
  if c ->> 'name' = '' and c ->> 'phone' = '' and c ->> 'email' = '' then raise exception 'Enter the guest''s name'; end if;
  gid := public.bk_guest_put_contact(p_venue, null, c);
  select data into d from public.bk_guests where venue = p_venue and id = gid;
  if public.bk_has_feature(p_venue, 'guests') then
    return jsonb_build_object('id', gid, 'guest', d || jsonb_build_object('id', gid));
  end if;
  select data into doc from public.bk_venue_state where id = p_venue;
  return jsonb_build_object('id', gid, 'guest', public.bk_guest_stub(gid, d, public.bk_allergy_tags(coalesce(doc, '{}'::jsonb))));
end $$;

-- 4. Inbox: online requests carry contact details --------------------------
drop policy if exists "staff read inbox"   on public.bk_inbox;
drop policy if exists "staff update inbox" on public.bk_inbox;
create policy "staff read inbox" on public.bk_inbox for select to authenticated
  using (public.bk_is_staff(venue) and public.bk_has_feature(venue, public.bk_inbox_feature(kind)) and public.bk_has_feature(venue, 'guests'));
create policy "staff update inbox" on public.bk_inbox for update to authenticated
  using (public.bk_is_staff(venue) and public.bk_has_feature(venue, public.bk_inbox_feature(kind)) and public.bk_has_feature(venue, 'guests'))
  with check (public.bk_is_staff(venue) and public.bk_has_feature(venue, public.bk_inbox_feature(kind)) and public.bk_has_feature(venue, 'guests'));

-- Claims the venue's open requests (that the person handles), files the guest in the guest book and
-- returns the requests with guest_id + guest card. Without the guests feature, contact details are removed.
create or replace function public.bk_inbox_take(p_venue text, p_limit int default 50) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record; res jsonb := '[]'::jsonb; pl jsonb; has_g boolean; gid text; d jsonb; doc jsonb; alg jsonb; pt jsonb;
begin
  if auth.uid() is null or not public.bk_is_staff(p_venue) then raise exception 'Not allowed' using errcode = '42501'; end if;
  has_g := public.bk_has_feature(p_venue, 'guests');
  select data into doc from public.bk_venue_state where id = p_venue;
  doc := coalesce(doc, '{}'::jsonb); alg := public.bk_allergy_tags(doc);
  for r in select * from public.bk_inbox i
            where i.venue = p_venue and not i.processed and public.bk_has_feature(p_venue, public.bk_inbox_feature(i.kind))
            order by i.created_at limit greatest(1, least(coalesce(p_limit, 50), 200))
            for update skip locked loop
    update public.bk_inbox set processed = true where id = r.id;
    pl := case when jsonb_typeof(r.payload) = 'object' then r.payload else '{}'::jsonb end;
    gid := null;
    if r.kind in ('booking', 'enquiry', 'queue', 'signup') and (coalesce(pl ->> 'name', '') <> '' or coalesce(pl ->> 'email', '') <> '' or coalesce(pl ->> 'phone', '') <> '') then
      gid := public.bk_guest_put_contact(p_venue, null, jsonb_strip_nulls(jsonb_build_object(
               'name', left(btrim(coalesce(pl ->> 'name', '')), 80), 'phone', left(btrim(coalesce(pl ->> 'phone', '')), 40),
               'email', left(lower(btrim(coalesce(pl ->> 'email', ''))), 120),
               'marketing', r.kind = 'signup' or (pl ->> 'mkt') = 'true',
               'birthday', case when r.kind = 'signup' then nullif(left(btrim(coalesce(pl ->> 'birthday', '')), 10), '') end)));
    elsif r.kind = 'cancel' and coalesce(pl ->> 'queue', '') not in ('true', '1') then
      select x into pt from jsonb_array_elements(case when jsonb_typeof(doc -> 'parties') = 'array' then doc -> 'parties' else '[]'::jsonb end) x
       where x ->> 'id' = pl ->> 'id' limit 1;
      gid := pt ->> 'guest';
      pl := pl || jsonb_build_object('email_ok', gid is not null and exists (
                select 1 from public.bk_guests g where g.venue = p_venue and g.id = gid and g.email_key = nullif(lower(btrim(coalesce(pl ->> 'email', ''))), '')));
    elsif r.kind = 'sms' and public.bk_phone_key(pl ->> 'from') is not null then
      select g.id into gid from public.bk_guests g where g.venue = p_venue and g.phone_key = public.bk_phone_key(pl ->> 'from') order by g.id limit 1;
    end if;
    if gid is not null then
      select data into d from public.bk_guests where venue = p_venue and id = gid;
      if d is not null then
        pl := pl || jsonb_build_object('guest_id', gid, 'guest', case when has_g then d || jsonb_build_object('id', gid) else public.bk_guest_stub(gid, d, alg) end);
      end if;
    end if;
    if not has_g then pl := pl - 'name' - 'email' - 'phone' - 'birthday' - 'from' - 'mkt'; end if;
    res := res || jsonb_build_array(jsonb_build_object('id', r.id, 'venue', r.venue, 'kind', r.kind, 'created_at', r.created_at, 'processed', true, 'payload', pl));
  end loop;
  return res;
end $$;

-- 5. Reading the venue document: only what the person's features allow ----
create or replace function public.bk_redact_party(x jsonb, rep boolean, items boolean) returns jsonb language sql immutable as $$
  select case when jsonb_typeof(x) <> 'object' then x else
    (case when rep then x
          else (x - 'spend' - 'deposit' - 'depositRef')
               || case when public.bk_ms(x -> 'deposit') > 0 then '{"_dep":true}'::jsonb else '{}'::jsonb end end)
    - case when items then '_none_' else 'preItems' end end $$;

create or replace function public.bk_venue_redact(v text, d jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare rep boolean; pre boolean; kit boolean;
begin
  if d is null or jsonb_typeof(d) <> 'object' then return d; end if;
  rep := public.bk_has_feature(v, 'reports'); pre := public.bk_has_feature(v, 'preorders'); kit := public.bk_has_feature(v, 'kitchen');
  if (not rep or not (pre or kit)) and jsonb_typeof(d -> 'parties') = 'array' then
    d := jsonb_set(d, '{parties}', coalesce((select jsonb_agg(public.bk_redact_party(x, rep, pre or kit) order by o)
                                               from jsonb_array_elements(d -> 'parties') with ordinality t(x, o)), '[]'::jsonb));
  end if;
  if not pre and d ? 'menus' then
    d := jsonb_set(d, '{menus}', case when kit and jsonb_typeof(d -> 'menus') = 'array' then
      coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('id', m -> 'id', 'name', m -> 'name', 'active', m -> 'active', '_u', m -> '_u',
                  'items', coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('id', i -> 'id', 'name', i -> 'name', 'section', i -> 'section')) order by io)
                                       from jsonb_array_elements(case when jsonb_typeof(m -> 'items') = 'array' then m -> 'items' else '[]'::jsonb end) with ordinality q(i, io)), '[]'::jsonb)))
                  order by mo)
                  from jsonb_array_elements(d -> 'menus') with ordinality w(m, mo) where jsonb_typeof(m) = 'object'), '[]'::jsonb)
      else '[]'::jsonb end);
  end if;
  return d;
end $$;

create or replace function public.bk_venue_get(p_venue text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r public.bk_venue_state;
begin
  if auth.uid() is null or not public.bk_is_staff(p_venue) then raise exception 'Not allowed' using errcode = '42501'; end if;
  select * into r from public.bk_venue_state where id = p_venue;
  if not found then return null; end if;
  return jsonb_build_object('data', public.bk_venue_redact(p_venue, r.data), 'updated_at', r.updated_at);
end $$;

-- Saves the document if nobody saved since p_prev (null = create). Returns {updated_at, g} or null on a clash.
create or replace function public.bk_venue_put(p_venue text, p_data jsonb, p_prev text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t timestamptz; g jsonb;
begin
  if auth.uid() is null or not public.bk_is_staff(p_venue) then raise exception 'Not allowed' using errcode = '42501'; end if;
  if not (public.bk_is_master() or public.bk_site_ok(p_venue)) then raise exception 'This site''s licence has ended.' using errcode = '42501'; end if;
  if p_data is null or jsonb_typeof(p_data) <> 'object' then raise exception 'Bad venue data'; end if;
  if p_prev is null then
    insert into public.bk_venue_state (id, data, updated_at, updated_by) values (p_venue, p_data, clock_timestamp(), auth.uid())
    on conflict (id) do nothing returning updated_at, data -> '_g' into t, g;
  else
    update public.bk_venue_state set data = p_data, updated_at = clock_timestamp(), updated_by = auth.uid()
     where id = p_venue and updated_at = p_prev::timestamptz returning updated_at, data -> '_g' into t, g;
  end if;
  if t is null then return null; end if;
  return jsonb_build_object('updated_at', t, 'g', g);
end $$;

-- Direct reads of the whole document: only people who may see all of it.
drop policy if exists "staff read state" on public.bk_venue_state;
create policy "staff read state" on public.bk_venue_state for select to authenticated
  using (public.bk_is_staff(id) and public.bk_has_feature(id, 'reports') and public.bk_has_feature(id, 'preorders'));

-- 6. Change pings (live updates for people who read through bk_venue_get) ---
create table if not exists public.bk_venue_ping (
  id        text primary key,
  state_at  timestamptz,
  inbox_at  timestamptz
);
alter table public.bk_venue_ping enable row level security;
drop policy if exists bk_ping_read on public.bk_venue_ping;
create policy bk_ping_read on public.bk_venue_ping for select to authenticated using (public.bk_is_staff(id));
revoke all on public.bk_venue_ping from public, anon, authenticated;
grant select on public.bk_venue_ping to authenticated;
grant all on public.bk_venue_ping to service_role;

create or replace function public.bk_ping_state() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.bk_venue_ping (id, state_at) values (new.id, new.updated_at)
  on conflict (id) do update set state_at = excluded.state_at;
  return null;
end $$;
drop trigger if exists bk_ping_state on public.bk_venue_state;
create trigger bk_ping_state after insert or update on public.bk_venue_state
  for each row execute function public.bk_ping_state();

create or replace function public.bk_ping_inbox() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.bk_venue_ping (id, inbox_at) values (new.venue, now())
  on conflict (id) do update set inbox_at = excluded.inbox_at;
  return null;
end $$;
drop trigger if exists bk_ping_inbox on public.bk_inbox;
create trigger bk_ping_inbox after insert on public.bk_inbox
  for each row execute function public.bk_ping_inbox();

-- 7. Saving the venue document ---------------------------------------------
-- (a) bk_venue_state_fill runs first: puts back what the writer was never sent.
create or replace function public.bk_fill_party(x jsonb, o jsonb, rep boolean, pre boolean) returns jsonb language plpgsql immutable as $$
declare k text;
begin
  if jsonb_typeof(x) <> 'object' then return x; end if;
  if not rep then
    if o is not null then
      foreach k in array array['deposit', 'depositRef'] loop
        x := case when o ? k then x || jsonb_build_object(k, o -> k) else x - k end;
      end loop;
      if x -> 'spend' is null or jsonb_typeof(x -> 'spend') = 'null' then          -- bill totals are write-only
        x := case when o ? 'spend' then x || jsonb_build_object('spend', o -> 'spend') else x - 'spend' end;
      end if;
    end if;
  end if;
  if not pre then
    if o is not null then
      foreach k in array array['preItems', 'preorder'] loop
        x := case when o ? k then x || jsonb_build_object(k, o -> k) else x - k end;
      end loop;
    else
      x := x - 'preItems';
      if x ? 'preorder' then x := x || '{"preorder":false}'::jsonb; end if;
    end if;
  end if;
  return x;
end $$;

create or replace function public.bk_venue_state_fill() returns trigger
language plpgsql security definer set search_path = public as $$
declare nd jsonb := new.data; od jsonb; rep boolean; pre boolean;
begin
  if nd is null or jsonb_typeof(nd) <> 'object' then return new; end if;
  if jsonb_typeof(nd -> 'parties') = 'array'                                  -- "_dep" is a read-only marker
     and exists (select 1 from jsonb_array_elements(nd -> 'parties') x where jsonb_typeof(x) = 'object' and x ? '_dep') then
    nd := jsonb_set(nd, '{parties}', coalesce((select jsonb_agg(case when jsonb_typeof(x) = 'object' then x - '_dep' else x end order by o)
                                        from jsonb_array_elements(nd -> 'parties') with ordinality t(x, o)), '[]'::jsonb));
  end if;
  if tg_op = 'UPDATE' and auth.uid() is not null and not public.bk_is_master() then
    od := case when jsonb_typeof(old.data) = 'object' then old.data else '{}'::jsonb end;
    rep := public.bk_has_feature(new.id, 'reports'); pre := public.bk_has_feature(new.id, 'preorders');
    if not pre then
      nd := case when od ? 'menus' then jsonb_set(nd, '{menus}', od -> 'menus') else nd - 'menus' end;
    end if;
    if (not rep or not pre) and jsonb_typeof(nd -> 'parties') = 'array' then
      nd := jsonb_set(nd, '{parties}', coalesce((
              select jsonb_agg(public.bk_fill_party(t.x, op.y, rep, pre) order by t.o)
                from jsonb_array_elements(nd -> 'parties') with ordinality t(x, o)
                left join lateral (select y from jsonb_array_elements(case when jsonb_typeof(od -> 'parties') = 'array' then od -> 'parties' else '[]'::jsonb end) y
                                    where jsonb_typeof(y) = 'object' and y ->> 'id' = t.x ->> 'id' limit 1) op on true), '[]'::jsonb));
    end if;
  end if;
  new.data := nd;
  return new;
end $$;
drop trigger if exists bk_venue_state_fill on public.bk_venue_state;
create trigger bk_venue_state_fill before insert or update on public.bk_venue_state
  for each row execute function public.bk_venue_state_fill();

-- (b) bk_venue_state_guard (004) runs next, unchanged.
-- (c) bk_venue_state_guests runs last: guest records go to bk_guests, the document keeps cut-down cards.
create or replace function public.bk_venue_state_guests() returns trigger
language plpgsql security definer set search_path = public as $$
declare nd jsonb := new.data; od jsonb; has_g boolean; del jsonb; odel jsonb; g jsonb; gid text; nid text;
        rw public.bk_guests; s0 jsonb; upd jsonb; k text; remap jsonb := '{}'::jsonb; alg jsonb; addt jsonb; remt jsonb;
        del_changed boolean := false; is_card boolean;
begin
  if nd is null or jsonb_typeof(nd) <> 'object' then return new; end if;
  od := case when tg_op = 'UPDATE' and jsonb_typeof(old.data) = 'object' then old.data else '{}'::jsonb end;
  has_g := auth.uid() is null or public.bk_is_master() or public.bk_has_feature(new.id, 'guests');
  del  := case when jsonb_typeof(nd -> '_del') = 'object' then nd -> '_del' else '{}'::jsonb end;
  odel := case when jsonb_typeof(od -> '_del') = 'object' then od -> '_del' else '{}'::jsonb end;
  alg := public.bk_allergy_tags(nd);

  -- 1. guest records written into the document (older app versions)
  if jsonb_typeof(nd -> 'guests') = 'array' then
    for g in select x from jsonb_array_elements(nd -> 'guests') x where jsonb_typeof(x) = 'object' and coalesce(x ->> 'id', '') <> '' loop
      gid := left(g ->> 'id', 64);
      if del ? gid and public.bk_ms(del -> gid) >= public.bk_ms(g -> '_u') then continue; end if;   -- deleted
      select * into rw from public.bk_guests where venue = new.id and id = gid;
      if not found then
        nid := public.bk_guest_put_contact(new.id, gid, g);       -- new guest (anyone taking bookings may add one)
        if nid <> gid then remap := remap || jsonb_build_object(gid, nid); end if;
      elsif has_g and public.bk_ms(g -> '_u') > public.bk_ms(rw.data -> '_u') then
        s0 := public.bk_guest_stub(gid, rw.data, alg);
        -- a cut-down card has the short name and/or a blank email where the guest book has one
        is_card := (coalesce(g ->> 'name', '') = s0 ->> 'name' and s0 ->> 'name' <> coalesce(rw.data ->> 'name', ''))
                or (coalesce(g ->> 'email', '') = '' and coalesce(rw.data ->> 'email', '') <> '');
        if is_card then
          -- an edit made on the cut-down card: apply only what was filled in or changed
          upd := rw.data;
          for k in select jsonb_object_keys(g - 'id' - '_u' - 'tags') loop
            if (g -> k) is distinct from (s0 -> k) and (g -> k) not in ('""'::jsonb, 'false'::jsonb, 'null'::jsonb) then
              upd := upd || jsonb_build_object(k, g -> k);
            end if;
          end loop;
          if jsonb_typeof(g -> 'tags') = 'array' and (g -> 'tags') is distinct from (s0 -> 'tags') then
            addt := coalesce((select jsonb_agg(t) from jsonb_array_elements(g -> 'tags') t where not (s0 -> 'tags') @> jsonb_build_array(t)), '[]'::jsonb);
            remt := coalesce((select jsonb_agg(t) from jsonb_array_elements(s0 -> 'tags') t where not (g -> 'tags') @> jsonb_build_array(t)), '[]'::jsonb);
            upd := upd || jsonb_build_object('tags', coalesce((select jsonb_agg(distinct t) from (
                     select t from jsonb_array_elements(case when jsonb_typeof(rw.data -> 'tags') = 'array' then rw.data -> 'tags' else '[]'::jsonb end) t
                      where not remt @> jsonb_build_array(t)
                     union select t from jsonb_array_elements(addt) t) z), '[]'::jsonb));
          end if;
        else
          upd := rw.data || (g - 'id');                           -- a full record from an older app
        end if;
        if (upd - '_u') is distinct from (rw.data - '_u') then
          update public.bk_guests set data = upd || jsonb_build_object('_u', g -> '_u') where venue = new.id and id = gid;
        end if;
      end if;
    end loop;
  end if;

  -- 2. point bookings and chats at the merged guest
  if remap <> '{}'::jsonb then
    foreach k in array array['parties', 'chats'] loop
      if jsonb_typeof(nd -> k) = 'array' then
        nd := jsonb_set(nd, array[k], coalesce((select jsonb_agg(case when jsonb_typeof(x) = 'object' and remap ? (x ->> 'guest')
                                                             then x || jsonb_build_object('guest', remap -> (x ->> 'guest')) else x end order by o)
                                         from jsonb_array_elements(nd -> k) with ordinality t(x, o)), '[]'::jsonb));
      end if;
    end loop;
  end if;

  -- 3. guests deleted in the document (older app versions): only with the guests feature
  for k in select key from jsonb_each(del) where not odel ? key or public.bk_ms(del -> key) > public.bk_ms(odel -> key) loop
    if exists (select 1 from public.bk_guests where venue = new.id and id = k) then
      if has_g then
        delete from public.bk_guests where venue = new.id and id = k and public.bk_ms(data -> '_u') <= public.bk_ms(del -> k);
      else
        del := case when odel ? k then del || jsonb_build_object(k, odel -> k) else del - k end; del_changed := true;
      end if;
    end if;
  end loop;
  if del_changed then nd := jsonb_set(nd, '{_del}', del); end if;

  -- 4. the document keeps only cut-down cards for guests with a booking or chat here
  nd := jsonb_set(nd, '{guests}', coalesce((
          select jsonb_agg(public.bk_guest_stub(g2.id, g2.data, alg) order by g2.id)
            from public.bk_guests g2
           where g2.venue = new.id
             and g2.id in (select x ->> 'guest' from jsonb_array_elements(case when jsonb_typeof(nd -> 'parties') = 'array' then nd -> 'parties' else '[]'::jsonb end) x
                            where jsonb_typeof(x) = 'object'
                           union
                           select x ->> 'guest' from jsonb_array_elements(case when jsonb_typeof(nd -> 'chats') = 'array' then nd -> 'chats' else '[]'::jsonb end) x
                            where jsonb_typeof(x) = 'object')), '[]'::jsonb));
  new.data := nd;
  return new;
end $$;
drop trigger if exists bk_venue_state_guests on public.bk_venue_state;
create trigger bk_venue_state_guests before insert or update on public.bk_venue_state
  for each row execute function public.bk_venue_state_guests();

-- 8. Insights money figures (reports feature) -------------------------------
-- Same rules as the app: DEAD = cancelled/noshow/deleted/pending/declined, seated = finished/seated/dessert/paying.
create or replace function public.bk_report_money(p_venue text, p_from date, p_to date, p_dow int default null,
                                                  p_seat text default 'any', p_with_queue boolean default false) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare d jsonb; res jsonb;
begin
  if auth.uid() is null or not public.bk_is_staff(p_venue) or not public.bk_has_feature(p_venue, 'reports') then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  select data into d from public.bk_venue_state where id = p_venue;
  with ps as (
    select x ->> 'date' dt, coalesce(x ->> 'status', '') st,
           public.bk_ms(x -> 'spend') spend, public.bk_ms(x -> 'deposit') dep, public.bk_ms(x -> 'size') sz
      from jsonb_array_elements(case when jsonb_typeof(d -> 'parties') = 'array' then d -> 'parties' else '[]'::jsonb end) x
     where jsonb_typeof(x) = 'object' and coalesce(x ->> 'date', '') ~ '^\d{4}-\d{2}-\d{2}$'
       and x ->> 'date' between to_char(p_from, 'YYYY-MM-DD') and to_char(p_to, 'YYYY-MM-DD')
       and coalesce(x ->> 'kind', 'booking') <> 'enquiry' and (p_with_queue or coalesce(x ->> 'kind', 'booking') <> 'queue')
       and coalesce(x ->> 'status', '') <> 'deleted'
       and (p_dow is null or extract(dow from (x ->> 'date')::date) = p_dow)),
  f as (select *, st in ('cancelled', 'noshow', 'deleted', 'pending', 'declined') dead,
               st in ('finished', 'seated', 'dessert', 'paying') seated from ps),
  g as (select * from f where coalesce(p_seat, 'any') = 'any' or (p_seat = 'yes' and seated) or (p_seat = 'no' and dead)),
  ok as (select * from g where p_seat = 'no' or not dead)
  select jsonb_build_object(
    'deposits', coalesce((select sum(dep) from ok), 0),
    'takings', coalesce((select sum(spend) from g where seated), 0),
    'spend_covers', coalesce((select sum(sz) from g where seated and spend > 0), 0),
    'per_head', coalesce((select case when sum(sz) > 0 then round(sum(spend) / sum(sz), 2) end from g where seated and spend > 0), 0),
    'by_day', coalesce((select jsonb_object_agg(dt, jsonb_build_object('takings', t, 'deposits', dd)) from (
                 select dt, sum(spend) filter (where seated) t, sum(dep) filter (where p_seat = 'no' or not dead) dd from g group by dt) z), '{}'::jsonb))
    into res;
  return res;
end $$;

-- 9. Unsubscribes (bk-mail edge function) and site deletion ------------------
create or replace function public.bk_guest_marketing_off(p_venue text, p_email text) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update public.bk_guests set data = data || jsonb_build_object('marketing', false, '_u', (extract(epoch from clock_timestamp()) * 1000)::bigint)
   where venue = p_venue and email_key = lower(btrim(coalesce(p_email, ''))) and (data ->> 'marketing') = 'true';
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.bk_site_deleted() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  delete from public.bk_venue_state where id = old.id;
  delete from public.bk_venue_public where id = old.id;
  delete from public.bk_guests where venue = old.id;
  delete from public.bk_venue_ping where id = old.id;
  delete from public.bk_staff_profiles where venue = old.id;
  delete from public.bk_staff_invites where venue = old.id;
  perform set_config('bk.sync', '1', true);
  update public.bk_business_members set site_ids = array_remove(site_ids, old.id) where old.id = any(site_ids);
  perform set_config('bk.sync', '', true);
  return old;
end $$;

-- 10. Grants ----------------------------------------------------------------
revoke all on function public.bk_guest_find(text, text, text), public.bk_guest_put_contact(text, text, jsonb),
                       public.bk_guest_marketing_off(text, text), public.bk_venue_redact(text, jsonb) from public, anon, authenticated;
revoke all on function public.bk_guest_attach(text, jsonb), public.bk_inbox_take(text, int), public.bk_venue_get(text),
                       public.bk_venue_put(text, jsonb, text), public.bk_report_money(text, date, date, int, text, boolean) from public, anon;
grant execute on function public.bk_guest_attach(text, jsonb), public.bk_inbox_take(text, int), public.bk_venue_get(text),
                          public.bk_venue_put(text, jsonb, text), public.bk_report_money(text, date, date, int, text, boolean) to authenticated;
grant execute on function public.bk_guest_find(text, text, text), public.bk_guest_put_contact(text, text, jsonb),
                          public.bk_guest_marketing_off(text, text), public.bk_venue_redact(text, jsonb) to service_role;
grant execute on function public.bk_ms(jsonb), public.bk_short_name(text), public.bk_phone_key(text), public.bk_allergy_tags(jsonb),
                          public.bk_guest_stub(text, jsonb, jsonb), public.bk_redact_party(jsonb, boolean, boolean),
                          public.bk_fill_party(jsonb, jsonb, boolean, boolean) to anon, authenticated, service_role;

do $$ begin
  begin alter publication supabase_realtime add table public.bk_guests;     exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.bk_venue_ping; exception when duplicate_object then null; end;
end $$;

-- 11. Move existing guest details out of the shared document ----------------
insert into public.bk_guests (venue, id, data)
select distinct on (s.id, left(g ->> 'id', 64)) s.id, left(g ->> 'id', 64), g - 'id'
  from public.bk_venue_state s
 cross join lateral jsonb_array_elements(case when jsonb_typeof(s.data -> 'guests') = 'array' then s.data -> 'guests' else '[]'::jsonb end) g
 where jsonb_typeof(g) = 'object' and coalesce(g ->> 'id', '') <> ''
   and octet_length(g::text) < 32000
   and not (case when jsonb_typeof(s.data -> '_del') = 'object' then s.data -> '_del' else '{}'::jsonb end) ? (g ->> 'id')
on conflict (venue, id) do nothing;

-- Notifications ("New online booking: Rachel Kim ...") get the short name too.
create or replace function public.bk_shorten_note_names(d jsonb) returns jsonb language plpgsql immutable as $$
declare n jsonb; g jsonb; t text; out jsonb := '[]'::jsonb;
begin
  if jsonb_typeof(d -> 'notes') <> 'array' or jsonb_typeof(d -> 'guests') <> 'array' then return d; end if;
  for n in select x from jsonb_array_elements(d -> 'notes') x loop
    if jsonb_typeof(n) = 'object' and jsonb_typeof(n -> 'text') = 'string' then
      t := n ->> 'text';
      for g in select x from jsonb_array_elements(d -> 'guests') x
                where jsonb_typeof(x) = 'object' and btrim(coalesce(x ->> 'name', '')) ~ '\s'
                order by length(x ->> 'name') desc loop
        t := replace(t, btrim(g ->> 'name'), public.bk_short_name(g ->> 'name'));
      end loop;
      n := n || jsonb_build_object('text', t);
    end if;
    out := out || jsonb_build_array(n);
  end loop;
  return jsonb_set(d, '{notes}', out);
end $$;

-- Rewriting each document runs bk_venue_state_guests, which replaces the guest list with the cut-down
-- cards. updated_at moves on so every device picks up the new version.
update public.bk_venue_state set data = public.bk_shorten_note_names(data), updated_at = clock_timestamp()
 where jsonb_typeof(data -> 'guests') = 'array'
   and exists (select 1 from jsonb_array_elements(data -> 'guests') g
                where jsonb_typeof(g) = 'object' and (coalesce(g ->> 'email', '') <> '' or coalesce(g ->> 'phone', '') <> ''
                       or coalesce(g ->> 'notes', '') <> '' or (g ->> 'marketing') = 'true' or g ? 'birthday' or g ? 'anniversary'
                       or g ->> 'name' is distinct from public.bk_short_name(g ->> 'name')));
