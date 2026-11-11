-- 009: the licence portal's "New customer" can add the business here too (NEW_CUSTOMER_MULTIAPP_SPEC, 11 Nov 2026).
--
-- The licence hub (edge function licence-hub) calls hub_call(token, 'add_business', args) with
-- args { business, name, email, mobile, password, contact_email? } and gets bk_add_business's result plus account_id.
-- It runs the master's own "+ Add business", public.bk_add_business (migration 007), unchanged, so it behaves exactly
-- the same: the same checks and messages, all or nothing, no email sent, an existing login keeps its password, and the
-- new business gets whatever licence state bk_add_business gives it (none, once the no-trial migration is in).
-- Only "who may call" differs: the hub token instead of the master's sign-in. For this one call the request runs as
-- this app's master account (bk_master_admins), which bk_add_business checks for, and is put back straight after.
-- The live hub_call ('list', 'set', ...) is kept exactly as it is, moved to hub_private.hub_call_base.
-- Safe to run more than once, and in any order with the no-trial migration.

-- 1) Move the live hub_call ('list', 'set', ...) aside, untouched, as hub_private.hub_call_base (not callable by the API).
--    Run again after any later change to public.hub_call and that newer one becomes the base.
do $$
declare src text := (select prosrc from pg_proc where oid = to_regprocedure('public.hub_call(text,text,jsonb)'));
begin
  if src is null then raise exception 'public.hub_call(text,text,jsonb) is missing.'; end if;
  if position('hub_private.hub_call_base' in src) = 0 then
    drop function if exists hub_private.hub_call_base(text, text, jsonb);
    alter function public.hub_call(text, text, jsonb) rename to hub_call_base;
    alter function public.hub_call_base(text, text, jsonb) set schema hub_private;
  end if;
end $$;
revoke all on function hub_private.hub_call_base(text, text, jsonb) from public, anon, authenticated;

-- 2) hub_call: 'add_business' here, every other action exactly as before.
create or replace function public.hub_call(p_token text, p_action text, p_args jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  r jsonb; mu uuid; me text;
  ce text := nullif(lower(trim(coalesce(p_args->>'contact_email', ''))), '');
  c_claims text := current_setting('request.jwt.claims', true);
  c_sub    text := current_setting('request.jwt.claim.sub', true);
  c_claim  text := current_setting('request.jwt.claim', true);
begin
  if p_action is distinct from 'add_business' then
    return hub_private.hub_call_base(p_token, p_action, p_args);
  end if;
  if p_token is null or encode(extensions.digest(p_token, 'sha256'), 'hex') is distinct from (select token_sha256 from hub_private.config where id = 1) then
    raise exception 'not authorised';
  end if;
  if ce is not null and ce !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a valid contact email, or leave it empty.'; end if;

  -- the master's own Add business, run as the master (bk_master_admins) for this one call
  select m.user_id, lower(u.email) into mu, me from public.bk_master_admins m join auth.users u on u.id = m.user_id
   order by u.created_at limit 1;
  if mu is null and me is null then raise exception 'This app has no Proview master account to add the business with.'; end if;
  perform set_config('request.jwt.claims', jsonb_strip_nulls(jsonb_build_object('sub', mu, 'email', me, 'role', 'authenticated',
                     'aud', 'authenticated', 'is_anonymous', false))::text, true);
  perform set_config('request.jwt.claim.sub', coalesce(mu::text, ''), true);
  perform set_config('request.jwt.claim', '', true);
  r := public.bk_add_business(p_args->>'business', p_args->>'name', p_args->>'email', p_args->>'mobile', p_args->>'password');
  perform set_config('request.jwt.claims', coalesce(c_claims, ''), true);
  perform set_config('request.jwt.claim.sub', coalesce(c_sub, ''), true);
  perform set_config('request.jwt.claim', coalesce(c_claim, ''), true);

  -- bk_add_business stores the owner's email as the contact email; the portal may pass the customer's instead
  if ce is not null then update public.bk_businesses set contact_email = ce where id = (r->>'business_id')::uuid; end if;
  return r || jsonb_build_object('account_id', r->>'business_id');
end;
$$;
revoke all on function public.hub_call(text, text, jsonb) from public, anon, authenticated, service_role;
grant execute on function public.hub_call(text, text, jsonb) to anon, authenticated;
