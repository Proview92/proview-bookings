-- 013: the licence portal can pause / resume a business and delete it completely (owner, 12 Nov 2026).
--   bk_businesses.suspended: a paused business is locked (bk_site_ok / bk_site_status: no staff use, no online booking);
--   bk_whoami reports it per site so the app shows "This business is paused".
--   hub_call 'suspend' { account_id, suspended } and 'delete_account' { account_id } (deletes the business, its
--   locations and everything kept for them: bookings state, public page, inbox, guests, campaigns, staff). Logins kept.
alter table public.bk_businesses add column if not exists suspended boolean not null default false;

create or replace function public.bk_site_ok(p_site text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.bk_sites s left join public.bk_businesses b on b.id = s.business_id
                  where s.id = p_site and not coalesce(b.suspended, false) and public.bk_license_ok(s.license_type, s.license_expires_at))
$$;
create or replace function public.bk_site_status(p_site text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('exists', s.id is not null, 'suspended', coalesce(b.suspended, false),
                            'ok', coalesce(public.bk_license_ok(s.license_type, s.license_expires_at), false) and not coalesce(b.suspended, false))
    from (select 1) x left join public.bk_sites s on s.id = p_site left join public.bk_businesses b on b.id = s.business_id
$$;

do $w$ declare d text; begin
  d := pg_get_functiondef('public.bk_whoami()'::regprocedure);
  if position('''suspended''' in d) = 0 then
    execute replace(d, '''license_type'', s.license_type, ''license_expires_at'', s.license_expires_at)',
                       '''license_type'', s.license_type, ''license_expires_at'', s.license_expires_at, ''suspended'', coalesce(b.suspended, false))');
  end if;
end $w$;

create or replace function hub_private.bk_hub_admin(p_action text, p_args jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b public.bk_businesses; s boolean; bid uuid; sites text[];
begin
  begin bid := (p_args->>'account_id')::uuid; exception when others then raise exception 'Business not found.'; end;
  select * into b from public.bk_businesses where id = bid;
  if p_action = 'suspend' then
    if b.id is null then raise exception 'Business not found.'; end if;
    s := coalesce((p_args->>'suspended')::boolean, true);
    update public.bk_businesses set suspended = s where id = b.id;
    return jsonb_build_object('ok', true, 'account_id', b.id, 'suspended', s);
  end if;
  if b.id is null then return jsonb_build_object('ok', true, 'account_id', bid, 'deleted', true, 'already', true); end if;
  select coalesce(array_agg(id), '{}') into sites from public.bk_sites where business_id = b.id;
  delete from public.bk_campaigns where venue = any(sites);
  delete from public.bk_guests where venue = any(sites);
  delete from public.bk_unsubscribes where venue = any(sites);
  delete from public.bk_staff_invites where venue = any(sites);
  delete from public.bk_staff_profiles where venue = any(sites);
  delete from public.bk_inbox where venue = any(sites);
  delete from public.bk_venue_public where id = any(sites);
  delete from public.bk_venue_state where id = any(sites);
  delete from public.bk_venue_ping where id = any(sites);
  delete from public.bk_businesses where id = b.id;   -- sites and members cascade
  return jsonb_build_object('ok', true, 'account_id', b.id, 'deleted', true);
end $$;
revoke all on function hub_private.bk_hub_admin(text, jsonb) from public, anon, authenticated;

do $p$ declare d text; begin
  d := pg_get_functiondef('public.hub_call(text,text,jsonb)'::regprocedure);
  if position('bk_hub_admin' in d) = 0 then
    execute replace(d, '  if p_action is distinct from ''link'' and p_action is distinct from ''unlink'' then',
      '  if p_action in (''suspend'', ''delete_account'') then
    if p_token is null or encode(extensions.digest(p_token, ''sha256''), ''hex'') is distinct from (select token_sha256 from hub_private.config where id = 1) then
      raise exception ''not authorised'';
    end if;
    return hub_private.bk_hub_admin(p_action, p_args);
  end if;
  if p_action is distinct from ''link'' and p_action is distinct from ''unlink'' then');
  end if;
end $p$;
