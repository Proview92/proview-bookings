-- Proview Bookings: email campaigns (same designer as Proview WiFi), sent through Resend by the
-- bk-campaign edge function; opens, clicks and unsubscribes are recorded by bk-mail.
-- Managers (bk_is_admin: Admin/Owner/Manager staff, or master admins) can see and edit a venue's campaigns.

create table if not exists public.bk_campaigns (
  id            uuid primary key default gen_random_uuid(),
  venue         text not null references public.bk_sites(id) on delete cascade,
  name          text not null default 'New campaign',
  subject       text not null default '',
  preheader     text not null default '',
  from_name     text not null default '',
  reply_to      text not null default '',
  design        jsonb not null default '{}'::jsonb,
  status        text not null default 'draft' check (status in ('draft','scheduled','sending','sent','cancelled')),
  scheduled_at  timestamptz,
  started_at    timestamptz,
  finished_at   timestamptz,
  links         jsonb not null default '[]'::jsonb,   -- tracked links, frozen when sending starts
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists bk_campaigns_venue_idx on public.bk_campaigns(venue, created_at desc);
create index if not exists bk_campaigns_due_idx on public.bk_campaigns(status, scheduled_at) where status in ('scheduled','sending');

create table if not exists public.bk_campaign_recipients (
  id           bigserial primary key,
  campaign_id  uuid not null references public.bk_campaigns(id) on delete cascade,
  venue        text not null,
  guest_id     text,
  email        text not null,
  name         text not null default '',
  token        text not null unique default encode(gen_random_bytes(18), 'hex'),
  status       text not null default 'pending' check (status in ('pending','sent','failed','skipped')),
  error        text,
  sent_at      timestamptz,
  opened_at    timestamptz,
  clicked_at   timestamptz,
  unsub_at     timestamptz,
  unique (campaign_id, email)
);
create index if not exists bk_campaign_rcpt_pending_idx on public.bk_campaign_recipients(campaign_id) where status = 'pending';

-- Anyone who unsubscribed from a venue (kept even if the guest is re-added later)
create table if not exists public.bk_unsubscribes (
  venue       text not null,
  email       text not null,
  campaign_id uuid,
  at          timestamptz not null default now(),
  primary key (venue, email)
);

-- keep updated_at fresh
create or replace function public.bk_campaigns_touch() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;
drop trigger if exists bk_campaigns_touch on public.bk_campaigns;
create trigger bk_campaigns_touch before update on public.bk_campaigns for each row execute function public.bk_campaigns_touch();

alter table public.bk_campaigns enable row level security;
alter table public.bk_campaign_recipients enable row level security;
alter table public.bk_unsubscribes enable row level security;

drop policy if exists bk_campaigns_read on public.bk_campaigns;
create policy bk_campaigns_read on public.bk_campaigns for select to authenticated using (public.bk_is_admin(venue));
drop policy if exists bk_campaigns_add on public.bk_campaigns;
create policy bk_campaigns_add on public.bk_campaigns for insert to authenticated with check (public.bk_is_admin(venue) and status = 'draft');
-- Managers edit drafts and scheduled campaigns (and can cancel); sending itself is done by the edge function
drop policy if exists bk_campaigns_edit on public.bk_campaigns;
create policy bk_campaigns_edit on public.bk_campaigns for update to authenticated
  using (public.bk_is_admin(venue) and status in ('draft','scheduled'))
  with check (public.bk_is_admin(venue) and status in ('draft','scheduled','cancelled'));
drop policy if exists bk_campaigns_del on public.bk_campaigns;
create policy bk_campaigns_del on public.bk_campaigns for delete to authenticated using (public.bk_is_admin(venue) and status = 'draft');

drop policy if exists bk_campaign_rcpt_read on public.bk_campaign_recipients;
create policy bk_campaign_rcpt_read on public.bk_campaign_recipients for select to authenticated using (public.bk_is_admin(venue));
drop policy if exists bk_unsub_read on public.bk_unsubscribes;
create policy bk_unsub_read on public.bk_unsubscribes for select to authenticated using (public.bk_is_admin(venue));

grant select, insert, update, delete on public.bk_campaigns to authenticated;
grant select on public.bk_campaign_recipients, public.bk_unsubscribes to authenticated;

-- Per-campaign numbers for the list and report pages
create or replace function public.bk_campaign_stats(p_venue text)
returns table (campaign_id uuid, total int, sent int, failed int, skipped int, pending int, opened int, clicked int, unsubscribed int)
language sql stable security definer set search_path = public as $$
  select r.campaign_id, count(*)::int,
    count(*) filter (where r.status = 'sent')::int, count(*) filter (where r.status = 'failed')::int,
    count(*) filter (where r.status = 'skipped')::int, count(*) filter (where r.status = 'pending')::int,
    count(r.opened_at)::int, count(r.clicked_at)::int, count(r.unsub_at)::int
  from public.bk_campaign_recipients r
  where r.venue = p_venue and public.bk_is_admin(p_venue)
  group by r.campaign_id
$$;
revoke all on function public.bk_campaign_stats(text) from public, anon;
grant execute on function public.bk_campaign_stats(text) to authenticated;

-- Private secret shared by the cron job and the edge functions (never exposed through the API)
create schema if not exists bk_private;
revoke all on schema bk_private from public, anon, authenticated;
create table if not exists bk_private.mail_secret (id int primary key default 1 check (id = 1), token text not null default encode(gen_random_bytes(32), 'hex'));
insert into bk_private.mail_secret (id) values (1) on conflict do nothing;
create or replace function public.bk_mail_secret() returns text language sql stable security definer set search_path = bk_private as $$ select token from bk_private.mail_secret where id = 1 $$;
revoke all on function public.bk_mail_secret() from public, anon, authenticated;
grant execute on function public.bk_mail_secret() to service_role;

-- Images used in emails: public bucket, managers upload into their venue's folder
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('bk-email', 'bk-email', true, 5242880, array['image/png','image/jpeg','image/gif','image/webp'])
on conflict (id) do nothing;
drop policy if exists bk_email_upload on storage.objects;
create policy bk_email_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'bk-email' and public.bk_is_admin((storage.foldername(name))[1]));

-- Hands out queued campaign emails to one sender at a time (the Send button and the every-minute job can overlap)
alter table public.bk_campaign_recipients add column if not exists claimed_at timestamptz;
create or replace function public.bk_claim_recipients(p_campaign uuid, p_n int)
returns setof public.bk_campaign_recipients language sql volatile security definer set search_path = public as $$
  update public.bk_campaign_recipients r set claimed_at = now()
  where r.id in (
    select id from public.bk_campaign_recipients
    where campaign_id = p_campaign and status = 'pending' and (claimed_at is null or claimed_at < now() - interval '5 minutes')
    order by id limit greatest(1, least(p_n, 100))
    for update skip locked)
  returning r.*
$$;
revoke all on function public.bk_claim_recipients(uuid, int) from public, anon, authenticated;
grant execute on function public.bk_claim_recipients(uuid, int) to service_role;

grant all on public.bk_campaigns, public.bk_campaign_recipients, public.bk_unsubscribes to service_role;
grant usage, select on sequence public.bk_campaign_recipients_id_seq to service_role;
grant select, update on public.bk_venue_state to service_role;
grant select on public.bk_sites to service_role;

-- Every minute: if a campaign is due or still sending, wake the bk-campaign function to carry on
create extension if not exists pg_net;
create extension if not exists pg_cron;
create or replace function bk_private.campaign_tick() returns void language plpgsql security definer set search_path = public, bk_private as $$
begin
  if exists (select 1 from public.bk_campaigns where status = 'sending' or (status = 'scheduled' and scheduled_at <= now())) then
    perform net.http_post(
      url := 'https://otljdgrjrikuejmlwnpv.supabase.co/functions/v1/bk-campaign',
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-bk-tick', (select token from bk_private.mail_secret where id = 1)),
      body := '{"action":"tick"}'::jsonb,
      timeout_milliseconds := 55000);
  end if;
end $$;
revoke all on function bk_private.campaign_tick() from public, anon, authenticated;
select cron.unschedule(jobid) from cron.job where jobname = 'bk-campaign-tick';
select cron.schedule('bk-campaign-tick', '* * * * *', 'select bk_private.campaign_tick()');
