// Shared helpers for Proview Bookings edge functions.
export const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
export const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
export const env = (k: string) => Deno.env.get(k) ?? "";
const SB = () => ({ url: env("SUPABASE_URL"), service: env("SUPABASE_SERVICE_ROLE_KEY") });

// Calls the database with the service role (server only).
export async function db(path: string, init: RequestInit = {}) {
  const { url, service } = SB();
  const r = await fetch(`${url}/rest/v1/${path}`, {
    ...init,
    headers: { apikey: service, Authorization: `Bearer ${service}`, "Content-Type": "application/json", Prefer: "return=representation", ...(init.headers || {}) },
  });
  if (!r.ok) throw new Error(`db ${r.status}: ${await r.text()}`);
  return r.status === 204 ? null : r.json();
}
// Returns the signed-in user for the request, or null.
export async function userFrom(req: Request) {
  const auth = req.headers.get("Authorization") || "";
  if (!auth.startsWith("Bearer ")) return null;
  const r = await fetch(`${env("SUPABASE_URL")}/auth/v1/user`, { headers: { Authorization: auth, apikey: env("SUPABASE_ANON_KEY") } });
  return r.ok ? await r.json() : null;
}
export async function isStaff(userId: string, venue: string) {
  const rows = await db(`bk_staff_profiles?user_id=eq.${userId}&venue=eq.${encodeURIComponent(venue)}&select=user_id`);
  return Array.isArray(rows) && rows.length > 0;
}
