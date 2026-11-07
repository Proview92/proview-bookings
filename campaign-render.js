// Proview Bookings email campaigns: turns a design (theme + blocks) into email-safe HTML
// (tables + inline styles) that renders in Outlook, Gmail, Apple Mail and phones.
// Same design format as Proview WiFi. Used by the designer preview (browser) and by the
// bk-campaign edge function (Deno) so what you see is what guests get.
// Keep supabase/functions/bk-campaign/render.js and supabase/functions/bk-mail/render.js identical to this file.

export const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const color = (c, d) => (/^#[0-9a-f]{6}$/i.test(c || '') ? c : d);
export const safeUrl = (u) => { const s = String(u || '').trim(); return /^(https?:\/\/|mailto:|tel:)/i.test(s) ? s : ''; };
const FONTS = {
  sans: "-apple-system, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif",
  serif: "Georgia, 'Times New Roman', serif",
  rounded: "'Trebuchet MS', 'Segoe UI', Helvetica, Arial, sans-serif",
};

// Defaults for every block type (also used by the designer)
export const BLOCKS = {
  logo: { src: '', width: 160, align: 'center', link: '' },
  heading: { text: 'Your headline here', size: 'l', align: 'center' },
  text: { text: 'Hi {{name}},\n\nWrite your message here. Use **bold**, *italics* and [links](https://example.com).', align: 'left' },
  image: { src: '', alt: '', link: '', full: true },
  button: { label: 'Book now', url: 'https://', align: 'center', bg: '', fg: '#ffffff' },
  voucher: { title: 'Show this when you visit', code: 'THANKS10', note: 'Valid until 31 December' },
  divider: { color: '#e4e2dc' },
  spacer: { height: 24 },
};

export function normaliseDesign(d) {
  const theme = Object.assign({ bg: '#f4f3ef', content: '#ffffff', text: '#1d2330', accent: '#2f6fd8', font: 'sans', footer: '' }, d?.theme || {});
  const blocks = (Array.isArray(d?.blocks) ? d.blocks : []).filter((b) => BLOCKS[b?.type]).slice(0, 60).map((b) => ({ ...BLOCKS[b.type], ...b }));
  return { theme, blocks };
}

export const firstName = (n) => String(n || '').trim().split(/\s+/)[0] || '';
const align = (a) => (['left', 'center', 'right'].includes(a) ? a : 'left');

// Very small, safe markdown: **bold**, *italic*, [text](url), line breaks, paragraphs
function inline(text, ctx) {
  let s = esc(text);
  s = s.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (m, label, url) => {
    const u = safeUrl(url.replace(/&amp;/g, '&'));
    return u ? `<a href="${esc(ctx.link(u))}" style="color:${ctx.theme.accent};text-decoration:underline">${label}</a>` : label;
  });
  s = s.replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>').replace(/(^|[^*])\*(?!\s)(.+?)\*(?!\*)/g, '$1<em>$2</em>');
  return ctx.vars(s);
}

function block(b, ctx) {
  const t = ctx.theme;
  const row = (inner, padding) => `<tr><td style="${padding}">${inner}</td></tr>`;
  switch (b.type) {
    case 'logo': {
      if (!b.src) return ctx.preview ? row(`<div style="border:2px dashed #cfccc4;border-radius:8px;padding:18px;color:#8b8b95;font-size:13px;text-align:center;font-family:${ctx.font}">Logo: add an image link or upload</div>`, 'padding:24px 32px 8px') : '';
      const img = `<img src="${esc(b.src)}" width="${Math.min(560, Number(b.width) || 160)}" alt="${esc(ctx.venue)}" style="display:inline-block;max-width:100%;height:auto;border:0">`;
      const u = safeUrl(b.link);
      return row(`<div style="text-align:${align(b.align)}">${u ? `<a href="${esc(ctx.link(u))}">${img}</a>` : img}</div>`, 'padding:28px 32px 8px');
    }
    case 'heading': {
      const size = { s: 20, m: 26, l: 32, xl: 40 }[b.size] || 32;
      return row(`<h1 style="margin:0;font-family:${ctx.font};font-size:${size}px;line-height:1.2;font-weight:800;color:${t.text};text-align:${align(b.align)};letter-spacing:-0.01em">${ctx.vars(esc(b.text))}</h1>`, 'padding:18px 32px 6px');
    }
    case 'text': {
      const paras = String(b.text || '').split(/\n{2,}/).map((p) => `<p style="margin:0 0 14px">${inline(p, ctx).replace(/\n/g, '<br>')}</p>`).join('');
      return row(`<div style="font-family:${ctx.font};font-size:16px;line-height:1.6;color:${t.text};text-align:${align(b.align)}">${paras}</div>`, 'padding:10px 32px 0');
    }
    case 'image': {
      if (!b.src) return ctx.preview ? row(`<div style="border:2px dashed #cfccc4;border-radius:8px;padding:40px 18px;color:#8b8b95;font-size:13px;text-align:center;font-family:${ctx.font}">Image: add an image link or upload</div>`, 'padding:12px 32px') : '';
      const img = `<img src="${esc(b.src)}" width="${b.full ? 600 : 536}" alt="${esc(b.alt)}" style="display:block;width:100%;max-width:${b.full ? 600 : 536}px;height:auto;border:0${b.full ? '' : ';border-radius:8px'}">`;
      const u = safeUrl(b.link);
      return row(u ? `<a href="${esc(ctx.link(u))}">${img}</a>` : img, b.full ? 'padding:12px 0' : 'padding:12px 32px');
    }
    case 'button': {
      const bg = color(b.bg, t.accent), fg = color(b.fg, '#ffffff'), u = safeUrl(b.url);
      return row(`<table role="presentation" cellpadding="0" cellspacing="0" border="0" align="${align(b.align)}" style="margin:0 ${b.align === 'center' ? 'auto' : '0'}"><tr>
        <td style="border-radius:10px;background:${bg}" bgcolor="${bg}"><a href="${esc(u ? ctx.link(u) : '#')}" style="display:inline-block;padding:14px 28px;font-family:${ctx.font};font-size:16px;font-weight:700;color:${fg};text-decoration:none;border-radius:10px">${ctx.vars(esc(b.label))}</a></td></tr></table>`, 'padding:16px 32px');
    }
    case 'voucher':
      return row(`<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border:2px dashed ${t.accent};border-radius:12px"><tr><td style="padding:20px;text-align:center;font-family:${ctx.font};color:${t.text}">
        <div style="font-size:14px;font-weight:600;opacity:.8">${ctx.vars(esc(b.title))}</div>
        <div style="font-size:30px;font-weight:800;letter-spacing:.08em;color:${t.accent};margin:6px 0;font-family:'Courier New',monospace">${esc(b.code)}</div>
        <div style="font-size:13px;opacity:.7">${ctx.vars(esc(b.note))}</div></td></tr></table>`, 'padding:14px 32px');
    case 'divider':
      return row(`<div style="border-top:1px solid ${color(b.color, '#e4e2dc')};font-size:0;line-height:0">&nbsp;</div>`, 'padding:14px 32px');
    case 'spacer':
      return row(`<div style="height:${Math.max(4, Math.min(120, Number(b.height) || 24))}px;font-size:0;line-height:0">&nbsp;</div>`, 'padding:0');
  }
  return '';
}

/**
 * campaign: { subject, preheader, design, from_name }
 * opts: { preview, venue (name), recipient: { name },
 *         track: { link(url) -> url, unsub, view, pixel } (real sends; all optional) }
 */
export function renderEmail(campaign, opts = {}) {
  const { theme, blocks } = normaliseDesign(typeof campaign.design === 'string' ? JSON.parse(campaign.design || '{}') : campaign.design);
  theme.bg = color(theme.bg, '#f4f3ef'); theme.content = color(theme.content, '#ffffff');
  theme.text = color(theme.text, '#1d2330'); theme.accent = color(theme.accent, '#2f6fd8');
  const r = opts.recipient || {}, tr = opts.track || {};
  const venue = campaign.from_name || opts.venue || 'us';
  const ctx = {
    theme, preview: !!opts.preview, venue, font: FONTS[theme.font] || FONTS.sans,
    vars: (s) => s.replace(/\{\{\s*name\s*\}\}/gi, esc(firstName(r.name) || 'there')).replace(/\{\{\s*site\s*\}\}/gi, esc(venue)),
    link: (u) => (tr.link && /^https?:/i.test(u) ? tr.link(u) : u),
  };
  const footer = `<tr><td style="padding:24px 32px 30px;font-family:${ctx.font};font-size:12px;line-height:1.6;color:#8b8b95;text-align:center">
      ${theme.footer ? `<div style="margin-bottom:8px">${esc(theme.footer).replace(/\n/g, '<br>')}</div>` : ''}
      You're receiving this because you agreed to hear from ${esc(opts.venue || venue)} when you booked or joined the guest list.<br>
      <a href="${esc(tr.unsub || '#')}" style="color:#8b8b95;text-decoration:underline">Unsubscribe</a>${tr.view ? ` &middot; <a href="${esc(tr.view)}" style="color:#8b8b95;text-decoration:underline">View in browser</a>` : ''}
    </td></tr>`;
  const pixel = tr.pixel ? `<img src="${esc(tr.pixel)}" width="1" height="1" alt="" style="display:block;border:0">` : '';

  return `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="x-apple-disable-message-reformatting"><meta name="color-scheme" content="light"><title>${esc(campaign.subject || '')}</title>
<style>body{margin:0;padding:0}img{-ms-interpolation-mode:bicubic}a{color:${theme.accent}}@media (max-width:620px){.wrap{width:100%!important}}</style></head>
<body style="margin:0;padding:0;background:${theme.bg}">
<div style="display:none;max-height:0;overflow:hidden;opacity:0;color:transparent">${esc(campaign.preheader || '')}&#8199;&#65279;&#847;&#8199;&#65279;&#847;&#8199;&#65279;&#847;</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="${theme.bg}" style="background:${theme.bg}"><tr><td align="center" style="padding:24px 12px">
<table role="presentation" class="wrap" width="600" cellpadding="0" cellspacing="0" border="0" bgcolor="${theme.content}" style="width:600px;max-width:600px;background:${theme.content};border-radius:14px;overflow:hidden">
${blocks.map((b) => { const h = block(b, ctx); return ctx.preview && h ? h.replace(/^<tr>/, `<tr data-bid="${esc(b.id)}">`) : h; }).join('\n')}
<tr><td style="padding:18px 0 0"></td></tr>
</table>
<table role="presentation" class="wrap" width="600" cellpadding="0" cellspacing="0" border="0" style="width:600px;max-width:600px">${footer}</table>
${pixel}
</td></tr></table></body></html>`;
}

// Plain-text version (improves deliverability)
export function renderText(campaign, opts = {}) {
  const { blocks } = normaliseDesign(typeof campaign.design === 'string' ? JSON.parse(campaign.design || '{}') : campaign.design);
  const name = firstName(opts.recipient?.name) || 'there';
  const v = (s) => String(s || '').replace(/\{\{\s*name\s*\}\}/gi, name).replace(/\{\{\s*site\s*\}\}/gi, campaign.from_name || opts.venue || '');
  const out = blocks.map((b) => {
    if (b.type === 'heading') return v(b.text).toUpperCase();
    if (b.type === 'text') return v(b.text).replace(/\*\*(.+?)\*\*/g, '$1').replace(/\*(.+?)\*/g, '$1').replace(/\[([^\]]+)\]\(([^)]+)\)/g, '$1 ($2)');
    if (b.type === 'button' && safeUrl(b.url)) return `${v(b.label)}: ${b.url}`;
    if (b.type === 'voucher') return `${v(b.title)}: ${b.code}\n${v(b.note)}`;
    if (b.type === 'divider') return '----------';
    return null;
  }).filter(Boolean);
  if (opts.track?.unsub) out.push(`\nUnsubscribe: ${opts.track.unsub}`);
  return out.join('\n\n');
}

export function subjectFor(campaign, recipient, venue) {
  return String(campaign.subject || '(no subject)')
    .replace(/\{\{\s*name\s*\}\}/gi, firstName(recipient?.name) || 'there')
    .replace(/\{\{\s*site\s*\}\}/gi, campaign.from_name || venue || '');
}

// Starter designs offered when creating a campaign
const T = (theme, blocks) => ({ theme: { bg: '#f4f3ef', content: '#ffffff', text: '#1d2330', accent: '#2f6fd8', font: 'sans', footer: '', ...theme }, blocks });
let n = 0; const b = (type, props = {}) => ({ id: 'b' + (++n) + Math.random().toString(36).slice(2, 6), type, ...props });
export const TEMPLATES = {
  offer: {
    label: 'Special offer', desc: 'Discount or deal with a voucher code', swatch: 'linear-gradient(135deg,#f59e0b,#d9472b)',
    subject: 'A little thank you from {{site}}', preheader: 'Show this email for your discount',
    design: () => T({ accent: '#d9472b' }, [
      b('logo'), b('heading', { text: '10% off your next visit', size: 'l' }),
      b('text', { text: 'Hi {{name}},\n\nThanks for dining with us. As a thank you, here’s **10% off** your next visit. Just show this email when you order.', align: 'center' }),
      b('voucher', { title: 'Your code', code: 'THANKS10', note: 'Valid for 30 days. One per customer.' }),
      b('button', { label: 'Book a table', url: 'https://', align: 'center' }),
      b('spacer', { height: 12 }),
    ]),
  },
  event: {
    label: 'Event', desc: 'Promote a night, tasting menu or launch', swatch: 'linear-gradient(135deg,#141418,#7c5cff)',
    subject: 'You’re invited: this Friday at {{site}}', preheader: 'Live music, food and drinks',
    design: () => T({ bg: '#141418', accent: '#7c5cff' }, [
      b('logo'), b('image', { full: true }),
      b('heading', { text: 'Live music this Friday', size: 'xl' }),
      b('text', { text: 'Hi {{name}},\n\nJoin us from **8pm** for live music, great food and drinks offers all night.\n\nTables are limited, so book ahead.', align: 'center' }),
      b('button', { label: 'Reserve your table', url: 'https://', align: 'center' }),
      b('spacer', { height: 12 }),
    ]),
  },
  newsletter: {
    label: 'Newsletter', desc: 'News, menu changes and updates', swatch: 'linear-gradient(135deg,#2f84d4,#5a5fbb)',
    subject: 'What’s new at {{site}} this month', preheader: 'New menu, events and more',
    design: () => T({}, [
      b('logo', { align: 'left' }), b('heading', { text: 'What’s new this month', size: 'l', align: 'left' }),
      b('text', { text: 'Hi {{name}},\n\nHere’s a quick round-up of what’s happening.' }),
      b('image', { full: false }), b('heading', { text: 'New autumn menu', size: 's', align: 'left' }),
      b('text', { text: 'Seasonal dishes, all made in-house. [See the menu](https://example.com)' }),
      b('divider'), b('heading', { text: 'Coming up', size: 's', align: 'left' }),
      b('text', { text: '**Quiz night**: every Thursday, 7:30pm\n**Sunday roast**: served 12–5pm' }),
      b('button', { label: 'Book a table', url: 'https://', align: 'left' }),
    ]),
  },
  welcome: {
    label: 'We miss you', desc: 'Win back guests who haven’t visited lately', swatch: 'linear-gradient(135deg,#10b981,#2563eb)',
    subject: 'We’ve missed you, {{name}}', preheader: 'Come back and see what’s new',
    design: () => T({ accent: '#12a150' }, [
      b('logo'), b('heading', { text: 'We’ve missed you!', size: 'l' }),
      b('text', { text: 'Hi {{name}},\n\nIt’s been a while. Book your next visit and enjoy a **free dessert** on us.', align: 'center' }),
      b('voucher', { title: 'Free dessert', code: 'WELCOMEBACK', note: 'Show this email when you order' }),
      b('button', { label: 'Book a table', url: 'https://', align: 'center' }),
      b('spacer', { height: 12 }),
    ]),
  },
  blank: {
    label: 'Blank', desc: 'Start from scratch', swatch: '#eeece6',
    subject: '', preheader: '',
    design: () => T({}, [b('logo'), b('heading'), b('text')]),
  },
};
