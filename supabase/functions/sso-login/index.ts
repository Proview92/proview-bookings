// "Sign in with Proview account" — receiving end for bookings.
//
// dashboard.proviewcrm.co.uk signs a short-lived Ed25519 assertion "this person controls
// <email>" (only after they signed in to their confirmed Proview account). This function checks
// the signature, checks the email is an owner/manager here (public.sso_entitled), and returns a
// one-time magic-link token the app exchanges for a normal session with
// supabase.auth.verifyOtp({ token_hash, type: "magiclink" }). Staff-level users are refused.
//
//   POST { assertion } → { token_hash, email }      (assertion mode "login", single use)
//   POST { assertion } → { ok, reason }             (assertion mode "check": can this person sign in?)
//
// Deploy with verify_jwt = false (the caller isn't signed in yet). Only the public key lives here.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const APP = "bookings";
const PUBLIC_JWK = { crv: "Ed25519", x: "yAcboFvNf5YwMEut72aLrh8OhptnUkGgHFExuQaD868", kty: "OKP" };

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "content-type": "application/json" } });
const unb64u = (s: string) => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4)), (c) => c.charCodeAt(0));

let KEY: CryptoKey | null = null;
async function verify(token: string) {
  const [p, s] = String(token || "").split(".");
  if (!p || !s) return null;
  KEY ??= await crypto.subtle.importKey("jwk", PUBLIC_JWK, { name: "Ed25519" }, false, ["verify"]);
  const raw = unb64u(p);
  if (!(await crypto.subtle.verify({ name: "Ed25519" }, KEY, unb64u(s), raw))) return null;
  const c = JSON.parse(new TextDecoder().decode(raw));
  const now = Math.floor(Date.now() / 1000);
  if (c.iss !== "proview-account" || c.aud !== APP || !c.email || !c.jti) return null;
  if (!(c.exp > now) || c.exp - c.iat > 300 || c.iat > now + 60) return null;
  return c as { email: string; mode: string; jti: string; exp: number };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  try {
    const { assertion } = await req.json().catch(() => ({}));
    const c = await verify(assertion).catch(() => null);
    if (!c) return json({ error: "That sign-in link has expired. Please try again." }, 401);

    const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
    const { data: ent, error } = await db.rpc("sso_entitled", { p_email: c.email });
    if (error) throw error;
    if (c.mode === "check") return json({ ok: !!ent?.ok, reason: ent?.reason || "" });
    if (!ent?.ok) return json({ error: ent?.reason || "This email can’t use a Proview account here." }, 403);

    const used = await db.from("sso_used").insert({ jti: c.jti, email: c.email });
    if (used.error) return json({ error: "That sign-in link was already used. Please try again." }, 401);
    await db.from("sso_used").delete().lt("at", new Date(Date.now() - 864e5).toISOString());

    if (!ent.user_id && ent.create) {
      const r = await db.auth.admin.createUser({ email: c.email, email_confirm: true });
      if (r.error && !/already/i.test(r.error.message)) throw r.error;
    }
    const link = await db.auth.admin.generateLink({ type: "magiclink", email: c.email });
    if (link.error) throw link.error;
    return json({ token_hash: link.data.properties.hashed_token, email: c.email });
  } catch (e) {
    console.error(e);
    return json({ error: "Sign-in failed. Please try again." }, 500);
  }
});
