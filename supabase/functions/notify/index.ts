// Sends guest emails (Resend) and texts (Twilio) for signed-in staff.
// Secrets: RESEND_API_KEY, FROM_EMAIL, TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_FROM
import { cors, json, env, userFrom, isStaff } from "../_shared.ts";

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
            from: `${String(body.from_name || "Proview Bookings").replace(/[<>"]/g, "")} <${env("FROM_EMAIL")}>`,
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
