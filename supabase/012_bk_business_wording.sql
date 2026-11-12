-- 012: wording only (owner, 12 Nov 2026: "business", not "location"). Re-creates bk_add_site from 011 with the new message.
create or replace function public.bk_add_site(p_business uuid, p_name text, p_license text default 'trial')
returns public.bk_sites language plpgsql security definer set search_path = public as $$
begin
  raise exception 'Businesses are added in the licence portal (New business), and linked there by Proview.';
end $$;
