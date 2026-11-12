// Headless test harness (Playwright + headless Chrome): a static server for an app's web root plus an in-memory
// mock of its Supabase project (auth, PostgREST tables + RPCs, sso-login), wired in through Playwright routing.
// Every request and response body is logged, so a test can prove another business's data never reached the page.
// Playwright: PLAYWRIGHT=<path to the playwright package>, else the one installed for the Proview test runs.
const { chromium } = require(process.env.PLAYWRIGHT || '/opt/npm-tools/node_modules/playwright');
const http = require('http');
const fs = require('fs');
const path = require('path');

const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.png': 'image/png', '.json': 'application/json', '.webmanifest': 'application/json' };
function serveStatic(root, port) {
  return new Promise((res) => {
    const srv = http.createServer((req, rsp) => {
      let p = decodeURIComponent(new URL(req.url, 'http://x').pathname);
      if (p.endsWith('/')) p += 'index.html';
      const f = path.join(root, p);
      if (!f.startsWith(root) || !fs.existsSync(f) || fs.statSync(f).isDirectory()) { rsp.writeHead(404); return rsp.end('nf'); }
      rsp.writeHead(200, { 'content-type': MIME[path.extname(f)] || 'application/octet-stream', 'cache-control': 'no-store' });
      fs.createReadStream(f).pipe(rsp);
    }).listen(port, '127.0.0.1', () => res(srv));
  });
}

// PostgREST filter subset
function cellMatch(cell, opv) {
  const neg = opv.startsWith('not.'); if (neg) opv = opv.slice(4);
  const i = opv.indexOf('.'); const op = opv.slice(0, i), v = opv.slice(i + 1);
  let r;
  if (op === 'eq') r = String(cell) === v;
  else if (op === 'neq') r = String(cell) !== v;
  else if (op === 'is') r = v === 'null' ? cell == null : v === 'true' ? cell === true : v === 'false' ? cell === false : false;
  else if (op === 'in') { const list = v.replace(/^\(|\)$/g, '').split(',').map((x) => x.replace(/^"|"$/g, '')); r = list.includes(String(cell)); }
  else if (op === 'lt') r = cell != null && String(cell) < v;
  else if (op === 'lte') r = cell != null && String(cell) <= v;
  else if (op === 'gt') r = cell != null && String(cell) > v;
  else if (op === 'gte') r = cell != null && String(cell) >= v;
  else if (op === 'cs') { const want = JSON.parse(v.replace(/^\{/, '[').replace(/\}$/, ']')); r = Array.isArray(cell) && want.every((w) => cell.includes(w)); }
  else if (op === 'ilike' || op === 'like') { const re = new RegExp('^' + v.replace(/[.+?^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*').replace(/%/g, '.*') + '$', 'i'); r = re.test(String(cell ?? '')); }
  else r = true;
  return neg ? !r : r;
}
function orMatch(row, expr) {   // or=(a.eq.1,b.eq.2)
  const parts = expr.replace(/^\(|\)$/g, '').split(/,(?![^(]*\))/);
  return parts.some((p) => { const i = p.indexOf('.'); return cellMatch(row[p.slice(0, i)], p.slice(i + 1)); });
}
const SKIP = new Set(['select', 'order', 'limit', 'offset', 'on_conflict', 'columns']);
function filterRows(rows, sp) {
  let out = rows.filter((r) => [...sp].every(([k, v]) => SKIP.has(k) ? true : k === 'or' ? orMatch(r, v) : cellMatch(r[k], v)));
  const off = +(sp.get('offset') || 0), lim = sp.get('limit'); out = out.slice(off, lim ? off + +lim : undefined);
  return out;
}

/**
 * startMock({ users: { token: user }, tables: { name: rows[] }, rls: (table, row, user) => bool,
 *             rpc: { name: (args, user) => value }, ssoLogin: (body) => { status, body } })
 */
function makeMock(cfg) {
  const log = [];
  const S = { sessions: {} };
  const userOf = (req) => { const a = (req.headers()['authorization'] || '').replace(/^Bearer\s+/i, ''); return cfg.users[a] || S.sessions[a] || null; };
  async function handle(route) {
    const req = route.request();
    const url = new URL(req.url());
    const p = url.pathname;
    let body = null; try { body = req.postData() ? JSON.parse(req.postData()) : null; } catch { body = req.postData(); }
    const user = userOf(req);
    const send = (status, b, headers = {}) => {
      const text = b === undefined ? '' : JSON.stringify(b);
      log.push({ method: req.method(), url: req.url(), status, req: body, res: text, user: user?.email || null });
      return route.fulfill({ status, body: text, headers: { 'content-type': 'application/json', 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': '*', ...headers } });
    };
    if (req.method() === 'OPTIONS') return send(200, {});
    if (p === '/auth/v1/user') return user ? send(200, user) : send(401, { message: 'bad jwt' });
    if (p === '/auth/v1/logout') return send(204);
    if (p === '/auth/v1/verify') {
      const u = cfg.otp?.[body.token_hash]; if (!u) return send(400, { msg: 'bad otp' });
      const tok = 'sess-' + u.id + '-' + Math.random().toString(36).slice(2); S.sessions[tok] = u;
      return send(200, { access_token: tok, token_type: 'bearer', expires_in: 3600, expires_at: Math.floor(Date.now() / 1000) + 3600, refresh_token: 'r-' + tok, user: u });
    }
    if (p === '/auth/v1/token' && url.searchParams.get('grant_type') === 'password') {   // password sign-in
      const u = cfg.passwords?.[String(body?.email || '').toLowerCase()]; if (!u || body.password !== cfg.passwordOf?.(u)) return send(400, { error: 'invalid_grant', error_description: 'Invalid login credentials', msg: 'Invalid login credentials' });
      const tok = 'sess-' + u.id + '-' + Math.random().toString(36).slice(2); S.sessions[tok] = u;
      return send(200, { access_token: tok, token_type: 'bearer', expires_in: 3600, expires_at: Math.floor(Date.now() / 1000) + 3600, refresh_token: 'r-' + tok, user: u });
    }
    if (p === '/auth/v1/token') return send(400, { msg: 'no refresh in mock' });
    if (p.startsWith('/functions/v1/sso-login')) { const r = cfg.ssoLogin(body); return send(r.status, r.body); }
    if (p.startsWith('/functions/v1/')) return send(404, { error: 'no fn' });
    let m;
    if ((m = p.match(/^\/rest\/v1\/rpc\/(\w+)$/))) {
      const f = cfg.rpc[m[1]];
      if (!f) return send(404, { code: 'PGRST202', message: 'Could not find the function ' + m[1] });
      try { const v = f(body || Object.fromEntries(url.searchParams), user); return send(200, v === undefined ? null : v); }
      catch (e) { return send(400, { message: e.message }); }
    }
    if ((m = p.match(/^\/rest\/v1\/(\w+)$/))) {
      const t = m[1]; const rows = (cfg.tables[t] || []).filter((r) => !cfg.rls || cfg.rls(t, r, user));
      const accept = req.headers()['accept'] || '';
      const prefer = req.headers()['prefer'] || '';
      if (req.method() === 'GET' || req.method() === 'HEAD') {
        let out = filterRows(rows, url.searchParams);
        const range = req.headers()['range']; if (range) { const [a, b] = range.split('-').map(Number); out = out.slice(a, b + 1); }
        const headers = prefer.includes('count=') ? { 'content-range': `0-${Math.max(out.length - 1, 0)}/${out.length}` } : {};
        if (accept.includes('vnd.pgrst.object')) return out.length === 1 ? send(200, out[0], headers) : send(406, { code: 'PGRST116', message: 'not one row' });
        return send(200, req.method() === 'HEAD' ? undefined : out, headers);
      }
      if (req.method() === 'POST') { const list = Array.isArray(body) ? body : [body]; const T = (cfg.tables[t] ||= []);
        const keys = (url.searchParams.get('on_conflict') || '').split(',').filter(Boolean);
        for (const r of list) { const ex = keys.length && T.find((x) => keys.every((k) => String(x[k]) === String(r[k]))); if (ex) Object.assign(ex, r); else T.push(r); } return send(201, prefer.includes('representation') ? (accept.includes('vnd.pgrst.object') ? list[0] : list) : undefined); }
      if (req.method() === 'PATCH') { const hit = filterRows(rows, url.searchParams); hit.forEach((r) => Object.assign(r, body)); return send(200, prefer.includes('representation') ? hit : undefined); }
      if (req.method() === 'DELETE') return send(204);
    }
    if (p.startsWith('/storage/')) return send(200, []);
    if (p.startsWith('/realtime/')) return route.abort();
    return send(404, { message: 'mock: no route ' + req.method() + ' ' + p });
  }
  return { handle, log, S };
}

// CDN modules (supabase-js +esm and its imports), fetched once with curl (it uses the proxy) and kept on disk
const crypto = require('crypto');
const { execFileSync } = require('child_process');
const CDN_DIR = path.join(require('os').tmpdir(), 'proview-headless-cdn'); fs.mkdirSync(CDN_DIR, { recursive: true });
function cdn(url) {
  const f = path.join(CDN_DIR, crypto.createHash('sha1').update(url).digest('hex'));
  if (!fs.existsSync(f)) execFileSync('curl', ['-sSL', '--fail', '-o', f, url]);
  return { status: 200, body: fs.readFileSync(f), headers: { 'content-type': 'text/javascript', 'access-control-allow-origin': '*' } };
}

async function launch() {
  return chromium.launch({ executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox'] });
}

/** A page with the app served at base and its Supabase host mocked. seed: localStorage entries set before load. */
async function openApp(browser, { base, supaHost, mock, seed = {}, viewport = { width: 1280, height: 860 }, ctx: existing }) {
  const ctx = existing || await browser.newContext({ viewport });
  if (!existing) {
    await ctx.route('**/*', (route) => {
      const u = new URL(route.request().url());
      if (u.host === supaHost) return mock.handle(route);
      if (u.origin === new URL(base).origin) return route.continue();
      if (u.protocol === 'ws:' || u.protocol === 'wss:') return route.abort();
      if (u.host === 'cdn.jsdelivr.net' || u.host === 'esm.sh' || u.host === 'unpkg.com') return route.fulfill(cdn(u.toString()));
      return route.fulfill({ status: 204, body: '' });   // fonts, CDNs, etc.
    });
    await ctx.addInitScript((seed) => { if (!sessionStorage.getItem('__seeded')) { for (const [k, v] of Object.entries(seed)) localStorage.setItem(k, v); sessionStorage.setItem('__seeded', '1'); } }, seed);
  }
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  page.on('console', (m) => { if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errors.push('console: ' + m.text()); });
  page.on('response', (r) => { if (r.status() === 404 && !/tv-version.json|help-kb.json/.test(r.url())) errors.push('404 ' + r.url().replace(/^https?:\/\/[^/]+/, '')); });
  return { ctx, page, errors };
}

/** A supabase-js v2 stored session for a user, for localStorage[storageKey]. */
function storedSession(token, user) {
  return JSON.stringify({ access_token: token, token_type: 'bearer', expires_in: 3600, expires_at: Math.floor(Date.now() / 1000) + 3600, refresh_token: 'r-' + token, user });
}

/** Strings that must never appear in anything the mock sent back (or was asked for) during a step. */
function leaks(log, from, needles) {
  const hits = [];
  for (const e of log.slice(from)) for (const n of needles) if (e.res.includes(n) || e.url.includes(n)) hits.push(`${n} in ${e.method} ${e.url.replace(/^https?:\/\/[^/]+/, '')}`);
  return [...new Set(hits)];
}

function reporter() {
  const out = [];
  const ok = (c, m) => { out.push((c ? 'PASS ' : 'FAIL ') + m); };
  const done = () => { console.log(out.join('\n')); const f = out.filter((l) => l.startsWith('FAIL')).length; console.log(f ? `${f} FAILED of ${out.length}` : `ALL ${out.length} PASSED`); return f; };
  return { ok, done, out };
}

module.exports = { serveStatic, makeMock, launch, openApp, storedSession, leaks, reporter };
