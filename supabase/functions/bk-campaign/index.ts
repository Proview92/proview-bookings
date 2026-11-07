// Proview Bookings email campaigns: sending.
//
// Called by managers from the Bookings app (their own login) and every minute by pg_cron.
//   POST { action: "status" }                     → { configured, from }
//   POST { action: "test", id, email }            → sends one [TEST] copy
//   POST { action: "send", id }                   → freezes the audience (guests who agreed to marketing) and starts sending
//   POST { action: "cancel", id }                 → stops a campaign that is sending
//   POST { action: "tick" } + x-bk-tick header    → starts due scheduled campaigns and sends queued emails (cron)
// Emails go out through Resend (secrets BK_RESEND_API_KEY, BK_FROM_EMAIL), the same as booking emails.
// Deployed with verify_jwt = false: it checks the caller itself (manager login, or the cron secret).
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
import { renderEmail, renderText, subjectFor, normaliseDesign } from "./render.js";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const env = (k: string) => Deno.env.get(k) ?? "";
const URL_ = env("SUPABASE_URL");
const MAIL_FN = `${URL_}/functions/v1/bk-mail`;
const SITE = "https://bookings.proviewcrm.co.uk";
const db = createClient(URL_, env("SUPABASE_SERVICE_ROLE_KEY"), { auth: { persistSession: false } });
const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

// ---------- who is calling ----------
async function managerOf(req: Request, venue: string) {
  const auth = req.headers.get("Authorization") || "";
  if (!auth.startsWith("Bearer ")) return false;
  const r = await fetch(`${URL_}/rest/v1/rpc/bk_is_admin`, {
    method: "POST", headers: { apikey: env("SUPABASE_ANON_KEY"), Authorization: auth, "Content-Type": "application/json" },
    body: JSON.stringify({ v: venue }),
  });
  return r.ok && (await r.json()) === true;
}
let SECRET = "";
async function secret() {
  if (!SECRET) { const { data, error } = await db.rpc("bk_mail_secret"); if (error) throw error; SECRET = String(data); }
  return SECRET;
}

// ---------- email ----------
const fromAddr = () => env("BK_FROM_EMAIL") || "bookings@proviewcrm.co.uk";
const fromHeader = (c: any, venue: string) => `${String(c.from_name || venue || "Proview Bookings").replace(/["\r\n<>]/g, "")} <${fromAddr()}>`;
function trackFor(c: any, token: string) {
  const links: string[] = Array.isArray(c.links) ? c.links : [];
  return {
    link: (u: string) => { const i = links.indexOf(u); return i < 0 ? u : `${MAIL_FN}/c/${token}?i=${i}`; },
    unsub: `${SITE}/unsubscribe.html?t=${token}`,
    view: `${SITE}/email.html?t=${token}`,
    pixel: `${MAIL_FN}/o/${token}.gif`,
  };
}
function message(c: any, venue: string, rc: { email: string; name: string; token: string }, test = false) {
  const track = test ? { unsub: `${SITE}/unsubscribe.html?t=test`, view: "" } : trackFor(c, rc.token);
  const msg: any = {
    from: fromHeader(c, venue), to: [rc.email],
    subject: (test ? "[TEST] " : "") + subjectFor(c, rc, venue),
    html: renderEmail(c, { venue, recipient: rc, track }),
    text: renderText(c, { venue, recipient: rc, track }),
  };
  if (c.reply_to && EMAIL_RE.test(c.reply_to)) msg.reply_to = c.reply_to;
  if (!test) msg.headers = { "List-Unsubscribe": `<${MAIL_FN}/u/${rc.token}>`, "List-Unsubscribe-Post": "List-Unsubscribe=One-Click" };
  return msg;
}
async function resendBatch(msgs: any[]) {
  const key = env("BK_RESEND_API_KEY");
  if (!key) throw new Error("Email sending isn’t switched on yet (BK_RESEND_API_KEY)");
  const r = await fetch(msgs.length === 1 ? "https://api.resend.com/emails" : "https://api.resend.com/emails/batch", {
    method: "POST", headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify(msgs.length === 1 ? msgs[0] : msgs),
  });
  if (!r.ok) throw new Error(`Resend ${r.status}: ${(await r.text()).slice(0, 300)}`);
}

// ---------- campaigns ----------
async function getCampaign(id: string) {
  const { data, error } = await db.from("bk_campaigns").select("*").eq("id", id).maybeSingle();
  if (error) throw error;
  return data;
}
async function venueName(venue: string) {
  const { data } = await db.from("bk_sites").select("name").eq("id", venue).maybeSingle();
  return data?.name || "";
}

// Guests at this venue who agreed to marketing (one email each), minus anyone who unsubscribed
async function audience(venue: string) {
  const { data: row, error } = await db.from("bk_venue_state").select("guests:data->guests, del:data->_del").eq("id", venue).maybeSingle();
  if (error) throw error;
  const del = row?.del && typeof row.del === "object" ? row.del : {};
  const { data: gone } = await db.from("bk_unsubscribes").select("email").eq("venue", venue);
  const out = new Set((gone || []).map((g: any) => g.email));
  const seen = new Map<string, { guest_id: string; email: string; name: string }>();
  for (const g of Array.isArray(row?.guests) ? row.guests : []) {
    const email = String(g?.email || "").trim().toLowerCase();
    if (!g || g.marketing !== true || !EMAIL_RE.test(email) || del[g.id] || out.has(email) || seen.has(email)) continue;
    seen.set(email, { guest_id: String(g.id || ""), email, name: String(g.name || "").slice(0, 120) });
  }
  return [...seen.values()];
}

// Every tracked link in the design, frozen when sending starts (clicks redirect by index: no open redirects)
function collectLinks(c: any) {
  const links: string[] = [];
  renderEmail(c, { track: { link: (u: string) => { if (/^https?:/i.test(u) && !links.includes(u)) links.push(u); return u; } } });
  return links.slice(0, 200);
}

async function start(c: any) {
  const people = await audience(c.venue);
  const links = collectLinks(c);
  await db.from("bk_campaign_recipients").delete().eq("campaign_id", c.id);
  for (let i = 0; i < people.length; i += 500) {
    const { error } = await db.from("bk_campaign_recipients").insert(people.slice(i, i + 500).map((p) => ({ ...p, campaign_id: c.id, venue: c.venue })));
    if (error) throw error;
  }
  const { error } = await db.from("bk_campaigns").update({ status: people.length ? "sending" : "sent", started_at: new Date().toISOString(), finished_at: people.length ? null : new Date().toISOString(), scheduled_at: null, links }).eq("id", c.id);
  if (error) throw error;
  return people.length;
}

// Send queued emails for up to `ms` milliseconds
async function work(ms: number, onlyId?: string) {
  const until = Date.now() + ms;
  let q = db.from("bk_campaigns").select("*").eq("status", "sending").order("started_at");
  if (onlyId) q = q.eq("id", onlyId);
  const { data: list } = await q;
  for (const c of list || []) {
    const venue = await venueName(c.venue);
    while (Date.now() < until) {
      const { data: batch, error } = await db.rpc("bk_claim_recipients", { p_campaign: c.id, p_n: 100 });
      if (error) throw error;
      if (!batch?.length) break;
      // skip anyone who unsubscribed after the list was frozen
      const { data: gone } = await db.from("bk_unsubscribes").select("email").eq("venue", c.venue).in("email", batch.map((r: any) => r.email));
      const out = new Set((gone || []).map((g: any) => g.email));
      const skip = batch.filter((r: any) => out.has(r.email)), go = batch.filter((r: any) => !out.has(r.email));
      if (skip.length) await db.from("bk_campaign_recipients").update({ status: "skipped", error: "Unsubscribed" }).in("id", skip.map((r: any) => r.id));
      if (go.length) {
        try {
          await resendBatch(go.map((r: any) => message(c, venue, r)));
          await db.from("bk_campaign_recipients").update({ status: "sent", sent_at: new Date().toISOString() }).in("id", go.map((r: any) => r.id));
        } catch (e) {
          const msg = String((e as Error).message).slice(0, 300);
          await db.from("bk_campaign_recipients").update({ status: "failed", error: msg }).in("id", go.map((r: any) => r.id));
          if (/BK_RESEND_API_KEY|401|403/.test(msg)) break; // not set up: stop, don't burn through the list
        }
        await new Promise((r) => setTimeout(r, 600)); // stay under Resend's rate limit
      }
    }
    const { count } = await db.from("bk_campaign_recipients").select("id", { count: "exact", head: true }).eq("campaign_id", c.id).eq("status", "pending");
    if (!count) await db.from("bk_campaigns").update({ status: "sent", finished_at: new Date().toISOString() }).eq("id", c.id).eq("status", "sending");
    if (Date.now() >= until) break;
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  try {
    const body = await req.json().catch(() => ({}));
    const action = String(body.action || "");

    if (action === "tick") {
      if (!req.headers.get("x-bk-tick") || req.headers.get("x-bk-tick") !== (await secret())) return json({ error: "Not allowed" }, 403);
      const { data: due } = await db.from("bk_campaigns").select("*").eq("status", "scheduled").lte("scheduled_at", new Date().toISOString());
      for (const c of due || []) await start(c);
      await work(45_000);
      return json({ ok: true, started: (due || []).length });
    }
    if (action === "status") return json({ configured: !!env("BK_RESEND_API_KEY"), from: fromAddr() });

    const c = await getCampaign(String(body.id || ""));
    if (!c) return json({ error: "Campaign not found" }, 404);
    if (!(await managerOf(req, c.venue))) return json({ error: "Only owners and managers can send campaigns." }, 403);

    if (action === "test") {
      const email = String(body.email || "").trim().toLowerCase();
      if (!EMAIL_RE.test(email)) return json({ error: "Enter a valid email address." }, 400);
      const venue = await venueName(c.venue);
      await resendBatch([message(c, venue, { email, name: "Alex Example", token: "test" }, true)]);
      return json({ ok: true });
    }
    if (action === "send") {
      if (!["draft", "scheduled"].includes(c.status)) return json({ error: "This campaign has already been sent." }, 409);
      if (!env("BK_RESEND_API_KEY")) return json({ error: "Email sending isn’t switched on yet. Ask Proview to connect your email sending." }, 409);
      if (!String(c.subject || "").trim()) return json({ error: "Add a subject line first." }, 400);
      if (!normaliseDesign(c.design).blocks.length) return json({ error: "Your email has no content." }, 400);
      const n = await start(c);
      await work(40_000, c.id); // the rest is sent by the every-minute job
      return json({ ok: true, recipients: n });
    }
    if (action === "cancel") {
      if (c.status !== "sending") return json({ error: "This campaign isn’t sending." }, 409);
      await db.from("bk_campaigns").update({ status: "cancelled", finished_at: new Date().toISOString() }).eq("id", c.id);
      await db.from("bk_campaign_recipients").update({ status: "skipped", error: "Stopped" }).eq("campaign_id", c.id).eq("status", "pending");
      return json({ ok: true });
    }
    return json({ error: "Unknown action" }, 400);
  } catch (e) {
    console.error(e);
    return json({ error: String((e as Error).message || e).slice(0, 300) }, 500);
  }
});
