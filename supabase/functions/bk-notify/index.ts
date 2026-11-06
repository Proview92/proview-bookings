// Sends guest emails (Resend) and texts (Twilio) for signed-in staff.
// Secrets: RESEND_API_KEY, FROM_EMAIL, TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_FROM
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
    if (body.email?.to) {
      if (!env("RESEND_API_KEY")) out.email = "skipped: RESEND_API_KEY not set";
      else {
        const r = await fetch("https://api.resend.com/emails", {
          method: "POST",
          headers: { Authorization: `Bearer ${env("RESEND_API_KEY")}`, "Content-Type": "application/json" },
          body: JSON.stringify({
            from: `${String(body.from_name || "Proview Bookings").replace(/[<>"]/g, "")} <${env("FROM_EMAIL") || "bookings@proviewcrm.co.uk"}>`,
            to: [body.email.to], subject: String(body.email.subject).slice(0, 200),
            text: String(body.email.text || "").slice(0, 20000), html: body.email.html,
          }),
        });
        out.email = r.ok ? "sent" : `failed: ${await r.text()}`;
      }
    }
    if (body.sms?.to) {
      if (!env("TWILIO_ACCOUNT_SID")) out.sms = "skipped: Twilio not set";
      else {
        let to = String(body.sms.to).replace(/[^\d+]/g, "");
        if (to.startsWith("07")) to = "+44" + to.slice(1); // UK mobiles
        const form = new URLSearchParams({ To: to, From: env("TWILIO_FROM"), Body: String(body.sms.body).slice(0, 640) });
        const r = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${env("TWILIO_ACCOUNT_SID")}/Messages.json`, {
          method: "POST",
          headers: { Authorization: "Basic " + btoa(`${env("TWILIO_ACCOUNT_SID")}:${env("TWILIO_AUTH_TOKEN")}`), "Content-Type": "application/x-www-form-urlencoded" },
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
