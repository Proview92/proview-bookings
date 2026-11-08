// Sends guest emails (Resend) and texts (Twilio) for signed-in staff.
// Secrets (BK_ prefix keeps them apart from the till): BK_RESEND_API_KEY, BK_FROM_EMAIL, BK_TWILIO_ACCOUNT_SID, BK_TWILIO_AUTH_TOKEN, BK_TWILIO_FROM
// Shared helpers for Proview Bookings edge functions.
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const env = (k: string) => Deno.env.get(k) ?? "";
const SB = () => ({ url: env("SUPABASE_URL"), service: env("SUPABASE_SERVICE_ROLE_KEY") });

// Calls the database with the service role (server only).
async function db(path: string, init: RequestInit = {}) {
  const { url, service } = SB();
  const r = await fetch(`${url}/rest/v1/${path}`, {
    ...init,
    headers: { apikey: service, Authorization: `Bearer ${service}`, "Content-Type": "application/json", Prefer: "return=representation", ...(init.headers || {}) },
  });
  if (!r.ok) throw new Error(`db ${r.status}: ${await r.text()}`);
  return r.status === 204 ? null : r.json();
}
// Returns the signed-in user for the request, or null.
async function userFrom(req: Request) {
  const auth = req.headers.get("Authorization") || "";
  if (!auth.startsWith("Bearer ")) return null;
  const r = await fetch(`${env("SUPABASE_URL")}/auth/v1/user`, { headers: { Authorization: auth, apikey: env("SUPABASE_ANON_KEY") } });
  return r.ok ? await r.json() : null;
}
async function isStaff(userId: string, venue: string) {
  const rows = await db(`bk_staff_profiles?user_id=eq.${userId}&venue=eq.${encodeURIComponent(venue)}&select=user_id`);
  return Array.isArray(rows) && rows.length > 0;
}


Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const user = await userFrom(req);
    const body = await req.json();
    if (!user || !(await isStaff(user.id, body.venue))) return json({ error: "Not allowed" }, 403);
    const out: Record<string, unknown> = {};
    // People without the guests feature never see contact details: the app sends the guest's id
    // and the address is looked up here (bk_guests, supabase/005_guest_privacy.sql).
    if ((body.email && !body.email.to && body.email.guest) || (body.sms && !body.sms.to && body.sms.guest)) {
      const id = String(body.email?.guest || body.sms?.guest);
      const rows = await db(`bk_guests?venue=eq.${encodeURIComponent(body.venue)}&id=eq.${encodeURIComponent(id)}&select=data`);
      const g = Array.isArray(rows) && rows[0] ? rows[0].data : null;
      if (body.email && !body.email.to) { body.email.to = String(g?.email || "").trim(); if (!body.email.to) out.email = "skipped: no email address"; }
      if (body.sms && !body.sms.to) { body.sms.to = String(g?.phone || "").trim(); if (!body.sms.to) out.sms = "skipped: no phone number"; }
    }
    if (body.email?.to) {   // the manage-booking link carries the address: {{guest_email}}
      const enc = encodeURIComponent(String(body.email.to));
      body.email.text = String(body.email.text || "").split("{{guest_email}}").join(enc);
      if (typeof body.email.html === "string") body.email.html = body.email.html.split("{{guest_email}}").join(enc);
    }
    if (body.email?.to) {
      const key = env("BK_RESEND_API_KEY");
      if (!key) out.email = "skipped: BK_RESEND_API_KEY not set";
      else {
        const r = await fetch("https://api.resend.com/emails", {
          method: "POST",
          headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
          body: JSON.stringify({
            from: `${String(body.from_name || "Proview Bookings").replace(/[<>"]/g, "")} <${env("BK_FROM_EMAIL") || "bookings@proviewcrm.co.uk"}>`,
            to: [body.email.to], subject: String(body.email.subject).slice(0, 200),
            text: String(body.email.text || "").slice(0, 20000), html: body.email.html,
          }),
        });
        out.email = r.ok ? "sent" : `failed: ${await r.text()}`;
      }
    }
    if (body.sms?.to) {
      if (!env("BK_TWILIO_ACCOUNT_SID")) out.sms = "skipped: Twilio not set";
      else {
        let to = String(body.sms.to).replace(/[^\d+]/g, "");
        if (to.startsWith("07")) to = "+44" + to.slice(1); // UK mobiles
        const form = new URLSearchParams({ To: to, From: env("BK_TWILIO_FROM"), Body: String(body.sms.body).slice(0, 640) });
        const r = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${env("BK_TWILIO_ACCOUNT_SID")}/Messages.json`, {
          method: "POST",
          headers: { Authorization: "Basic " + btoa(`${env("BK_TWILIO_ACCOUNT_SID")}:${env("BK_TWILIO_AUTH_TOKEN")}`), "Content-Type": "application/x-www-form-urlencoded" },
          body: form,
        });
        out.sms = r.ok ? "sent" : `failed: ${await r.text()}`;
      }
    }
    return json({ ok: true, ...out });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
