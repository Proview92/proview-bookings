// Proview Bookings email campaigns: links inside sent emails (no login).
//   GET  /o/<token>.gif            open tracking pixel
//   GET  /c/<token>?i=<n>          click: records it, then redirects to the campaign's n-th link
//   POST /u/<token>                one-click unsubscribe from Gmail / Apple Mail (RFC 8058)
//   POST { action: "info"|"unsub"|"view", token }   for bookings.proviewcrm.co.uk/unsubscribe.html and /email.html
// Unsubscribing records it and unticks "marketing" on the guest in the Bookings guest book.
// Supabase doesn't serve HTML pages from function URLs, so the pages live on the Bookings site.
// Deployed with verify_jwt = false.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
import { renderEmail } from "./render.js";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const env = (k: string) => Deno.env.get(k) ?? "";
const URL_ = env("SUPABASE_URL");
const SITE = "https://bookings.proviewcrm.co.uk";
const db = createClient(URL_, env("SUPABASE_SERVICE_ROLE_KEY"), { auth: { persistSession: false } });
const GIF = Uint8Array.from(atob("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"), (c) => c.charCodeAt(0));
const TOKEN_RE = /^[0-9a-f]{20,64}$/;

async function recipient(token: string) {
  if (!TOKEN_RE.test(token)) return null;
  const { data } = await db.from("bk_campaign_recipients").select("*").eq("token", token).maybeSingle();
  return data;
}
const now = () => new Date().toISOString();

// Untick marketing for this email in the venue's guest book (optimistic lock: retry if staff saved in between)
async function optOut(venue: string, email: string) {
  for (let attempt = 0; attempt < 6; attempt++) {
    const { data: row } = await db.from("bk_venue_state").select("data, updated_at").eq("id", venue).maybeSingle();
    if (!row?.data || !Array.isArray(row.data.guests)) return 0;
    const t = Date.now();
    let changed = 0;
    for (const g of row.data.guests) {
      if (g && g.marketing === true && String(g.email || "").trim().toLowerCase() === email) { g.marketing = false; g._u = t; changed++; }
    }
    if (!changed) return 0;
    const { data: saved, error } = await db.from("bk_venue_state").update({ data: row.data, updated_at: new Date(t).toISOString(), updated_by: null })
      .eq("id", venue).eq("updated_at", row.updated_at).select("updated_at");
    if (error) throw error;
    if (saved?.length) return changed;
    await new Promise((r) => setTimeout(r, 250 + attempt * 400));
  }
  throw new Error("Guest book busy");
}

async function unsubscribe(r: any) {
  if (!r.unsub_at) await db.from("bk_campaign_recipients").update({ unsub_at: now() }).eq("id", r.id);
  await db.from("bk_unsubscribes").upsert({ venue: r.venue, email: r.email, campaign_id: r.campaign_id }, { onConflict: "venue,email", ignoreDuplicates: true });
  try { await optOut(r.venue, r.email); } catch (e) { console.error("optOut", e); } // still unsubscribed via bk_unsubscribes
}

async function venueName(venue: string, c?: any) {
  if (c?.from_name) return c.from_name;
  const { data } = await db.from("bk_sites").select("name").eq("id", venue).maybeSingle();
  return data?.name || "this venue";
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const url = new URL(req.url);
  const parts = url.pathname.split("/").filter(Boolean);
  const i = parts.indexOf("bk-mail");
  const [kind, raw] = i >= 0 ? parts.slice(i + 1) : parts;
  try {
    if (req.method === "GET" && kind === "o") {
      const token = String(raw || "").replace(/\.gif$/, "");
      if (TOKEN_RE.test(token)) await db.from("bk_campaign_recipients").update({ opened_at: now() }).eq("token", token).is("opened_at", null);
      return new Response(GIF, { headers: { "Content-Type": "image/gif", "Cache-Control": "no-store, max-age=0" } });
    }
    if (req.method === "GET" && kind === "c") {
      const r = await recipient(String(raw || ""));
      let to = SITE;
      if (r) {
        const { data: c } = await db.from("bk_campaigns").select("links").eq("id", r.campaign_id).maybeSingle();
        const u = (Array.isArray(c?.links) ? c.links : [])[Number(url.searchParams.get("i"))];
        if (typeof u === "string" && /^https?:\/\//i.test(u)) to = u;
        await db.from("bk_campaign_recipients").update({ clicked_at: r.clicked_at || now(), opened_at: r.opened_at || now() }).eq("id", r.id);
      }
      return new Response(null, { status: 302, headers: { Location: to, "Cache-Control": "no-store" } });
    }
    if (req.method === "POST" && kind === "u") {
      const r = await recipient(String(raw || ""));
      if (r) await unsubscribe(r);
      return new Response("Unsubscribed", { headers: { "Content-Type": "text/plain" } });
    }
    if (req.method === "POST") {
      const body = await req.json().catch(() => ({}));
      const r = await recipient(String(body.token || ""));
      if (!r) return json({ error: "This link has expired or isn’t valid." }, 404);
      const { data: c } = await db.from("bk_campaigns").select("*").eq("id", r.campaign_id).maybeSingle();
      const venue = await venueName(r.venue, c);
      if (body.action === "info") return json({ venue, email: r.email, done: !!r.unsub_at });
      if (body.action === "unsub") { await unsubscribe(r); return json({ ok: true, venue }); }
      if (body.action === "view" && c) {
        const links: string[] = Array.isArray(c.links) ? c.links : [];
        const html = renderEmail(c, { venue, recipient: r, track: { link: (u: string) => { const n = links.indexOf(u); return n < 0 ? u : `${URL_}/functions/v1/bk-mail/c/${r.token}?i=${n}`; }, unsub: `${SITE}/unsubscribe.html?t=${r.token}` } });
        return json({ html, subject: c.subject });
      }
      return json({ error: "Unknown action" }, 400);
    }
    return json({ error: "Not found" }, 404);
  } catch (e) {
    console.error(e);
    return json({ error: "Something went wrong. Please try again." }, 500);
  }
});
