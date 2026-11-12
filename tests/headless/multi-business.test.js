// Headless tests: a person in several businesses (MULTI_BUSINESS_PICKER_STANDARD.md), no Locations page,
// the in-page Location select, and Settings → "This location".
// Usage: node tests/headless/multi-business.test.js [web root]   (needs Playwright + Chrome, see harness.js)
const path = require('path');
const H = require('./harness.js');
const ROOT = process.argv[2] || path.join(__dirname, '../..');
const BASE = 'http://127.0.0.1:8853/';
const SUPA = 'bgsimnrmlzsrfkjpntvj.supabase.co', SKEY = 'sb-bgsimnrmlzsrfkjpntvj-auth-token';
const A = '11111111-1111-4111-8111-111111111111', B = '22222222-2222-4222-8222-222222222222';
const U = (id, email) => ({ id, email, aud: 'authenticated', role: 'authenticated', app_metadata: { provider: 'email' }, user_metadata: {} });
const master = U('u-master', 'master@proview.test'), multi = U('u-multi', 'Multi@Both.test'), solo = U('u-solo', 'solo@cafe-a.test');
const FK = ['bookings', 'enquiries', 'queue', 'messages', 'guests', 'campaigns', 'reviews', 'preorders', 'reports', 'staff', 'kitchen', 'settings', 'users'];
const GOOD = { license_type: 'm12', license_expires_at: '2027-06-01T00:00:00Z' }, GONE = { license_type: 'm1', license_expires_at: '2026-01-01T00:00:00Z' };
const INIT = {
  bk_master_admins: [{ user_id: 'u-master' }],
  bk_businesses: [{ id: A, name: 'Cafe Alpha' }, { id: B, name: 'Burger Bros Ltd' }],
  bk_sites: [{ id: 'alpha-high', business_id: A, name: 'Alpha High St', ...GOOD }, { id: 'alpha-station', business_id: A, name: 'Alpha Station', ...GOOD },
             { id: 'bros-kitchen', business_id: B, name: 'Bros Kitchen', ...GOOD }],
  bk_staff_profiles: [{ user_id: 'u-multi', venue: 'alpha-high', role: 'Owner' }, { user_id: 'u-multi', venue: 'alpha-station', role: 'Owner' }, { user_id: 'u-multi', venue: 'bros-kitchen', role: 'Owner' },
                      { user_id: 'u-solo', venue: 'alpha-high', role: 'Owner' }, { user_id: 'u-solo', venue: 'alpha-station', role: 'Owner' }],
  bk_venue_state: [], bk_inbox: [], bk_guests: [], bk_staff_invites: [], bk_venue_public: [],
};
const tables = {}, venueDoc = {};
const reset = (f) => { for (const k of Object.keys(tables)) delete tables[k]; Object.assign(tables, JSON.parse(JSON.stringify(INIT))); for (const k of Object.keys(venueDoc)) delete venueDoc[k]; if (f) f(tables); };
reset();
const isM = (u) => !!u && tables.bk_master_admins.some((m) => m.user_id === u.id);
const mySites = (u) => tables.bk_sites.filter((s) => isM(u) || tables.bk_staff_profiles.some((p) => p.user_id === u?.id && p.venue === s.id));
const rls = (t, r, u) => { if (!u) return false; if (isM(u)) return true; const ids = mySites(u).map((s) => s.id);
  if (t === 'bk_sites' || t === 'bk_venue_state') return ids.includes(r.id); if (t === 'bk_businesses') return mySites(u).some((s) => s.business_id === r.id);
  if (t === 'bk_master_admins') return false; return r.venue ? ids.includes(r.venue) : true; };
const bname = (id) => tables.bk_businesses.find((b) => b.id === id).name;
const whoami = (_, u) => { const m = isM(u); const sites = mySites(u).slice().sort((a, b) => (bname(a.business_id) + a.name).toLowerCase().localeCompare((bname(b.business_id) + b.name).toLowerCase()));
  return { user_id: u.id, email: u.email, is_master: m, feature_keys: FK,
    sites: sites.map((s) => { const p = tables.bk_staff_profiles.find((x) => x.user_id === u.id && x.venue === s.id); return { ...s, business: bname(s.business_id), role: m ? 'Admin' : p.role, features: Object.fromEntries(FK.map((f) => [f, true])) }; }),
    businesses: tables.bk_businesses.filter((b) => sites.some((s) => s.business_id === b.id)).map((b) => ({ id: b.id, name: b.name, role: 'Owner', can_manage_users: true })) }; };
const SSO = { 'as-master-A': [master, A] };
const gets = [];
const mock = H.makeMock({
  users: { 'tok-master': master, 'tok-multi': multi, 'tok-solo': solo }, tables, rls,
  passwords: { 'multi@both.test': multi }, passwordOf: () => 'correct-horse',
  otp: { 'h-master': master },
  rpc: { bk_is_master: (_, u) => isM(u), bk_whoami: whoami, bk_feature_keys: () => FK,
    bk_venue_get: (a, u) => { gets.push(a.p_venue); if (!mySites(u).some((s) => s.id === a.p_venue)) throw new Error('not allowed'); return venueDoc[a.p_venue] || null; },
    bk_venue_put: (a) => { venueDoc[a.p_venue] = { data: a.p_data, updated_at: new Date().toISOString() + Math.random() }; return { updated_at: venueDoc[a.p_venue].updated_at, g: a.p_data?._g ?? null }; },
    bk_inbox_take: () => [], bk_list_members: () => [], licence_buy_plans: () => ({}) },
  ssoLogin: (b) => { const s = SSO[b.assertion]; if (!s) return { status: 401, body: { error: 'expired' } }; return { status: 200, body: { token_hash: 'h-master', email: master.email, open: s[1] } }; },
});
const R = H.reporter();
const view = (page) => page.evaluate(() => {
  const sel = document.querySelector('#top .hdr-pick select'), loc = document.querySelector('#pvLoc');
  return {
    opts: sel ? [...sel.options].map((o) => o.textContent) : [], groups: sel ? sel.querySelectorAll('optgroup').length : 0,
    picked: sel ? sel.options[sel.selectedIndex]?.textContent : null, disabled: sel?.disabled ?? null, aria: sel?.getAttribute('aria-label'),
    locOpts: loc ? [...loc.options].map((o) => o.textContent) : null, locPicked: loc ? loc.options[loc.selectedIndex]?.textContent : null, locAria: loc?.getAttribute('aria-label'),
    vid: typeof CLOUD !== 'undefined' ? CLOUD.vid : null, view: typeof U !== 'undefined' ? U.view : null, gate: document.body.classList.contains('gate'),
    nav: [...document.querySelectorAll('#nav button')].map((a) => a.title || a.textContent.trim()),
    content: document.querySelector('#content')?.innerText || '', top: document.querySelector('#top')?.innerText || '', bar: document.querySelector('#pvMasterBar')?.innerText || '',
    authShown: !!document.querySelector('#lgEmail') && document.querySelector('#auth')?.hidden === false,
    last: localStorage.getItem('proview-bookings-last:multi@both.test'),
  };
});
const settle = async (p, ms = 2500) => { await p.waitForTimeout(ms); await p.waitForLoadState('load'); await p.waitForTimeout(900); };
const lastKey = 'proview-bookings-last:multi@both.test';
const pickBiz = async (page, name) => { const v = await page.evaluate((t) => [...document.querySelector('#top .hdr-pick select').options].find((o) => o.textContent === t)?.value, name); await page.selectOption('#top .hdr-pick select', v); };
const goView = (page, v) => page.evaluate((v) => { U.view = v; U.setPage = null; render(); }, v);
const noLocWords = (v) => !v.opts.some((o) => /All my locations|All locations|▸/.test(o)) && !v.groups && !/Switch location|Choose location|My locations/.test(v.top);

(async () => {
  const srv = await H.serveStatic(ROOT, 8853);
  const b = await H.launch();
  try {
    // 1) two businesses, last used Cafe Alpha ▸ Alpha Station
    {
      reset();
      const { page, errors, ctx } = await H.openApp(b, { base: BASE, supaHost: SUPA, mock, seed: { [SKEY]: H.storedSession('tok-multi', multi), [lastKey]: JSON.stringify({ biz: A, sites: { [A]: 'alpha-station' } }) } });
      await page.goto(BASE); await settle(page, 3500);
      let v = await view(page);
      R.ok(v.vid === 'alpha-station' && v.picked === 'Cafe Alpha', 'sign-in: lands in the last-used business and its location (Cafe Alpha, Alpha Station) ' + v.vid);
      R.ok(JSON.stringify(v.opts) === JSON.stringify(['Burger Bros Ltd', 'Cafe Alpha']) && noLocWords(v), 'header: business names only, by name ' + JSON.stringify(v.opts));
      R.ok(v.aria === 'Business' && v.disabled === false, 'header: aria-label "Business", enabled');
      R.ok(JSON.stringify(v.locOpts) === JSON.stringify(['Alpha High St', 'Alpha Station']) && v.locPicked === 'Alpha Station' && v.locAria === 'Location', 'page: Location select with Cafe Alpha\'s locations only ' + JSON.stringify(v.locOpts));
      // the in-page Location select switches location, same page
      await goView(page, 'guests'); await settle(page, 400);
      await page.selectOption('#pvLoc', 'alpha-high'); await settle(page, 3000);
      v = await view(page);
      R.ok(v.vid === 'alpha-high' && v.view === 'guests' && v.picked === 'Cafe Alpha', 'Location select: Alpha High St opens, still on the same page ' + v.view);
      // switch business to Burger Bros
      gets.length = 0; let n0 = mock.log.length;
      await pickBiz(page, 'Burger Bros Ltd'); await settle(page, 3000);
      v = await view(page);
      R.ok(v.vid === 'bros-kitchen' && v.picked === 'Burger Bros Ltd' && v.locOpts === null, 'switch: Burger Bros Ltd opens Bros Kitchen; one location, so no Location select');
      { const after = H.leaks(mock.log.slice(n0).filter((e) => !/rpc\/bk_whoami/.test(e.url) && !(/rpc\/bk_venue_put/.test(e.url) && e.req?.p_venue === 'alpha-high')), 0, ['alpha-high', 'alpha-station']);
        R.ok(gets.length && gets.every((g) => g === 'bros-kitchen') && !after.length, 'switch: no Cafe Alpha data read after switching (only the location list in whoami) ' + JSON.stringify(gets) + ' ' + after.join('; ')); }
      R.ok(JSON.parse(v.last || '{}').biz === B, 'switch: Burger Bros remembered as last used, by email ' + v.last);
      // back to Cafe Alpha: its last used location
      await pickBiz(page, 'Cafe Alpha'); await settle(page, 3000);
      v = await view(page);
      R.ok(v.vid === 'alpha-high', 'back to Cafe Alpha: opens the location last used there (Alpha High St) ' + v.vid);
      // no Locations page: no menu item, the old view goes home, nothing combines locations or businesses
      R.ok(!v.nav.some((t) => /^(My )?Locations$/i.test(t)), 'no Locations menu item ' + JSON.stringify(v.nav));
      await goView(page, 'allsites'); await settle(page, 400); v = await view(page);
      R.ok(v.view === 'parties' && !/Businesses|Bookings today|Open business/.test(v.content), 'old Locations view (allsites) goes to the home page (Bookings) ' + v.view);
      // Settings: "This location" with the business licence, and Location details save to that location only
      await goView(page, 'settings'); await settle(page, 400); v = await view(page);
      R.ok(/This location/.test(v.content) && /Alpha High St/.test(v.content) && /Business licence/.test(v.content) && /Renew online/.test(v.content), 'Settings: "This location" with its Business licence and Renew online');
      await page.evaluate(() => { U.setPage = 'account'; render(); }); await settle(page, 300);
      await page.fill('[data-bind="venue.name"]', 'Alpha High Street'); await page.dispatchEvent('[data-bind="venue.name"]', 'change'); await settle(page, 4500);
      R.ok(venueDoc['alpha-high']?.data?.venue?.name === 'Alpha High Street' && venueDoc['alpha-station']?.data?.venue?.name !== 'Alpha High Street', 'This location: the name saves to Alpha High St only');
      // stale text gone
      const src = require('fs').readFileSync(path.join(ROOT, 'index.html'), 'utf8');
      R.ok(!/Add one in the licence portal/.test(src) && !/Add a location ↗/.test(src) && /Businesses are set up by Proview\./.test(src) && !/Locations are (set up|added)/.test(src), 'no "Add one in the licence portal" / "Add a location" text; "Businesses are set up by Proview."');
      // sign out, password sign-in: back in the last used business
      await pickBiz(page, 'Burger Bros Ltd'); await settle(page, 3000);
      await page.evaluate(() => signOutWith('')); await settle(page, 3000);
      v = await view(page);
      R.ok(v.authShown && !!v.last, 'sign-out: sign-in page, the last used business is still remembered for this email');
      await page.fill('#lgEmail', 'multi@both.test'); await page.fill('#lgPw', 'correct-horse'); await page.click('#authGo'); await settle(page, 4000);
      v = await view(page);
      R.ok(v.vid === 'bros-kitchen' && v.picked === 'Burger Bros Ltd' && !/choose a business/i.test(v.content), 'password sign-in: lands in Burger Bros Ltd (last used), no "choose a business" page ' + v.vid);
      R.ok(!errors.length, 'two businesses: no page errors ' + errors.join(' | '));
      await ctx.close();
    }
    // 2) new device: first usable business by name
    {
      reset();
      const { page, errors, ctx } = await H.openApp(b, { base: BASE, supaHost: SUPA, mock, seed: { [SKEY]: H.storedSession('tok-multi', multi) } });
      await page.goto(BASE); await settle(page, 3500);
      const v = await view(page);
      R.ok(v.vid === 'bros-kitchen' && v.picked === 'Burger Bros Ltd', 'new device: first usable business by name ' + v.vid);
      R.ok(!errors.length, 'new device: no page errors ' + errors.join(' | '));
      await ctx.close();
    }
    // 3) fallback: Cafe Alpha unusable (every licence ended), even with this device still on its location
    for (const [why, seed] of [['remembered by email', { [lastKey]: JSON.stringify({ biz: A, sites: { [A]: 'alpha-high' } }) }],
                               ['still open on this device', { [lastKey]: JSON.stringify({ biz: A }), 'proview-locations': JSON.stringify({ cloud: true, current: 'alpha-high', list: [{ id: 'alpha-high', name: 'Alpha High St' }] }), 'proview-bookings-who': 'u-multi' }]]) {
      reset((t) => { t.bk_sites.filter((s) => s.business_id === A).forEach((s) => Object.assign(s, GONE)); });
      const { page, errors, ctx } = await H.openApp(b, { base: BASE, supaHost: SUPA, mock, seed: { [SKEY]: H.storedSession('tok-multi', multi), ...seed } });
      await page.goto(BASE); await settle(page, 4000);
      const v = await view(page);
      R.ok(v.vid === 'bros-kitchen' && !v.gate && JSON.stringify(v.opts) === JSON.stringify(['Burger Bros Ltd']) && v.disabled === true, `fallback (${why}): opens Burger Bros Ltd, its name disabled ${JSON.stringify(v.opts)} ${v.vid}`);
      R.ok(!errors.length, `fallback (${why}): no page errors ` + errors.join(' | '));
      await ctx.close();
    }
    // 4) single-business owner: the business name, disabled; the Location select for its two locations
    {
      reset();
      const { page, errors, ctx } = await H.openApp(b, { base: BASE, supaHost: SUPA, mock, seed: { [SKEY]: H.storedSession('tok-solo', solo) } });
      await page.goto(BASE); await settle(page, 3500);
      const v = await view(page);
      R.ok(v.vid === 'alpha-high' && JSON.stringify(v.opts) === JSON.stringify(['Cafe Alpha']) && v.disabled === true, 'single business: its name, disabled; first location as before ' + JSON.stringify(v.opts));
      R.ok(JSON.stringify(v.locOpts) === JSON.stringify(['Alpha High St', 'Alpha Station']) && !v.nav.some((t) => /Locations/i.test(t)), 'single business: Location select, no Locations menu item');
      R.ok(!errors.length, 'single business: no page errors ' + errors.join(' | '));
      await ctx.close();
    }
    // 4b) the master signed in directly: "Open a business from the licence portal"
    {
      reset();
      const { page, errors, ctx } = await H.openApp(b, { base: BASE, supaHost: SUPA, mock, seed: { [SKEY]: H.storedSession('tok-master', master) } });
      await page.goto(BASE); await settle(page, 3500);
      const t = await page.evaluate(() => document.body.innerText);
      R.ok(/Open a business from the licence portal/.test(t) && !/Open a location/.test(t), 'master direct: "Open a business from the licence portal"');
      R.ok(!errors.length, 'master direct: no page errors ' + errors.join(' | '));
      await ctx.close();
    }
    // 5) master-open: the opened business's name, disabled; nothing remembered
    {
      reset();
      const { page, errors, ctx } = await H.openApp(b, { base: BASE, supaHost: SUPA, mock });
      const n0 = mock.log.length; await page.goto(BASE + '#pv_sso=as-master-A'); await settle(page, 4500);
      let v = await view(page);
      R.ok(/Viewing\s+Cafe Alpha\s+as Proview/.test(v.bar) && JSON.stringify(v.opts) === JSON.stringify(['Cafe Alpha']) && v.disabled === true, 'master-open: banner, the business name disabled ' + JSON.stringify(v.opts));
      R.ok(!H.leaks(mock.log, n0, ['Burger Bros Ltd', 'bros-kitchen']).length && !Object.keys(await page.evaluate(() => ({ ...localStorage }))).some((k) => k.startsWith('proview-bookings-last:')), 'master-open: no other business loaded, nothing remembered as last used');
      await goView(page, 'settings'); await settle(page, 400); v = await view(page);
      R.ok(/This location/.test(v.content) && /Licence portal/.test(v.content), 'master-open: Settings "This location" with the licence portal link');
      R.ok(!errors.length, 'master-open: no page errors ' + errors.join(' | '));
      await ctx.close();
    }
  } finally { await b.close(); srv.close(); }
  process.exit(R.done() ? 1 : 0);
})();
