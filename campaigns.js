/* Proview Bookings: Email campaigns (same designer as Proview WiFi).
 * Owners and managers design emails and send them to guests who agreed to marketing.
 * Data: bk_campaigns / bk_campaign_recipients (Supabase, RLS: bk_is_admin). Sending, tests and scheduling:
 * the bk-campaign edge function (Resend). Opens, clicks and unsubscribes: bk-mail.
 * Uses the app's globals (VIEWS, AFTER, TITLES, NAV, A, U, S, CLOUD, render, esc, ic, toast, $).
 * The page lives in one persistent element so background refreshes never wipe what you're typing. */
import { renderEmail, BLOCKS, TEMPLATES, normaliseDesign } from './campaign-render.js?v=1';

const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const C = { mode: 'list', list: null, stats: {}, unsubs: null, cfg: null, cur: null, rows: null, sel: null, dirty: false, saving: null, saveT: 0, pvT: 0, pollT: 0, el: null, err: '' };
const sb = () => CLOUD.ad && CLOUD.ad.sb;
const venue = () => CLOUD.vid;
const canUse = () => !!(CLOUD.on && sb() && (isMaster() || ['Admin', 'Owner', 'Manager'].includes(CLOUD.site?.role)));
const uid = () => 'b' + Math.random().toString(36).slice(2, 9);
const fmt = (t) => (t ? new Date(t).toLocaleString('en-GB', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' }) : '—');
const pct = (a, b) => (b ? Math.round(((a || 0) / b) * 100) + '%' : '—');
const h = (html) => { const t = document.createElement('template'); t.innerHTML = html.trim(); return t.content.firstElementChild; };
async function fnErr(error) { try { return (await error.context.json()).error || error.message; } catch { return error.message || 'Something went wrong'; } }
async function invoke(body) {
  const { data, error } = await sb().functions.invoke('bk-campaign', { body });
  if (error) throw new Error(await fnErr(error));
  return data;
}

/* ---------- menu + view registration ---------- */
TITLES.campaigns = 'Email campaigns';
if (!NAV.some((n) => n[0] === 'campaigns')) NAV.splice(NAV.findIndex((n) => n[0] === 'guests') + 1, 0, ['campaigns', 'Email campaigns', 'mail']);
if (typeof SHORT === 'object') SHORT.campaigns = 'Emails';
const _renderNav = renderNav;
// Only owners and managers see it (and only once signed in to the cloud)
window.renderNav = renderNav = function () {
  const i = NAV.findIndex((n) => n[0] === 'campaigns'), keep = canUse();
  if (!keep && i >= 0) { const saved = NAV.splice(i, 1)[0]; try { _renderNav(); } finally { NAV.splice(i, 0, saved); } return; }
  _renderNav();
};

VIEWS.campaigns = () => (canUse() ? '<div id="cmpRoot"></div>' : `<div class="empty">Email campaigns are for owners and managers.</div>`);
AFTER.campaigns = () => {
  const root = $('#cmpRoot'); if (!root) return;
  if (C.venue !== venue()) Object.assign(C, { venue: venue(), mode: 'list', list: null, cur: null, unsubs: null, el: null });
  if (!C.el) { C.el = document.createElement('div'); paint(); }
  root.replaceWith(C.el);
  if (C.mode === 'edit') preview(true);
  if (C.mode === 'report') { const f = C.el.querySelector('#cmpView'); if (f) f.srcdoc = emailHtml(C.cur); }
};
// open the list whenever someone clicks the menu item
const _go = A.go;
A.go = (el) => {
  if (el?.dataset?.v === 'campaigns' && U.view === 'campaigns' && C.mode !== 'list') { leaveEditor().then(() => { C.mode = 'list'; C.list = null; paint(); }); return; }
  if (U.view === 'campaigns' && C.dirty) save(); // leaving mid-edit: keep the changes
  return _go(el);
};

/* ---------- data ---------- */
async function loadList() {
  const [l, s] = await Promise.all([
    sb().from('bk_campaigns').select('id,name,subject,status,scheduled_at,started_at,finished_at,updated_at,created_at').eq('venue', venue()).order('created_at', { ascending: false }),
    sb().rpc('bk_campaign_stats', { p_venue: venue() }),
  ]);
  if (l.error) throw l.error;
  C.list = l.data || [];
  C.stats = Object.fromEntries((s.data || []).map((r) => [r.campaign_id, r]));
}
async function loadUnsubs() {
  if (C.unsubs) return C.unsubs;
  const { data } = await sb().from('bk_unsubscribes').select('email').eq('venue', venue());
  return (C.unsubs = new Set((data || []).map((r) => r.email)));
}
async function loadCfg() { if (!C.cfg) try { C.cfg = await invoke({ action: 'status' }); } catch { C.cfg = { configured: false }; } return C.cfg; }
// Guests who agreed to marketing (one per email), minus anyone who unsubscribed
function audience() {
  const out = C.unsubs || new Set(), seen = new Set();
  for (const g of S.guests || []) {
    const e = String(g.email || '').trim().toLowerCase();
    if (g.marketing && EMAIL_RE.test(e) && !out.has(e)) seen.add(e);
  }
  return seen.size;
}
const emailHtml = (c, preview) => renderEmail(c, { preview, venue: S.venue.name, recipient: { name: 'Alex' }, track: { unsub: '#', view: '' } });

/* ---------- painting ---------- */
function paint() {
  if (!C.el) return;
  clearInterval(C.pollT);
  if (C.mode === 'edit' && C.cur) return paintEditor();
  if (C.mode === 'report' && C.cur) return paintReport();
  paintList();
}

function paintList() {
  C.el.className = 'cmp';
  const st = { draft: ['', 'Draft'], scheduled: ['amber', 'Scheduled'], sending: ['amber', 'Sending'], sent: ['green', 'Sent'], cancelled: ['red', 'Stopped'] };
  const L = C.list;
  const sent = (L || []).filter((c) => (C.stats[c.id]?.sent || 0) > 0);
  const avgOpen = sent.length ? Math.round((sent.reduce((a, c) => a + (C.stats[c.id].opened || 0) / C.stats[c.id].sent, 0) / sent.length) * 100) + '%' : '—';
  C.el.innerHTML = `
    <div class="row between" style="margin-bottom:14px;flex-wrap:wrap;gap:10px"><div class="mut">Design and send emails to guests who agreed to marketing when they booked or joined your guest list.</div>
      <button class="btn pri" data-c="new">${ic('plus', 16)} New campaign</button></div>
    ${C.cfg && !C.cfg.configured ? `<div class="notice bad" style="margin-bottom:14px"><b>Email sending isn’t switched on yet.</b> You can design and save campaigns. Contact Proview to switch sending on.</div>` : ''}
    ${C.err ? `<div class="notice bad" style="margin-bottom:14px">${esc(C.err)}</div>` : ''}
    <div class="stats">
      <div class="card stat"><div class="k">People you can email</div><div class="v">${C.unsubs ? audience() : '…'}</div></div>
      <div class="card stat"><div class="k">Campaigns sent</div><div class="v">${L ? L.filter((c) => c.status === 'sent').length : '…'}</div></div>
      <div class="card stat"><div class="k">Emails delivered</div><div class="v">${L ? L.reduce((a, c) => a + (C.stats[c.id]?.sent || 0), 0) : '…'}</div></div>
      <div class="card stat"><div class="k">Average open rate</div><div class="v">${L ? avgOpen : '…'}</div></div>
    </div>
    <div class="card">${!L ? '<div class="empty">Loading…</div>' : !L.length ? `<div class="empty"><b style="font-size:17px;color:var(--ink)">No campaigns yet</b><p>Pick a template, add your logo and offer, and send it to everyone who agreed to marketing.</p><button class="btn pri" data-c="new">Create your first campaign</button></div>` : `
      <table class="t"><thead><tr><th>Campaign</th><th>Status</th><th>Recipients</th><th>Opened</th><th>Clicked</th><th>When</th><th></th></tr></thead><tbody>
      ${L.map((c) => { const s = C.stats[c.id] || {}, [tone, lbl] = st[c.status] || st.draft; return `<tr class="click" data-c="open" data-id="${c.id}">
        <td><b>${esc(c.name)}</b><div class="small mut">${esc(c.subject || 'No subject yet')}</div></td>
        <td><span class="chip ${tone}">${lbl}</span></td><td>${s.total || '—'}</td>
        <td>${s.sent ? pct(s.opened, s.sent) : '—'}</td><td>${s.sent ? pct(s.clicked, s.sent) : '—'}</td>
        <td class="small mut" style="white-space:nowrap">${c.status === 'scheduled' ? fmt(c.scheduled_at) : c.started_at ? fmt(c.started_at) : 'Edited ' + fmt(c.updated_at)}</td>
        <td style="white-space:nowrap;text-align:right"><button class="btn sm" data-c="open" data-id="${c.id}">${['draft', 'scheduled'].includes(c.status) ? 'Edit' : 'Report'}</button> <button class="btn sm" data-c="copy" data-id="${c.id}" title="Make a copy">Copy</button></td></tr>`; }).join('')}
      </tbody></table>`}</div>
    <p class="small mut" style="margin-top:12px">Only guests who agreed to marketing are emailed. Every email has an unsubscribe link; anyone who unsubscribes is unticked in your guest book automatically.</p>`;
  bindList();
  if (!L || !C.unsubs || !C.cfg) {
    Promise.all([loadList(), loadUnsubs(), loadCfg()]).then(() => { C.err = ''; if (C.mode === 'list') paintList(); })
      .catch((e) => { C.err = 'Couldn’t load your campaigns: ' + (e.message || e); C.list = C.list || []; if (C.mode === 'list') paintList(); });
  }
}
function bindList() {
  C.el.onclick = async (e) => {
    const b = e.target.closest('[data-c]'); if (!b) return;
    const act = b.dataset.c, id = b.dataset.id;
    if (act === 'new') return templatePicker();
    if (act === 'copy') { e.stopPropagation(); return copy(id); }
    if (act === 'open') return open(id);
  };
}

function templatePicker() {
  const m = $('#modal');
  m.innerHTML = `<div class="modal card" style="max-width:640px"><div class="pad row between" style="border-bottom:1px solid var(--line)"><h3>Start a new campaign</h3><button class="btn sm" data-act="closeModal" aria-label="Close">${ic('x', 16)}</button></div>
    <div class="pad"><p class="mut" style="margin:0 0 14px">Pick a starting point. You can change everything in the designer.</p>
    <div class="cmp-tpl">${Object.entries(TEMPLATES).map(([k, t], i) => `<label><input type="radio" name="cmpTpl" value="${k}" ${i === 0 ? 'checked' : ''}><span class="art" style="background:${t.swatch}"><i></i><i></i><i></i></span><b>${esc(t.label)}</b><span class="small mut">${esc(t.desc)}</span></label>`).join('')}</div>
    <div class="row" style="justify-content:flex-end;margin-top:18px;gap:8px"><button class="btn" data-act="closeModal">Cancel</button><button class="btn pri" id="cmpCreate">Open designer</button></div></div></div>`;
  m.classList.add('show');
  $('#cmpCreate').onclick = async () => {
    const k = m.querySelector('input[name=cmpTpl]:checked').value, t = TEMPLATES[k];
    $('#cmpCreate').disabled = true;
    const day = new Date().toLocaleDateString('en-GB', { day: 'numeric', month: 'short' });
    const { data, error } = await sb().from('bk_campaigns').insert({ venue: venue(), name: `${t.label} – ${day}`, subject: t.subject, preheader: t.preheader, from_name: S.venue.name || '', design: t.design() }).select().single();
    A.closeModal();
    if (error) return toast('Couldn’t create the campaign: ' + error.message);
    C.list = null; C.cur = data; C.mode = 'edit'; C.sel = null; paint();
  };
}
async function open(id) {
  const { data, error } = await sb().from('bk_campaigns').select('*').eq('id', id).single();
  if (error) return toast('Couldn’t open that campaign');
  C.cur = data; C.sel = null; C.rows = null;
  C.mode = ['draft', 'scheduled'].includes(data.status) ? 'edit' : 'report';
  paint();
}
async function copy(id) {
  const { data: c, error } = await sb().from('bk_campaigns').select('*').eq('id', id).single();
  if (error) return toast('Couldn’t copy that campaign');
  const { data, error: e2 } = await sb().from('bk_campaigns').insert({ venue: venue(), name: (c.name + ' (copy)').slice(0, 120), subject: c.subject, preheader: c.preheader, from_name: c.from_name, reply_to: c.reply_to, design: c.design }).select().single();
  if (e2) return toast('Couldn’t copy: ' + e2.message);
  C.list = null; C.cur = data; C.mode = 'edit'; C.sel = null; paint();
}

/* ---------- designer (same as Proview WiFi) ---------- */
const I = {
  logo: '<circle cx="12" cy="12" r="9"/><path d="M8 14s1.5 2 4 2 4-2 4-2M9 9h.01M15 9h.01"/>', heading: '<path d="M6 4v16M18 4v16M6 12h12"/>',
  text: '<path d="M4 6h16M4 12h16M4 18h10"/>', image: '<rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8.5" cy="8.5" r="1.5"/><path d="m21 15-5-5L5 21"/>',
  button: '<rect x="3" y="8" width="18" height="8" rx="4"/><path d="M9 12h6"/>', voucher: '<path d="M3 8a2 2 0 0 0 2-2h14a2 2 0 0 0 2 2v2a2 2 0 0 0 0 4v2a2 2 0 0 0-2 2H5a2 2 0 0 0-2-2v-2a2 2 0 0 0 0-4z"/><path d="M13 6v12" stroke-dasharray="2 2"/>',
  divider: '<path d="M3 12h18"/>', spacer: '<path d="M12 3v18M8 7l4-4 4 4M8 17l4 4 4-4"/>', up: '<path d="m18 15-6-6-6 6"/>', down: '<path d="m6 9 6 6 6-6"/>',
  dup: '<rect x="8" y="8" width="13" height="13" rx="2"/><path d="M4 16V5a1 1 0 0 1 1-1h11"/>', trash: '<path d="M3 6h18M8 6V4h8v2M19 6l-1 14H6L5 6"/>',
  grip: '<circle cx="9" cy="6" r="1"/><circle cx="15" cy="6" r="1"/><circle cx="9" cy="12" r="1"/><circle cx="15" cy="12" r="1"/><circle cx="9" cy="18" r="1"/><circle cx="15" cy="18" r="1"/>',
};
const svg = (n) => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${I[n] || ''}</svg>`;
const META = {
  logo: ['Logo', (b) => (b.src ? 'Image set' : 'No image yet')], heading: ['Heading', (b) => b.text], text: ['Text', (b) => String(b.text || '').replace(/[*[\]()]/g, '').split('\n')[0]],
  image: ['Image', (b) => (b.src ? b.alt || 'Image set' : 'No image yet')], button: ['Button', (b) => b.label], voucher: ['Voucher code', (b) => b.code],
  divider: ['Divider', () => 'Line'], spacer: ['Space', (b) => b.height + 'px'],
};
const F = {
  logo: [['src', 'Logo image', 'image'], ['width', 'Size', 'range', { min: 60, max: 400, step: 10, unit: 'px' }], ['align', 'Position', 'align'], ['link', 'Link (optional)', 'url']],
  heading: [['text', 'Heading', 'text'], ['size', 'Size', 'select', { s: 'Small', m: 'Medium', l: 'Large', xl: 'Extra large' }], ['align', 'Alignment', 'align']],
  text: [['text', 'Text', 'rich'], ['align', 'Alignment', 'align']],
  image: [['src', 'Image', 'image'], ['alt', 'Description (for screen readers)', 'text'], ['link', 'Link (optional)', 'url'], ['full', 'Edge to edge', 'check']],
  button: [['label', 'Button text', 'text'], ['url', 'Link', 'url'], ['align', 'Position', 'align'], ['bg', 'Button colour (blank = brand colour)', 'color'], ['fg', 'Text colour', 'color']],
  voucher: [['title', 'Title', 'text'], ['code', 'Code', 'text'], ['note', 'Small print', 'text']],
  divider: [['color', 'Line colour', 'color']], spacer: [['height', 'Height', 'range', { min: 4, max: 120, step: 4, unit: 'px' }]],
};
const PRESETS = [
  ['Classic', '#f4f3ef', '#ffffff', '#1d2330', '#2f6fd8'], ['Night', '#141418', '#1f1f25', '#f1f1f4', '#8b88dc'], ['Warm', '#fbf1e6', '#ffffff', '#3a2a1e', '#d9472b'],
  ['Fresh', '#eaf7f0', '#ffffff', '#16302a', '#12a150'], ['Bold', '#111111', '#ffffff', '#111111', '#f5b700'], ['Rose', '#fdf0f3', '#ffffff', '#3b1f2a', '#d6336c'],
];

function paintEditor() {
  const c = C.cur;
  c.design = normaliseDesign(c.design); c.design.blocks.forEach((b) => { if (!b.id) b.id = uid(); });
  C.el.className = 'cmp';
  C.el.innerHTML = `
  <div class="dz-top">
    <div class="dz-title"><button class="crumb" data-e="back">${ic('left', 14)} Email campaigns</button><input id="cmpName" class="dz-name" maxlength="120" aria-label="Campaign name"></div>
    <div class="row" style="gap:8px;flex-wrap:wrap">
      <span id="cmpSave" class="small mut dz-save">Saved</span>
      <div class="seg" aria-label="Preview size"><button class="on" data-view="desktop">Desktop</button><button data-view="mobile">Phone</button></div>
      <button class="btn" data-e="test">Send test</button>
      <button class="btn pri" data-e="send">${c.status === 'scheduled' ? 'Scheduled ✓' : 'Send…'}</button>
    </div>
  </div>
  ${c.status === 'scheduled' ? `<div class="notice" style="margin-bottom:12px;background:#fdf3de;border-color:#f1d9a6;color:#7a4d00">Scheduled to send <b>${esc(fmt(c.scheduled_at))}</b>. Changes you make are saved and will be sent. <button class="btn sm" data-e="unschedule" style="margin-left:8px">Cancel schedule</button></div>` : ''}
  ${C.cfg && !C.cfg.configured ? `<div class="notice bad" style="margin-bottom:12px">Email sending isn’t switched on yet. You can design and save, but not send.</div>` : ''}
  <div class="dz">
    <aside class="dz-side card">
      <div class="dz-tabs" role="tablist"><button class="on" data-tab="content">Content</button><button data-tab="style">Style</button><button data-tab="settings">Settings<span id="cmpDot" class="dot" hidden></span></button></div>
      <div class="dz-tab" id="tab-content"><div id="cmpBlocks" class="blocks"></div><div class="add-title">Add a block</div><div id="cmpPalette" class="palette"></div>
        <p class="small mut">Tip: click any part of the preview to edit it. Drag blocks by their handle to reorder. Use <code>{{name}}</code> to greet each guest by first name.</p></div>
      <div class="dz-tab" id="tab-style" hidden>
        ${[['bg', 'Page background'], ['content', 'Email background'], ['text', 'Text colour'], ['accent', 'Brand colour (buttons, links, vouchers)']].map(([k, l]) => `<div><label class="f">${l}</label><div class="row" style="gap:8px"><input type="color" class="swatch" data-theme="${k}"><input class="inp hexin" data-hex="${k}"></div></div>`).join('')}
        <div><label class="f">Font</label><select class="inp" data-theme="font"><option value="sans">Modern (sans-serif)</option><option value="rounded">Friendly</option><option value="serif">Classic (serif)</option></select></div>
        <div><label class="f">Footer text</label><textarea class="inp" data-theme="footer" rows="3" placeholder="e.g. ${esc(S.venue.name || 'Your venue')}, 12 High Street, London"></textarea><div class="small mut">Add your business name and address. The unsubscribe link is added automatically.</div></div>
        <div><label class="f">Quick colour themes</label><div class="presets" id="cmpPresets"></div></div>
      </div>
      <div class="dz-tab" id="tab-settings" hidden>
        <div><label class="f">Subject line *</label><input class="inp" id="cmpSubject" maxlength="200" placeholder="e.g. 10% off your next visit, {{name}}"><div class="small mut"><span id="cmpSubjLen">0</span> characters, ideally under 50.</div></div>
        <div><label class="f">Preview text</label><input class="inp" id="cmpPre" maxlength="200" placeholder="Shown after the subject in most inboxes"></div>
        <div><label class="f">From name</label><input class="inp" id="cmpFrom" maxlength="80" placeholder="${esc(S.venue.name || 'Your venue')}"></div>
        <div><label class="f">Replies go to</label><input class="inp" id="cmpReply" type="email" placeholder="you@yourvenue.co.uk"><div class="small mut">Leave blank to not accept replies.</div></div>
        <div class="aud"><b id="cmpAud">…</b> <span id="cmpAudW">guests have</span> agreed to marketing<div class="small mut">From your guest book: guests who ticked marketing when they booked or signed up. Anyone who unsubscribed is left out.</div></div>
      </div>
    </aside>
    <section class="dz-stage">
      <div class="inbox card"><div class="inbox-av" id="ibAv">?</div><div class="inbox-t"><b id="ibFrom">From</b><span><strong id="ibSubj">Subject</strong> <span class="mut" id="ibPre"></span></span></div></div>
      <div class="frame-wrap" id="cmpFrameWrap"><iframe id="cmpPv" title="Email preview"></iframe></div>
    </section>
  </div>
  ${c.status === 'draft' ? `<button class="btn sm" data-e="delete" style="margin-top:14px;color:var(--bad)">Delete draft</button>` : ''}`;
  bindEditor();
}

function bindEditor() {
  const c = C.cur, el = C.el, q = (s) => el.querySelector(s), qa = (s) => [...el.querySelectorAll(s)];
  // header actions
  el.onclick = (e) => {
    const b = e.target.closest('[data-e]'); if (!b) return;
    ({ back: () => leaveEditor().then(() => { C.mode = 'list'; C.list = null; paint(); }), test: testDialog, send: sendDialog, unschedule, delete: delDraft })[b.dataset.e]?.();
  };
  qa('.seg[aria-label="Preview size"] button').forEach((b) => (b.onclick = () => {
    qa('.seg[aria-label="Preview size"] button').forEach((x) => x.classList.toggle('on', x === b));
    q('#cmpFrameWrap').classList.toggle('mobile', b.dataset.view === 'mobile'); setTimeout(fit, 60);
  }));
  qa('.dz-tabs button').forEach((b) => (b.onclick = () => {
    qa('.dz-tabs button').forEach((x) => x.classList.toggle('on', x === b));
    qa('.dz-tab').forEach((t) => (t.hidden = t.id !== 'tab-' + b.dataset.tab));
  }));
  // name + settings
  const bind = (sel, key) => { const i = q(sel); i.value = c[key] || ''; i.oninput = () => { c[key] = i.value; changed(); }; };
  bind('#cmpName', 'name'); bind('#cmpSubject', 'subject'); bind('#cmpPre', 'preheader'); bind('#cmpFrom', 'from_name'); bind('#cmpReply', 'reply_to');
  // style tab
  const th = c.design.theme;
  qa('[data-theme]').forEach((i) => { i.value = th[i.dataset.theme] ?? ''; i.oninput = () => { th[i.dataset.theme] = i.value; const hx = q(`[data-hex="${i.dataset.theme}"]`); if (hx) hx.value = i.value; changed(); }; });
  qa('[data-hex]').forEach((i) => { i.value = th[i.dataset.hex] || ''; i.oninput = () => { if (/^#[0-9a-f]{6}$/i.test(i.value)) { th[i.dataset.hex] = i.value; q(`[data-theme="${i.dataset.hex}"]`).value = i.value; changed(); } }; });
  q('#cmpPresets').innerHTML = PRESETS.map((p, i) => `<button type="button" data-i="${i}" title="${p[0]}"><span style="background:${p[1]}"><i style="background:${p[2]}"></i><b style="background:${p[4]}"></b></span>${p[0]}</button>`).join('');
  q('#cmpPresets').onclick = (e) => {
    const p = PRESETS[e.target.closest('button')?.dataset.i]; if (!p) return;
    Object.assign(th, { bg: p[1], content: p[2], text: p[3], accent: p[4] });
    ['bg', 'content', 'text', 'accent'].forEach((k) => { q(`[data-theme="${k}"]`).value = th[k]; q(`[data-hex="${k}"]`).value = th[k]; });
    changed();
  };
  // palette
  q('#cmpPalette').innerHTML = Object.keys(META).map((t) => `<button type="button" data-t="${t}">${svg(t)}<span>${META[t][0]}</span></button>`).join('');
  q('#cmpPalette').onclick = (e) => {
    const t = e.target.closest('button')?.dataset.t; if (!t) return;
    const b = { id: uid(), type: t, ...JSON.parse(JSON.stringify(BLOCKS[t])) };
    const at = C.sel ? c.design.blocks.findIndex((x) => x.id === C.sel) + 1 : c.design.blocks.length;
    c.design.blocks.splice(at, 0, b); select(b.id); changed(true);
  };
  renderBlocks(); inbox(); audienceLine();
  loadUnsubs().then(audienceLine); loadCfg().then(() => { if (C.cfg && !C.cfg.configured && C.mode === 'edit' && !el.querySelector('.notice.bad')) paintEditor(); });
  preview(true);
}

function renderBlocks() {
  const c = C.cur, list = C.el.querySelector('#cmpBlocks'); if (!list) return;
  list.innerHTML = c.design.blocks.length ? '' : '<div class="blk-empty">Your email is empty. Add a block below.</div>';
  c.design.blocks.forEach((b, i) => list.append(card(b, i)));
}
function card(b, i) {
  const c = C.cur, n = c.design.blocks.length;
  const el = h(`<div class="blk${C.sel === b.id ? ' open' : ''}" data-id="${b.id}"><div class="blk-h"><span class="grip" title="Drag to reorder">${svg('grip')}</span><span class="blk-ic">${svg(b.type)}</span>
    <span class="blk-t"><b>${META[b.type][0]}</b><span class="blk-s">${esc(META[b.type][1](b) || '')}</span></span>
    <span class="blk-a"><button type="button" data-a="up" title="Move up" ${i === 0 ? 'disabled' : ''}>${svg('up')}</button><button type="button" data-a="down" title="Move down" ${i === n - 1 ? 'disabled' : ''}>${svg('down')}</button><button type="button" data-a="dup" title="Duplicate">${svg('dup')}</button><button type="button" data-a="del" title="Delete">${svg('trash')}</button></span></div></div>`);
  if (C.sel === b.id) el.append(fields(b));
  el.querySelector('.blk-h').addEventListener('click', (e) => {
    const a = e.target.closest('button')?.dataset.a, idx = c.design.blocks.indexOf(b);
    if (a === 'up' || a === 'down') return move(idx, idx + (a === 'up' ? -1 : 1));
    if (a === 'dup') { const d = { ...JSON.parse(JSON.stringify(b)), id: uid() }; c.design.blocks.splice(idx + 1, 0, d); select(d.id); return changed(true); }
    if (a === 'del') { c.design.blocks.splice(idx, 1); if (C.sel === b.id) C.sel = null; return changed(true); }
    if (e.target.closest('.grip')) return;
    select(C.sel === b.id ? null : b.id);
  });
  const grip = el.querySelector('.grip');
  grip.addEventListener('mousedown', () => { el.draggable = true; });
  grip.addEventListener('touchstart', () => { el.draggable = true; }, { passive: true });
  el.addEventListener('dragstart', (e) => { e.dataTransfer.setData('text/plain', b.id); e.dataTransfer.effectAllowed = 'move'; el.classList.add('dragging'); });
  el.addEventListener('dragend', () => { el.draggable = false; el.classList.remove('dragging'); C.el.querySelectorAll('.blk').forEach((x) => x.classList.remove('drop-before', 'drop-after')); });
  el.addEventListener('dragover', (e) => { e.preventDefault(); const r = el.getBoundingClientRect(), after = e.clientY > r.top + r.height / 2; el.classList.toggle('drop-after', after); el.classList.toggle('drop-before', !after); });
  el.addEventListener('dragleave', () => el.classList.remove('drop-before', 'drop-after'));
  el.addEventListener('drop', (e) => {
    e.preventDefault();
    const from = c.design.blocks.findIndex((x) => x.id === e.dataTransfer.getData('text/plain'));
    let to = c.design.blocks.indexOf(b) + (el.classList.contains('drop-after') ? 1 : 0);
    if (from < 0) return; if (from < to) to--; move(from, to);
  });
  return el;
}
function move(from, to) {
  const bl = C.cur.design.blocks;
  if (to < 0 || to >= bl.length || from === to) return;
  const [x] = bl.splice(from, 1); bl.splice(to, 0, x); changed(true);
}
function select(id) {
  C.sel = id; renderBlocks(); highlight();
  if (id) C.el.querySelector(`.blk[data-id="${id}"]`)?.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
}

function fields(b) {
  const box = h('<div class="blk-b"></div>');
  for (const [k, label, type, opt] of F[b.type]) {
    const f = h('<div></div>');
    const set = (v) => { b[k] = v; const s = C.el.querySelector(`.blk[data-id="${b.id}"] .blk-s`); if (s) s.textContent = META[b.type][1](b) || ''; changed(); };
    if (type === 'check') {
      f.innerHTML = `<label class="row" style="gap:8px;cursor:pointer;font-weight:550"><input type="checkbox" ${b[k] ? 'checked' : ''}> ${label}</label>`;
      f.querySelector('input').onchange = (e) => set(e.target.checked);
    } else {
      f.innerHTML = `<label class="f" style="margin-top:0">${label}</label>`;
      if (type === 'text' || type === 'url') {
        const i = Object.assign(document.createElement('input'), { className: 'inp', type: 'text', value: b[k] ?? '', placeholder: type === 'url' ? 'https://' : '' });
        i.oninput = () => set(i.value); f.append(i);
      } else if (type === 'rich') {
        const bar = h('<div class="rt-bar"><button type="button" data-w="**" title="Bold"><b>B</b></button><button type="button" data-w="*" title="Italic"><i>I</i></button><button type="button" data-link title="Link">Link</button><button type="button" data-ins="{{name}}" title="Guest’s first name">+ First name</button></div>');
        const ta = Object.assign(document.createElement('textarea'), { className: 'inp', value: b[k] ?? '', rows: 7 });
        ta.oninput = () => set(ta.value);
        bar.onclick = (e) => {
          const btn = e.target.closest('button'); if (!btn) return;
          const s = ta.selectionStart, en = ta.selectionEnd, sel = ta.value.slice(s, en);
          if (btn.dataset.link !== undefined) return linkPrompt(sel, (u) => { ta.setRangeText(`[${sel || 'link text'}](${u})`, s, en, 'end'); ta.focus(); set(ta.value); });
          ta.setRangeText(btn.dataset.w ? btn.dataset.w + (sel || 'text') + btn.dataset.w : btn.dataset.ins, s, en, 'end'); ta.focus(); set(ta.value);
        };
        f.append(bar, ta, h('<div class="small mut">Blank line = new paragraph.</div>'));
      } else if (type === 'select') {
        const s = h(`<select class="inp">${Object.entries(opt).map(([v, l]) => `<option value="${v}" ${b[k] === v ? 'selected' : ''}>${l}</option>`).join('')}</select>`);
        s.onchange = () => set(s.value); f.append(s);
      } else if (type === 'align') {
        const seg = h(`<div class="seg" style="display:flex">${['left', 'center', 'right'].map((v) => `<button type="button" data-v="${v}" class="${b[k] === v ? 'on' : ''}" style="flex:1;justify-content:center">${v[0].toUpperCase() + v.slice(1)}</button>`).join('')}</div>`);
        seg.onclick = (e) => { const v = e.target.closest('button')?.dataset.v; if (!v) return; seg.querySelectorAll('button').forEach((x) => x.classList.toggle('on', x.dataset.v === v)); set(v); };
        f.append(seg);
      } else if (type === 'range') {
        const r = h(`<div class="row" style="gap:10px"><input type="range" min="${opt.min}" max="${opt.max}" step="${opt.step}" value="${b[k]}" style="flex:1"><span class="small mut rng">${b[k]}${opt.unit}</span></div>`);
        r.querySelector('input').oninput = (e) => { r.querySelector('.rng').textContent = e.target.value + opt.unit; set(Number(e.target.value)); };
        f.append(r);
      } else if (type === 'color') {
        const r = h(`<div class="row" style="gap:8px"><input type="color" class="swatch" value="${b[k] || '#2f6fd8'}"><input class="inp hexin" value="${b[k] || ''}" placeholder="auto"></div>`);
        const [cc, tt] = r.querySelectorAll('input');
        cc.oninput = () => { tt.value = cc.value; set(cc.value); };
        tt.oninput = () => { if (/^#[0-9a-f]{6}$/i.test(tt.value)) { cc.value = tt.value; set(tt.value); } else if (!tt.value) set(''); };
        f.append(r);
      } else if (type === 'image') {
        const w = h(`<div class="img-f">${b[k] ? `<img src="${esc(b[k])}" alt="">` : ''}<div class="row" style="gap:8px;flex-wrap:nowrap"><input class="inp" placeholder="Paste an image link, or upload" value="${esc(b[k] || '')}"><label class="btn sm up">Upload<input type="file" accept="image/png,image/jpeg,image/gif,image/webp" hidden></label></div><div class="small mut up-msg"></div></div>`);
        const i = w.querySelector('input.inp'), file = w.querySelector('input[type=file]'), msg = w.querySelector('.up-msg');
        i.oninput = () => set(i.value.trim());
        file.onchange = async () => {
          const fl = file.files[0]; if (!fl) return;
          msg.textContent = 'Uploading…';
          try { set(await upload(fl)); select(b.id); } catch (e) { msg.textContent = e.message || 'Upload failed'; }
        };
        f.append(w);
      }
    }
    box.append(f);
  }
  return box;
}
function linkPrompt(sel, done) {
  const m = $('#modal');
  m.innerHTML = `<div class="modal card" style="max-width:420px"><div class="pad"><b style="font-size:16px">Add a link</b>
    <label class="f">Link text</label><input class="inp" id="lkT" value="${esc(sel || '')}" placeholder="e.g. See the menu">
    <label class="f">Web address</label><input class="inp" id="lkU" value="https://">
    <div class="row" style="justify-content:flex-end;gap:8px;margin-top:16px"><button class="btn" data-act="closeModal">Cancel</button><button class="btn pri" id="lkGo">Add link</button></div></div></div>`;
  m.classList.add('show'); setTimeout(() => $('#lkU').focus(), 30);
  $('#lkGo').onclick = () => { const u = $('#lkU').value.trim(); if (!/^(https?:\/\/|mailto:|tel:)/i.test(u) || u === 'https://') return toast('Enter a web address starting with https://'); sel = $('#lkT').value || sel; A.closeModal(); done(u); };
}
// Shrink big photos, then upload to the venue's folder in the bk-email bucket
async function upload(file) {
  if (file.size > 5e6 && file.type === 'image/gif') throw new Error('GIFs must be under 5 MB');
  let blob = file;
  if (file.type !== 'image/gif' && file.size > 400e3) {
    const url = URL.createObjectURL(file);
    try {
      const img = await new Promise((res, rej) => { const i = new Image(); i.onload = () => res(i); i.onerror = () => rej(new Error('That image could not be opened')); i.src = url; });
      const w = Math.min(1200, img.width), hh = Math.round((img.height * w) / img.width);
      const cv = Object.assign(document.createElement('canvas'), { width: w, height: hh }); cv.getContext('2d').drawImage(img, 0, 0, w, hh);
      blob = await new Promise((res) => cv.toBlob(res, file.type === 'image/png' ? 'image/png' : 'image/jpeg', 0.85));
    } finally { URL.revokeObjectURL(url); }
  }
  const ext = { 'image/png': 'png', 'image/gif': 'gif', 'image/webp': 'webp' }[blob.type] || 'jpg';
  const path = `${venue()}/${crypto.randomUUID()}.${ext}`;
  const { error } = await sb().storage.from('bk-email').upload(path, blob, { contentType: blob.type, cacheControl: '31536000' });
  if (error) throw new Error('Upload failed: ' + error.message);
  return sb().storage.from('bk-email').getPublicUrl(path).data.publicUrl;
}

function inbox() {
  const c = C.cur, q = (s) => C.el.querySelector(s); if (!q('#ibFrom')) return;
  const from = c.from_name || S.venue.name || 'Your venue';
  q('#ibFrom').textContent = from; q('#ibAv').textContent = from.trim()[0]?.toUpperCase() || '?';
  q('#ibSubj').textContent = (c.subject || 'No subject yet').replace(/\{\{\s*name\s*\}\}/gi, 'Alex').replace(/\{\{\s*site\s*\}\}/gi, from);
  q('#ibPre').textContent = c.preheader ? '– ' + c.preheader : '';
  q('#cmpSubjLen').textContent = (c.subject || '').length;
  q('#cmpDot').hidden = !!c.subject;
}
function audienceLine() {
  const n = audience(), a = C.el?.querySelector('#cmpAud'); if (!a) return;
  a.textContent = C.unsubs ? n : '…'; C.el.querySelector('#cmpAudW').textContent = n === 1 ? 'guest has' : 'guests have';
}

// live preview (rendered here, with the same code that sends the email)
function preview(now) {
  clearTimeout(C.pvT);
  C.pvT = setTimeout(() => {
    const f = C.el?.querySelector('#cmpPv'); if (!f || !f.isConnected) return;
    const y = f.contentWindow?.scrollY || 0;
    f.onload = () => {
      const d = f.contentDocument; if (!d) return;
      const st = d.createElement('style');
      st.textContent = '[data-bid]{cursor:pointer}[data-bid]:hover>td{outline:2px dashed #8aa3e6;outline-offset:-2px}[data-bid].sel>td{outline:2px solid #4a6cd0;outline-offset:-2px}';
      d.head.append(st);
      d.addEventListener('click', (e) => { e.preventDefault(); const t = e.target.closest('[data-bid]'); if (t) { C.el.querySelector('.dz-tabs button').click(); select(t.dataset.bid); } }, true);
      f.contentWindow.scrollTo(0, y); highlight(); fit();
    };
    f.srcdoc = emailHtml(C.cur, true);
  }, now ? 0 : 200);
}
function highlight() {
  const d = C.el?.querySelector('#cmpPv')?.contentDocument; if (!d) return;
  d.querySelectorAll('[data-bid]').forEach((x) => x.classList.toggle('sel', x.dataset.bid === C.sel));
  if (C.sel) d.querySelector(`[data-bid="${C.sel}"]`)?.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
}
function fit() { try { const f = C.el.querySelector('#cmpPv'); f.style.height = Math.max(600, f.contentDocument.documentElement.scrollHeight + 4) + 'px'; } catch { /* not ready */ } }
addEventListener('resize', () => { if (U.view === 'campaigns' && C.mode === 'edit') fit(); });

// saving (debounced, straight to the database)
const saveState = (t, bad) => { const s = C.el?.querySelector('#cmpSave'); if (s) { s.textContent = t; s.style.color = bad ? 'var(--bad)' : ''; } };
function changed(structural) {
  C.dirty = true; saveState('Unsaved changes');
  if (structural) renderBlocks();
  inbox(); preview();
  clearTimeout(C.saveT); C.saveT = setTimeout(save, 900);
}
async function save() {
  clearTimeout(C.saveT);
  if (C.saving) await C.saving;
  if (!C.dirty || !C.cur) return true;
  C.dirty = false; saveState('Saving…');
  const c = C.cur;
  C.saving = sb().from('bk_campaigns').update({ name: c.name || 'Untitled campaign', subject: c.subject || '', preheader: c.preheader || '', from_name: c.from_name || '', reply_to: c.reply_to || '', design: c.design }).eq('id', c.id).select('id,status')
    .then(({ data, error }) => {
      if (error) throw error;
      if (!data?.length) throw new Error('This campaign can’t be changed any more (it may have been sent).');
      saveState('Saved'); return true;
    })
    .catch((e) => { C.dirty = true; saveState('Not saved: ' + (e.message || e), true); return false; })
    .finally(() => { C.saving = null; });
  return C.saving;
}
async function leaveEditor() { if (C.mode === 'edit') await save(); }
addEventListener('beforeunload', (e) => { if (C.dirty) { save(); e.preventDefault(); e.returnValue = ''; } });

function testDialog() {
  save();
  const m = $('#modal');
  m.innerHTML = `<div class="modal card" style="max-width:440px"><div class="pad"><b style="font-size:17px">Send a test email</b>
    <p class="mut" style="margin:6px 0 4px">See exactly how it looks in a real inbox. Tests are marked [TEST] and use the name “Alex”.</p>
    <label class="f">Send to</label><input class="inp" id="tstTo" type="email" placeholder="you@yourvenue.co.uk" value="${esc(localStorage.getItem('pvbk.testEmail') || CLOUD.user?.email || '')}">
    <div id="tstMsg" style="margin-top:10px"></div>
    <div class="row" style="justify-content:flex-end;gap:8px;margin-top:16px"><button class="btn" data-act="closeModal">Close</button><button class="btn pri" id="tstGo">Send test</button></div></div></div>`;
  m.classList.add('show');
  $('#tstGo').onclick = async () => {
    const email = $('#tstTo').value.trim(); if (!EMAIL_RE.test(email)) return ($('#tstMsg').innerHTML = '<div class="notice bad">Enter a valid email address.</div>');
    localStorage.setItem('pvbk.testEmail', email); $('#tstGo').disabled = true; $('#tstMsg').innerHTML = '<span class="mut">Sending…</span>';
    try { await save(); await invoke({ action: 'test', id: C.cur.id, email }); $('#tstMsg').innerHTML = `<div class="notice ok">Test sent to ${esc(email)}. Check your inbox (and spam folder).</div>`; }
    catch (e) { $('#tstMsg').innerHTML = `<div class="notice bad">${esc(e.message)}</div>`; }
    $('#tstGo').disabled = false;
  };
}

async function sendDialog() {
  await save(); await loadUnsubs();
  const c = C.cur, n = audience();
  const probs = [];
  if (!c.subject) probs.push('Add a subject line (Settings tab).');
  if (!n) probs.push('Nobody in your guest book has agreed to marketing yet.');
  if (!normaliseDesign(c.design).blocks.length) probs.push('Your email has no content.');
  if (C.cfg && !C.cfg.configured) probs.push('Email sending isn’t switched on yet. Contact Proview.');
  const min = new Date(Date.now() + 10 * 60e3); min.setSeconds(0, 0);
  const p2 = (x) => String(x).padStart(2, '0');
  const minS = `${min.getFullYear()}-${p2(min.getMonth() + 1)}-${p2(min.getDate())}T${p2(min.getHours())}:${p2(min.getMinutes())}`;
  const m = $('#modal');
  m.innerHTML = `<div class="modal card" style="max-width:480px"><div class="pad"><b style="font-size:17px">Ready to send?</b>
    <div class="send-sum"><div><span class="mut">To</span><b>${n} ${n === 1 ? 'guest who agreed' : 'guests who agreed'} to marketing</b></div><div><span class="mut">Subject</span><b>${esc(C.el.querySelector('#ibSubj')?.textContent || c.subject)}</b></div><div><span class="mut">From</span><b>${esc(c.from_name || S.venue.name)}</b></div></div>
    ${probs.length ? `<div class="notice bad">${probs.map(esc).join('<br>')}</div>` : ''}
    <label class="row" style="gap:8px;margin-top:12px;cursor:pointer"><input type="radio" name="when" value="now" checked> Send now</label>
    <label class="row" style="gap:8px;margin-top:6px;cursor:pointer"><input type="radio" name="when" value="later"> Schedule for later</label>
    <div id="whenLater" hidden style="margin:6px 0 0 26px"><input class="inp" type="datetime-local" id="sched" min="${minS}" style="max-width:260px"></div>
    <label class="row" style="gap:8px;margin-top:14px;cursor:pointer;align-items:flex-start"><input type="checkbox" id="sendOk" style="margin-top:3px"> <span>I confirm these guests agreed to receive marketing emails and this email is from us.</span></label>
    <div id="sendMsg" style="margin-top:10px"></div>
    <div class="row" style="justify-content:flex-end;gap:8px;margin-top:16px"><button class="btn" data-act="closeModal">Cancel</button><button class="btn pri" id="sendGo" ${probs.length ? 'disabled' : ''}>Send now</button></div></div></div>`;
  m.classList.add('show');
  m.querySelectorAll('input[name=when]').forEach((r) => (r.onchange = () => { const later = m.querySelector('input[name=when]:checked').value === 'later'; $('#whenLater').hidden = !later; $('#sendGo').textContent = later ? 'Schedule' : 'Send now'; }));
  $('#sendGo').onclick = async () => {
    const msg = (t) => ($('#sendMsg').innerHTML = `<div class="notice bad">${esc(t)}</div>`);
    if (!$('#sendOk').checked) return msg('Tick the box to confirm these guests agreed to marketing.');
    const later = m.querySelector('input[name=when]:checked').value === 'later';
    $('#sendGo').disabled = true; $('#sendGo').textContent = later ? 'Scheduling…' : 'Starting…';
    try {
      if (later) {
        const v = $('#sched').value, at = v && new Date(v);
        if (!at || isNaN(at) || at < Date.now() + 5 * 60e3) throw new Error('Choose a time at least 10 minutes from now.');
        const { error } = await sb().from('bk_campaigns').update({ status: 'scheduled', scheduled_at: at.toISOString() }).eq('id', c.id);
        if (error) throw error;
        A.closeModal(); toast('Scheduled for ' + fmt(at)); C.list = null; return open(c.id);
      }
      const r = await invoke({ action: 'send', id: c.id });
      A.closeModal(); toast(`Sending to ${r.recipients} ${r.recipients === 1 ? 'guest' : 'guests'}`); C.list = null; open(c.id);
    } catch (e) { msg(e.message || String(e)); $('#sendGo').disabled = false; $('#sendGo').textContent = later ? 'Schedule' : 'Send now'; }
  };
}
async function unschedule() {
  const { error } = await sb().from('bk_campaigns').update({ status: 'draft', scheduled_at: null }).eq('id', C.cur.id);
  if (error) return toast('Couldn’t cancel: ' + error.message);
  toast('Schedule cancelled. The campaign is a draft again.'); open(C.cur.id);
}
function delDraft() {
  const m = $('#modal');
  m.innerHTML = `<div class="modal card" style="max-width:400px"><div class="pad"><b style="font-size:17px">Delete this draft?</b><p class="mut">“${esc(C.cur.name)}” will be deleted. This can’t be undone.</p>
    <div class="row" style="justify-content:flex-end;gap:8px;margin-top:16px"><button class="btn" data-act="closeModal">Cancel</button><button class="btn pri" id="delGo" style="background:var(--bad)">Delete</button></div></div></div>`;
  m.classList.add('show');
  $('#delGo').onclick = async () => {
    const { error } = await sb().from('bk_campaigns').delete().eq('id', C.cur.id);
    A.closeModal(); if (error) return toast('Couldn’t delete: ' + error.message);
    C.dirty = false; C.cur = null; C.mode = 'list'; C.list = null; toast('Draft deleted'); paint();
  };
}

/* ---------- report ---------- */
async function paintReport() {
  const c = C.cur;
  C.el.className = 'cmp';
  const [st, rows] = await Promise.all([
    sb().rpc('bk_campaign_stats', { p_venue: venue() }).then((r) => (r.data || []).find((x) => x.campaign_id === c.id) || {}),
    sb().from('bk_campaign_recipients').select('email,name,status,error,opened_at,clicked_at,unsub_at').eq('campaign_id', c.id).order('id').limit(500).then((r) => r.data || []),
  ]);
  if (C.mode !== 'report' || C.cur?.id !== c.id) return;
  const s = st, done = (s.sent || 0) + (s.failed || 0) + (s.skipped || 0);
  const lbl = { sending: ['amber', 'Sending…'], sent: ['green', 'Sent'], cancelled: ['red', 'Stopped'] }[c.status] || ['', c.status];
  C.el.innerHTML = `
    <div class="dz-top"><div class="dz-title"><button class="crumb" data-r="back">${ic('left', 14)} Email campaigns</button><h2 style="margin:2px 0 4px">${esc(c.name)}</h2>
      <div class="small mut"><span class="chip ${lbl[0]}">${lbl[1]}</span> “${esc(c.subject)}” · started ${esc(fmt(c.started_at))}</div></div>
      <div class="row" style="gap:8px">${c.status === 'sending' ? '<button class="btn" data-r="stop" style="color:var(--bad)">Stop sending</button>' : ''}<button class="btn" data-r="copy">Copy &amp; edit</button></div></div>
    ${c.status === 'sending' ? `<div class="card pad" style="margin-bottom:14px"><div class="row between"><b>Sending: ${done} of ${s.total || 0}</b><span class="small mut">Updates automatically</span></div><div class="prog"><div style="width:${s.total ? Math.round((done / s.total) * 100) : 0}%"></div></div></div>` : ''}
    <div class="stats">
      <div class="card stat"><div class="k">Delivered</div><div class="v">${s.sent || 0}</div></div>
      <div class="card stat"><div class="k">Opened</div><div class="v">${pct(s.opened, s.sent) === '—' ? '0%' : pct(s.opened, s.sent)}</div><div class="small mut">${s.opened || 0} people</div></div>
      <div class="card stat"><div class="k">Clicked</div><div class="v">${pct(s.clicked, s.sent) === '—' ? '0%' : pct(s.clicked, s.sent)}</div><div class="small mut">${s.clicked || 0} people</div></div>
      <div class="card stat"><div class="k">Unsubscribed</div><div class="v">${s.unsubscribed || 0}</div></div>
      <div class="card stat"><div class="k">Failed / skipped</div><div class="v">${(s.failed || 0) + (s.skipped || 0)}</div></div>
    </div>
    <div class="grid2" style="align-items:start">
      <div class="card"><div class="pad"><b>Recipients</b></div><div style="max-height:560px;overflow:auto"><table class="t"><thead><tr><th>Guest</th><th>Status</th><th>Opened</th><th>Clicked</th></tr></thead><tbody>
        ${rows.map((r) => `<tr><td><b>${esc(r.name || r.email)}</b><div class="small mut">${esc(r.email)}${r.unsub_at ? ' · <span style="color:var(--bad)">Unsubscribed</span>' : ''}</div></td>
          <td><span class="chip ${r.status === 'sent' ? 'green' : r.status === 'failed' ? 'red' : r.status === 'pending' ? 'amber' : ''}" title="${esc(r.error || '')}">${esc({ sent: 'Sent', failed: 'Failed', pending: 'Queued', skipped: 'Skipped' }[r.status] || r.status)}</span></td>
          <td class="small mut">${r.opened_at ? esc(fmt(r.opened_at)) : '—'}</td><td class="small mut">${r.clicked_at ? esc(fmt(r.clicked_at)) : '—'}</td></tr>`).join('') || '<tr><td colspan="4" class="mut">Nobody to send to.</td></tr>'}
      </tbody></table></div>${(s.total || 0) > rows.length ? `<div class="pad small mut">Showing the first ${rows.length} of ${s.total}.</div>` : ''}</div>
      <div class="card" style="overflow:hidden;padding:0"><iframe id="cmpView" title="The email" style="width:100%;height:640px;border:0;display:block"></iframe></div>
    </div>
    <p class="small mut" style="margin-top:12px">Open rates are estimates: some email apps block tracking images, and others open every email automatically.</p>`;
  C.el.querySelector('#cmpView').srcdoc = emailHtml(c);
  C.el.onclick = async (e) => {
    const b = e.target.closest('[data-r]'); if (!b) return;
    if (b.dataset.r === 'back') { C.mode = 'list'; C.list = null; return paint(); }
    if (b.dataset.r === 'copy') return copy(c.id);
    if (b.dataset.r === 'stop') {
      b.disabled = true;
      try { await invoke({ action: 'cancel', id: c.id }); toast('Stopped. Guests who hadn’t been emailed yet were skipped.'); open(c.id); } catch (er) { toast(er.message); b.disabled = false; }
    }
  };
  if (c.status === 'sending') C.pollT = setInterval(async () => {
    if (U.view !== 'campaigns' || C.mode !== 'report') return clearInterval(C.pollT);
    const { data } = await sb().from('bk_campaigns').select('*').eq('id', c.id).single();
    if (data) { C.cur = data; paintReport(); }
  }, 5000);
}

/* ---------- styles (same designer as Proview WiFi, Bookings colours) ---------- */
document.head.append(h(`<style>
.cmp .crumb{border:0;background:none;padding:0;color:var(--mut);font:inherit;font-size:13px;cursor:pointer;display:flex;align-items:center;gap:4px;margin-bottom:4px}
.cmp .crumb:hover{color:var(--pri)}
.dz-top{display:flex;align-items:flex-end;justify-content:space-between;gap:14px;margin-bottom:14px;flex-wrap:wrap}
.dz-title{flex:1;min-width:220px}
.dz-name{font:650 21px inherit;font-family:inherit;letter-spacing:-.01em;border:1px solid transparent;background:transparent;padding:4px 8px;margin-left:-8px;max-width:520px;width:100%;border-radius:8px;color:var(--ink)}
.dz-name:hover,.dz-name:focus{border-color:var(--line);background:var(--card);outline:none}
.dz-save{min-width:110px;text-align:right}
.dz{display:grid;grid-template-columns:380px 1fr;gap:16px;align-items:start}
@media (max-width:1100px){.dz{grid-template-columns:1fr}}
.dz-side{position:sticky;top:12px;max-height:calc(100vh - 110px);overflow:auto}
@media (max-width:1100px){.dz-side{position:static;max-height:none}}
.dz-tabs{display:flex;border-bottom:1px solid var(--line);position:sticky;top:0;background:var(--card);z-index:2;border-radius:var(--r) var(--r) 0 0}
.dz-tabs button{flex:1;border:0;background:none;font:600 14px inherit;font-family:inherit;color:var(--mut);padding:13px 8px 11px;border-bottom:2px solid transparent;cursor:pointer;position:relative}
.dz-tabs button.on{color:var(--ink);border-bottom-color:var(--pri)}
.dz-tabs .dot{position:absolute;top:10px;margin-left:4px;width:7px;height:7px;border-radius:50%;background:var(--bad);display:inline-block}
.dz-tab{padding:14px;display:flex;flex-direction:column;gap:12px}
.dz-tab[hidden]{display:none}
.dz-tab label.f{margin:0 0 6px}
.blocks{display:flex;flex-direction:column;gap:6px}
.blk-empty{border:2px dashed var(--line);border-radius:10px;padding:18px;text-align:center;color:var(--grey);font-size:14px}
.blk{border:1px solid var(--line);border-radius:10px;background:var(--card);transition:border-color .12s,box-shadow .12s}
.blk:hover{border-color:#cfccc4}
.blk.open{border-color:var(--pri);box-shadow:0 0 0 3px var(--pri-l)}
.blk.dragging{opacity:.4}
.blk.drop-before{box-shadow:0 -3px 0 var(--pri)}.blk.drop-after{box-shadow:0 3px 0 var(--pri)}
.blk-h{display:flex;align-items:center;gap:8px;padding:8px 8px 8px 6px;cursor:pointer}
.blk-h svg{width:16px;height:16px}
.grip{color:var(--grey);cursor:grab;display:grid;place-items:center;padding:2px}
.blk-ic{width:30px;height:30px;border-radius:8px;background:var(--pri-l);color:var(--pri);display:grid;place-items:center;flex:none}
.blk-t{flex:1;min-width:0;display:flex;flex-direction:column;line-height:1.25}
.blk-t b{font-size:13.5px}.blk-s{font-size:12.5px;color:var(--grey);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.blk-a{display:flex;opacity:.55}.blk:hover .blk-a,.blk.open .blk-a{opacity:1}
.blk-a button{border:0;background:none;width:26px;height:26px;border-radius:6px;display:grid;place-items:center;color:var(--mut);cursor:pointer;padding:0}
.blk-a button:hover:not(:disabled){background:var(--bg);color:var(--ink)}
.blk-a button:disabled{opacity:.3;cursor:default}
.blk-a button[data-a=del]:hover{color:var(--bad);background:var(--badl)}
.blk-b{border-top:1px solid var(--line);padding:12px;display:flex;flex-direction:column;gap:12px;background:#fcfbf9;border-radius:0 0 10px 10px}
.blk-b textarea{min-height:120px}
.hexin{max-width:110px}
.swatch{width:42px;height:38px;border:1px solid var(--line);border-radius:9px;padding:2px;background:var(--card);cursor:pointer}
.rt-bar{display:flex;gap:4px;margin-bottom:6px;flex-wrap:wrap}
.rt-bar button{border:1px solid var(--line);background:var(--card);border-radius:7px;height:28px;padding:0 9px;font:600 12.5px inherit;font-family:inherit;color:var(--mut);cursor:pointer}
.rt-bar button:hover{color:var(--ink);border-color:#cfccc4}
.img-f img{display:block;max-width:100%;max-height:120px;border-radius:8px;margin-bottom:8px;border:1px solid var(--line);background:repeating-conic-gradient(#eee 0 25%,#fff 0 50%) 0 0/14px 14px}
.img-f .up{position:relative;cursor:pointer;flex:none}
.add-title{font-size:11px;text-transform:uppercase;letter-spacing:.08em;color:var(--grey);font-weight:600;margin-top:4px}
.palette{display:grid;grid-template-columns:repeat(4,1fr);gap:6px}
.palette button{border:1px solid var(--line);background:var(--card);border-radius:10px;padding:10px 4px 8px;display:flex;flex-direction:column;align-items:center;gap:5px;font:600 11.5px inherit;font-family:inherit;color:var(--mut);cursor:pointer}
.palette button:hover{border-color:var(--pri);color:var(--pri);background:var(--pri-l)}
.palette svg{width:20px;height:20px}
.presets{display:grid;grid-template-columns:repeat(3,1fr);gap:6px}
.presets button{border:1px solid var(--line);background:var(--card);border-radius:10px;padding:6px;font:600 12px inherit;font-family:inherit;color:var(--mut);cursor:pointer;display:flex;flex-direction:column;gap:5px}
.presets button:hover{border-color:var(--pri)}
.presets span{height:34px;border-radius:6px;position:relative;display:block}
.presets i{position:absolute;left:18%;right:18%;top:6px;bottom:0;border-radius:4px 4px 0 0}
.presets b{position:absolute;left:36%;right:36%;bottom:7px;height:6px;border-radius:3px}
.aud{font-size:13.5px;color:var(--mut);padding:10px 12px;border:1px solid var(--line);border-radius:10px;background:var(--bg)}
.aud b{color:var(--ink)}
.dz-stage{min-width:0}
.inbox{display:flex;align-items:center;gap:12px;padding:12px 16px;margin-bottom:12px}
.inbox-av{width:38px;height:38px;border-radius:50%;background:var(--grad);color:#fff;display:grid;place-items:center;font-weight:700;flex:none}
.inbox-t{min-width:0;display:flex;flex-direction:column;font-size:14px}
.inbox-t>span{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.frame-wrap{border-radius:var(--r);overflow:hidden;border:1px solid var(--line);background:#fff;transition:max-width .2s;max-width:100%;margin:0 auto}
.frame-wrap.mobile{max-width:390px;border-radius:28px;border:8px solid #141418}
.frame-wrap iframe{width:100%;height:700px;border:0;display:block}
.cmp-tpl{display:grid;grid-template-columns:repeat(auto-fill,minmax(170px,1fr));gap:10px}
.cmp-tpl label{border:1px solid var(--line);border-radius:12px;padding:10px;display:flex;flex-direction:column;gap:4px;cursor:pointer}
.cmp-tpl label:has(input:checked){border-color:var(--pri);box-shadow:0 0 0 3px var(--pri-l)}
.cmp-tpl input{position:absolute;opacity:0;pointer-events:none}
.cmp-tpl .art{height:70px;border-radius:8px;position:relative;margin-bottom:4px}
.cmp-tpl .art i{position:absolute;left:18%;right:18%;height:7px;border-radius:4px;background:rgba(255,255,255,.75)}
.cmp-tpl .art i:nth-child(1){top:14px;right:40%}.cmp-tpl .art i:nth-child(2){top:30px}.cmp-tpl .art i:nth-child(3){top:46px;right:55%}
.send-sum{display:flex;flex-direction:column;gap:6px;margin:12px 0;padding:12px;border:1px solid var(--line);border-radius:10px;background:var(--bg)}
.send-sum div{display:flex;gap:10px}.send-sum span{min-width:60px}
.prog{height:8px;background:var(--bg);border-radius:4px;overflow:hidden;margin-top:10px}.prog div{height:100%;background:var(--grad)}
</style>`));

/* ---------- go ---------- */
if (typeof render === 'function' && CLOUD.on) renderNav();
window.PV_CAMPAIGNS = C;
