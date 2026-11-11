// Deno tests for sso-login's master-open hand-off (MASTER_OPEN_PROTOCOL.md), against mocks.
// The function's real Ed25519 verify runs on assertions signed by a throw-away key: the test loads index.ts
// with only PUBLIC_JWK swapped for that key's public half. Supabase (rpc, tables, auth admin) is a stubbed fetch.
//   deno test -A supabase/functions/sso-login/index.test.ts
import { assert, assertEquals } from "jsr:@std/assert@1";

const APP = "bookings";
const kp = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]) as CryptoKeyPair;
const pub = await crypto.subtle.exportKey("jwk", kp.publicKey);
const b64u = (b: Uint8Array) => btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
async function sign(claims: Record<string, unknown>, key = kp.privateKey) {
  const p = new TextEncoder().encode(JSON.stringify(claims));
  return b64u(p) + "." + b64u(new Uint8Array(await crypto.subtle.sign({ name: "Ed25519" }, key, p)));
}
const now = () => Math.floor(Date.now() / 1000);
const claims = (email: string, extra: Record<string, unknown> = {}) =>
  ({ iss: "proview-account", aud: APP, email, mode: "login", iat: now(), exp: now() + 120, jti: crypto.randomUUID(), ...extra });

// people in this app: master (bk_master_admins), an owner, and a staff login
const PEOPLE: Record<string, { id: string; admin: boolean; ok: boolean; reason?: string }> = {
  "master@proview.test": { id: "u-master", admin: true, ok: true },
  "owner@cafe.test": { id: "u-owner", admin: false, ok: true },
  "staff@cafe.test": { id: "u-staff", admin: false, ok: false, reason: "This is an editor login in Signage." },
};
const used = new Set<string>();
Deno.env.set("SUPABASE_URL", "http://mock.local");
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "service");
globalThis.fetch = async (input: Request | URL | string, init?: RequestInit) => {
  const req = new Request(input, init);
  const url = new URL(req.url);
  const body = ["POST", "PATCH"].includes(req.method) ? await req.clone().json().catch(() => null) : null;
  const j = (b: unknown, s = 200) => new Response(b === undefined ? null : JSON.stringify(b), { status: s, headers: { "content-type": "application/json" } });
  if (url.pathname === "/rest/v1/rpc/sso_entitled") {
    const p = PEOPLE[body.p_email]; return j(p ? { ok: p.ok, reason: p.reason || "", user_id: p.id } : { ok: false, reason: "No account" });
  }
  if (url.pathname === "/rest/v1/sso_used" && req.method === "POST") {
    if (used.has(body.jti)) return j({ code: "23505", message: "duplicate key" }, 409);
    used.add(body.jti); return j(undefined, 201);
  }
  if (url.pathname === "/rest/v1/sso_used" && req.method === "DELETE") return j(undefined, 204);
  if (url.pathname === "/rest/v1/bk_master_admins") {
    const id = (url.searchParams.get("user_id") || "").replace(/^eq\./, "");
    const p = Object.values(PEOPLE).find((x) => x.id === id);
    return j(p && p.admin ? [{ user_id: p.id }] : []);
  }
  if (url.pathname === "/auth/v1/admin/generate_link") return j({ hashed_token: "hash-" + body.email, action_link: "x", id: "u", email: body.email });
  if (url.pathname === "/auth/v1/admin/users") return j({ id: "u-new", email: body.email });
  return j({ message: "mock: no route " + req.method + " " + req.url }, 404);
};

// load the real function with only the public key swapped
const src = await Deno.readTextFile(new URL("./index.ts", import.meta.url));
const patched = src.replace(/const PUBLIC_JWK = \{[^}]*\};/, `const PUBLIC_JWK = ${JSON.stringify({ crv: pub.crv, x: pub.x, kty: pub.kty })};`);
assert(patched !== src, "PUBLIC_JWK found");
const tmp = await Deno.makeTempFile({ suffix: ".ts" });
await Deno.writeTextFile(tmp, patched);
let handler!: (r: Request) => Promise<Response>;
(Deno as unknown as { serve: unknown }).serve = (h: typeof handler) => { handler = h; };
await import("file://" + tmp);

const call = async (assertion: string) => {
  const r = await handler(new Request("http://fn.local/", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ assertion }) }));
  return { status: r.status, body: await r.json() };
};

Deno.test("master + biz: signed in and told which business to open", async () => {
  const r = await call(await sign(claims("master@proview.test", { biz: "c-111" })));
  assertEquals(r.status, 200);
  assertEquals(r.body.token_hash, "hash-master@proview.test");
  assertEquals(r.body.open, "c-111");
});

Deno.test("master without biz: signed in, no open (app shows 'Open a customer from the licence portal')", async () => {
  const r = await call(await sign(claims("master@proview.test")));
  assertEquals(r.status, 200); assert(!("open" in r.body));
});

Deno.test("biz on a non-master assertion is ignored", async () => {
  const r = await call(await sign(claims("owner@cafe.test", { biz: "c-other" })));
  assertEquals(r.status, 200); assertEquals(r.body.token_hash, "hash-owner@cafe.test"); assert(!("open" in r.body));
});

Deno.test("staff stay refused, with or without biz", async () => {
  const r = await call(await sign(claims("staff@cafe.test", { biz: "c-111" })));
  assertEquals(r.status, 403); assert(!r.body.token_hash && !r.body.open);
});

Deno.test("signature is really checked: wrong key, tampered biz, wrong audience", async () => {
  const other = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]) as CryptoKeyPair;
  assertEquals((await call(await sign(claims("master@proview.test", { biz: "c-1" }), other.privateKey))).status, 401);
  // swap the payload for one with a different biz, keep the old signature
  const good = await sign(claims("master@proview.test", { biz: "c-1" }));
  const forged = b64u(new TextEncoder().encode(JSON.stringify(claims("master@proview.test", { biz: "c-2" })))) + "." + good.split(".")[1];
  assertEquals((await call(forged)).status, 401);
  assertEquals((await call(await sign({ ...claims("master@proview.test", { biz: "c-1" }), aud: "some-other-app" }))).status, 401);
});

Deno.test("single use: the same assertion can't be replayed", async () => {
  const t = await sign(claims("master@proview.test", { biz: "c-1" }));
  assertEquals((await call(t)).status, 200);
  assertEquals((await call(t)).status, 401);
});

Deno.test("bad biz values are ignored (no open)", async () => {
  for (const biz of [{ x: 1 }, "", "   ", "x".repeat(201), null]) {
    const r = await call(await sign(claims("master@proview.test", { biz })));
    assertEquals(r.status, 200); assert(!("open" in r.body), JSON.stringify(biz));
  }
  const n = await call(await sign(claims("master@proview.test", { biz: 42 })));
  assertEquals(n.body.open, "42");
});

Deno.test("check mode unchanged", async () => {
  const r = await call(await sign(claims("master@proview.test", { mode: "check" })));
  assertEquals(r.body, { ok: true, reason: "" });
});
