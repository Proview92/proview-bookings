// Twilio "A message comes in" webhook → puts the guest's reply in the venue inbox.
// Set the webhook URL in Twilio to: https://<project>.supabase.co/functions/v1/bk-sms-in?venue=<venue-id>
// Deploy with --no-verify-jwt. Secret: TWILIO_AUTH_TOKEN (used to check the request really came from Twilio).
import { env, db } from "../_shared.ts";

async function validTwilio(req: Request, params: URLSearchParams) {
  const sig = req.headers.get("X-Twilio-Signature") || "";
  const u = new URL(req.url);
  const url = `${env("SUPABASE_URL")}/functions/v1/bk-sms-in${u.search}`; // the public URL Twilio signed
  const data = url + [...params.keys()].sort().map((k) => k + params.get(k)).join("");
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(env("BK_TWILIO_AUTH_TOKEN")), { name: "HMAC", hash: "SHA-1" }, false, ["sign"]);
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(data));
  return btoa(String.fromCharCode(...new Uint8Array(mac))) === sig;
}

Deno.serve(async (req) => {
  const venue = new URL(req.url).searchParams.get("venue") || "";
  const params = new URLSearchParams(await req.text());
  if (!(await validTwilio(req, params))) return new Response("Forbidden", { status: 403 });
  await db("bk_inbox", { method: "POST", body: JSON.stringify({ venue, kind: "sms", payload: { from: params.get("From"), body: params.get("Body") } }) });
  return new Response("<Response></Response>", { headers: { "Content-Type": "text/xml" } });
});
