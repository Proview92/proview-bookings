// Stripe webhook: when a deposit is paid, adds the booking to the venue inbox.
// In Stripe → Developers → Webhooks, add endpoint https://<project>.supabase.co/functions/v1/stripe-webhook
// for event checkout.session.completed. Deploy with --no-verify-jwt. Secret: STRIPE_WEBHOOK_SECRET
import { env, db } from "../_shared.ts";

async function verify(payload: string, header: string) {
  const parts = Object.fromEntries(header.split(",").map((p) => p.split("=") as [string, string]));
  if (!parts.t || !parts.v1 || Math.abs(Date.now() / 1000 - +parts.t) > 300) return false;
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(env("STRIPE_WEBHOOK_SECRET")), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${parts.t}.${payload}`)));
  const hex = [...mac].map((b) => b.toString(16).padStart(2, "0")).join("");
  return hex === parts.v1;
}

Deno.serve(async (req) => {
  const payload = await req.text();
  if (!(await verify(payload, req.headers.get("Stripe-Signature") || ""))) return new Response("Bad signature", { status: 400 });
  const evt = JSON.parse(payload);
  if (evt.type === "checkout.session.completed") {
    const s = evt.data.object;
    const booking = JSON.parse(s.metadata?.booking || "{}");
    await db("inbox", {
      method: "POST",
      body: JSON.stringify({ venue: s.metadata?.venue, kind: "booking", payload: { ...booking, deposit_paid: (s.amount_total || 0) / 100, deposit_ref: s.id } }),
    });
  }
  return new Response("ok");
});
