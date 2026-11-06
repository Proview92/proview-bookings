// Creates a Stripe Checkout page for a booking deposit. Called by the public booking page.
// Deploy with --no-verify-jwt. Secret: STRIPE_SECRET_KEY
import { cors, json, env, db } from "../_shared.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const { venue, booking, return_url } = await req.json();
    const rows = await db(`venue_public?id=eq.${encodeURIComponent(venue)}&select=data`);
    const pub = rows?.[0]?.data;
    if (!pub) return json({ error: "Unknown venue" }, 404);
    const B = pub.settings.bookings;
    const size = Math.max(1, Math.min(500, Math.round(+booking.size || 0)));
    if (B.policy !== "deposit" || size < +B.policyFrom) return json({ error: "No deposit needed" }, 400);
    const pence = Math.round(+B.policyAmount * 100);
    const back = String(return_url || "").split("?")[0];
    const small = { ...booking, notes: String(booking.notes || "").slice(0, 120) };
    const form = new URLSearchParams({
      mode: "payment",
      "line_items[0][quantity]": String(size),
      "line_items[0][price_data][currency]": "gbp",
      "line_items[0][price_data][unit_amount]": String(pence),
      "line_items[0][price_data][product_data][name]": `Deposit · ${pub.venue.name} · ${booking.date} ${booking.time}`,
      customer_email: String(booking.email || ""),
      success_url: `${back}?paid=1&v=${encodeURIComponent(venue)}`,
      cancel_url: `${back}?v=${encodeURIComponent(venue)}`,
      "metadata[venue]": venue,
      "metadata[booking]": JSON.stringify(small).slice(0, 500),
    });
    const r = await fetch("https://api.stripe.com/v1/checkout/sessions", {
      method: "POST", headers: { Authorization: `Bearer ${env("STRIPE_SECRET_KEY")}`, "Content-Type": "application/x-www-form-urlencoded" }, body: form,
    });
    const s = await r.json();
    if (!r.ok) return json({ error: s.error?.message || "Stripe error" }, 400);
    return json({ url: s.url });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
