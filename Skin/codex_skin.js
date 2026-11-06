// Zero-One skin injector for the Codex desktop app. Runs inside the Codex page via the launcher's private
// debugging pipe. It only adds one <style> element and keeps the page in Codex's own dark theme;
// it never reads or changes conversation content. window.__zoSkinOff() removes everything again.
(function zoSkin() {
  const ID = 'zo-skin';
  const CSS = {{CSS_JSON}};
  // The launcher may evaluate this the moment a window is created, before the document has a root element.
  if (!document.documentElement) {
    if (window.__zoPending) return 'pending';
    window.__zoPending = true;
    const t = setInterval(() => { if (document.documentElement) { clearInterval(t); window.__zoPending = false; zoSkin(); } }, 16);
    return 'pending';
  }
  const html = document.documentElement;
  if (window.__zoSkin) { window.__zoSkin.css = CSS; window.__zoSkin.remap = undefined; window.__zoSkin.apply(); return 'updated'; }

  const state = { css: CSS, on: true, origTheme: null, observer: null };
  // Full app windows get the background; the transparent floating avatar window does not.
  const overlay = /avatar/i.test(decodeURIComponent(location.search));
  if (!overlay) html.setAttribute('data-zo-full', '');
  // Codex's own blue accents (#339cff family) are remapped to the key colour wherever they appear as
  // custom properties, so new variables in later Codex versions are covered too.
  // How each custom property is used (as a background or as a text / line colour), following var() chains,
  // so a blue background becomes a dark accent tint (its white text stays readable) while blue text becomes the accent.
  const usage = (rulesOf) => {
    const use = new Map(), refs = new Map();
    const mark = (n, k) => { const u = use.get(n) || { bg: false, fg: false }; u[k] = true; use.set(n, u); };
    const decl = /(--[\w-]+|[a-z-]+)\s*:\s*([^;]+)/g;
    for (const rules of rulesOf) {
      const walk = (rs) => { for (const r of rs) {
        if (r.style && r.style.cssText.includes('var(')) {
          for (const [, p, v] of r.style.cssText.matchAll(decl)) {
            const vs = v.match(/--[\w-]+/g); if (!vs) continue;
            if (p.startsWith('--')) { const set = refs.get(p) || new Set(); vs.forEach(x => set.add(x)); refs.set(p, set); continue; }
            const k = /^(background|fill)/.test(p) ? 'bg' : /^(color|stroke|caret-color|outline|border|text-decoration|column-rule)/.test(p) ? 'fg' : null;
            if (k) vs.forEach(x => mark(x, k));
          }
        }
        if (r.cssRules) walk(r.cssRules);
      } };
      walk(rules);
    }
    for (let pass = 0; pass < 4; pass++) for (const [a, set] of refs) {
      const u = use.get(a); if (!u) continue;
      for (const b of set) { if (u.bg) mark(b, 'bg'); if (u.fg) mark(b, 'fg'); }
    }
    return use;
  };
  // Any CSS colour (hex, rgb, hsl, oklab, oklch, color()) -> [r, g, b, a] in sRGB 0-255, via a 1x1 canvas.
  const cv = document.createElement('canvas'); cv.width = cv.height = 1;
  const cx = cv.getContext('2d', { willReadFrequently: true });
  const toRGBA = (v) => {
    const sentinel = 'rgba(1, 2, 3, 0.5)';
    cx.fillStyle = sentinel; const before = cx.fillStyle;
    cx.fillStyle = v; if (cx.fillStyle === before && !v.includes('1, 2, 3')) return null;
    cx.clearRect(0, 0, 1, 1); cx.fillRect(0, 0, 1, 1);
    const d = cx.getImageData(0, 0, 1, 1).data;
    return [d[0], d[1], d[2], d[3] / 255];
  };
  window.__zoToRGBA = toRGBA;
  const isColour = (v) => /^(#|rgb|hsl|oklch|oklab|lab\(|lch\(|color\()/.test(v);

  // Replacement for one variable value, or null to leave it. `scoped` = a declaration inside a nested selector
  // (only blues are replaced there).
  const classify = (n, v, use, scoped) => {
    const c = toRGBA(v); if (!c || c[3] < 0.02) return null;
    const [r, g, b, a] = c;
    const mx = Math.max(r, g, b), mn = Math.min(r, g, b);
    const u = use.get(n) || { bg: false, fg: false };
    if (mx - mn < 20) {
      // Neutral greys: same brightness, Hiden green tint. Text tones keep their hierarchy and contrast;
      // only dark background greys are tinted. Variables the skin sets explicitly are left alone.
      if (scoped || state.css.includes(n + ':')) return null;
      const nameFg = /(text|foreground|fg|icon|placeholder|label|caption|muted)/i.test(n);
      const fg = (u.fg && !u.bg) || (nameFg && !u.bg) || (nameFg && u.fg);
      const m = (r + g + b) / 3;
      let t = null;
      if (fg && m > 70) t = [m * 0.975, Math.min(255, m * 1.025), m * 0.93];
      else if (u.bg && !u.fg && m < 60) t = [m * 0.88, m * 1.06 + 1, m * 0.9];
      if (!t) return null;
      const [tr, tg, tb] = t.map(x => Math.round(Math.max(0, Math.min(255, x))));
      return `rgba(${tr}, ${tg}, ${tb}, ${+a.toFixed(3)})`;
    }
    if (mx - mn < 60) return null;
    let h = mx === r ? ((g - b) / (mx - mn)) % 6 : mx === g ? (b - r) / (mx - mn) + 2 : (r - g) / (mx - mn) + 4; h = (h * 60 + 360) % 360;
    if (h < 195 || h > 235) return null;                     // Codex blue range only
    const lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255;
    return lum > 0.8 ? `rgba(var(--zo-accent-rgb), ${+(0.16 * a).toFixed(3)})` : lum < 0.22 ? `rgba(var(--zo-accent-rgb), ${+(0.14 * a).toFixed(3)})`
         : (u.bg && !u.fg) ? `rgba(var(--zo-accent-rgb), ${+(0.24 * a).toFixed(3)})`
         : a < 0.99 ? `rgba(var(--zo-accent-rgb), ${+a.toFixed(3)})` : 'var(--zo-accent)';
  };

  const remapBlues = () => {
    const names = new Set(), rulesOf = [], scoped = new Map();   // selector -> [[name, literal value]]
    for (const sh of document.styleSheets) {
      let rules; try { rules = sh.cssRules } catch (e) { continue }
      rulesOf.push(rules);
      const walk = (rs) => { for (const r of rs) {
        if (r.style) for (const p of r.style) {
          if (!p.startsWith('--')) continue;
          names.add(p);
          const sel = r.selectorText;
          if (sel && !/^(:root|html)(\[[^\]]*\])*$/.test(sel.trim())) {
            const raw = r.style.getPropertyValue(p).trim();
            if (isColour(raw)) { const l = scoped.get(sel) || []; l.push([p, raw]); scoped.set(sel, l); }
          }
        }
        if (r.cssRules) walk(r.cssRules);
      } };
      walk(rules);
    }
    const use = usage(rulesOf);
    const cs = getComputedStyle(html);
    const rootOut = [], blocks = [];
    for (const n of names) {
      if (n.startsWith('--zo-')) continue;
      const v = cs.getPropertyValue(n).trim();
      if (!v || !isColour(v)) continue;
      const rep = classify(n, v, use, false);
      if (rep) rootOut.push(`${n}: ${rep} !important;`);
    }
    // Blues defined in nested scopes (a :root override would not reach them): override at the same selector.
    for (const [sel, decls] of scoped) {
      const o = [];
      for (const [n, raw] of decls) { if (n.startsWith('--zo-')) continue; const rep = classify(n, raw, use, true); if (rep) o.push(`${n}: ${rep} !important;`); }
      if (o.length) blocks.push(`${sel} { ${o.join(' ')} }`);
    }
    return (rootOut.length ? `:root, :root[data-theme] { ${rootOut.join(' ')} }\n` : '') + blocks.join('\n');
  };

  // Safety net: anything that still ends up on a solid accent background gets dark text.
  const seen = new WeakSet();
  const lumOf = (c) => { const m = toRGBA(c); return m ? (0.299 * m[0] + 0.587 * m[1] + 0.114 * m[2]) / 255 : 0; };
  // Parts of ChatGPT conversations carry their own data-theme="light" (they follow the light system setting);
  // switch those subtrees to dark as well, remembering the original value for __zoSkinOff.
  const darkenScopes = () => {
    for (const e of document.querySelectorAll('[data-theme]:not(html)')) {
      const t = e.getAttribute('data-theme');
      if (t !== 'dark') { if (!e.hasAttribute('data-zo-theme')) e.setAttribute('data-zo-theme', t); e.setAttribute('data-theme', 'dark'); }
    }
  };
  const fixOnAccent = () => {
    if (!state.on || !document.body) return;
    darkenScopes();
    const A = getComputedStyle(html).getPropertyValue('--zo-accent-rgb').split(',').map(Number);
    if (A.length < 3) return;
    for (const el of document.body.querySelectorAll('*')) {
      if (seen.has(el)) continue;
      seen.add(el);
      const st = getComputedStyle(el);
      const m = toRGBA(st.backgroundColor);
      if (!m || m[3] < 0.85) continue;
      if (Math.abs(m[0] - A[0]) + Math.abs(m[1] - A[1]) + Math.abs(m[2] - A[2]) > 60) continue;
      if (lumOf(st.color) > 0.5) el.classList.add('zo-on-accent');
    }
  };
  let fixTimer = 0;
  const scheduleFix = () => { clearTimeout(fixTimer); fixTimer = setTimeout(fixOnAccent, 250); };

  state.apply = () => {
    if (!state.on) return;
    if (!document.head) { setTimeout(state.apply, 50); return; }
    let s = document.getElementById(ID);
    if (!s) { s = document.createElement('style'); s.id = ID; document.head.appendChild(s); }
    if (state.origTheme === null) state.origTheme = html.getAttribute('data-theme');
    if (html.getAttribute('data-theme') !== 'dark') html.setAttribute('data-theme', 'dark');
    if (state.remap === undefined && document.body) { s.textContent = state.css; state.remap = remapBlues(); }
    const full = state.css + '\n' + (state.remap || '');
    if (s.textContent !== full) s.textContent = full;
    if (!state.observer) {
      state.observer = new MutationObserver((records) => {
        if (!state.on) return;
        if (html.getAttribute('data-theme') !== 'dark') html.setAttribute('data-theme', 'dark');
        if (!document.getElementById(ID)) { state.apply(); return; }
        // Codex adds its stylesheets after we start: rescan its blues once they have settled.
        if (records.some(r => r.type === 'childList' && [...r.addedNodes].some(n => n.id !== ID && /^(STYLE|LINK)$/.test(n.nodeName)))) state.rescan();
      });
      state.observer.observe(html, { attributes: true, attributeFilter: ['data-theme'] });
      if (document.head) state.observer.observe(document.head, { childList: true });
    }
    if (!state.bodyObserver && document.body) {
      state.bodyObserver = new MutationObserver((recs) => { if (recs.some(r => r.type === 'attributes')) darkenScopes(); scheduleFix(); });
      state.bodyObserver.observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ['data-theme'] });
      scheduleFix();
    }
  };
  state.rescan = () => {
    clearTimeout(state.rescanTimer);
    state.rescanTimer = setTimeout(() => { if (!state.on || !document.body) return; state.remap = remapBlues(); state.apply(); setTimeout(() => { document.querySelectorAll('*').forEach(e => seen.delete(e)); fixOnAccent(); }, 100); }, 300);
  };
  window.addEventListener('load', () => state.rescan());
  document.addEventListener('DOMContentLoaded', () => state.rescan());
  window.__zoSkinOff = () => {
    state.on = false;
    state.observer?.disconnect(); state.observer = null;
    state.bodyObserver?.disconnect(); state.bodyObserver = null;
    document.querySelectorAll('.zo-on-accent').forEach(e => e.classList.remove('zo-on-accent'));
    document.querySelectorAll('[data-zo-theme]').forEach(e => { e.setAttribute('data-theme', e.getAttribute('data-zo-theme')); e.removeAttribute('data-zo-theme'); });
    document.getElementById(ID)?.remove();
    if (state.origTheme !== null) html.setAttribute('data-theme', state.origTheme);
    html.removeAttribute('data-zo-full');
    delete window.__zoSkin;
    return 'off';
  };
  window.__zoSkin = state;
  // Ready = the app layout is up: the old layout class, or (any Codex version) the main area plus the composer.
  window.__zoReady = () => !!document.querySelector('[class*="_PageSurfaceLayout_"], [class*="PageSurfaceLayout-"]') || (!!document.querySelector('main') && !!document.querySelector('[data-composer-markdown], main [contenteditable="true"], [contenteditable="true"].ProseMirror, textarea'));
  window.__zoSkinReport = () => JSON.stringify({remapped: (state.remap.match(/;/g) || []).length});
  // Contrast audit for testing: visible text elements below `min` contrast against their effective background.
  // Reports class names, colours and ratio only, never the text itself.
  window.__zoContrastAudit = (min = 4.5) => {
    const parse = (c) => toRGBA(c) || [0, 0, 0, 0];
    const lin = (x) => { x /= 255; return x <= 0.03928 ? x / 12.92 : Math.pow((x + 0.055) / 1.055, 2.4); };
    const L = ([r, g, b]) => 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
    const bgOf = (el) => {
      let acc = null;
      for (let e = el; e; e = e.parentElement) {
        const c = parse(getComputedStyle(e).backgroundColor);
        if (c[3] === 0) continue;
        acc = acc ? acc.map((v, i) => i < 3 ? v * acc[3] + c[i] * c[3] * (1 - acc[3]) : 1) : c;   // rough front-to-back blend
        if (c[3] >= 0.95) break;
      }
      return acc || [4, 7, 5, 1];
    };
    const bad = [];
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    const done = new Set();
    while (walker.nextNode()) {
      const el = walker.currentNode.parentElement;
      if (!el || done.has(el) || !walker.currentNode.textContent.trim()) continue;
      done.add(el);
      const r = el.getBoundingClientRect(); if (r.width < 2 || r.height < 2) continue;
      const st = getComputedStyle(el); if (st.visibility === 'hidden' || +st.opacity === 0) continue;
      const fgc = parse(st.color), bgc = bgOf(el);
      const f = fgc[3] < 1 ? fgc.slice(0, 3).map((v, i) => v * fgc[3] + bgc[i] * (1 - fgc[3])) : fgc;
      const a = L(f), b = L(bgc), ratio = (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
      if (ratio < min) bad.push({ ratio: +ratio.toFixed(2), cls: (el.className && el.className.baseVal === undefined ? el.className : '').toString().split(' ').filter(c => /^_/.test(c)).slice(0, 3).join(' ') || el.tagName,
                                  color: st.color, bg: `rgb(${bgc.slice(0, 3).map(Math.round).join(', ')})`, size: st.fontSize });
    }
    bad.sort((x, y) => x.ratio - y.ratio);
    return JSON.stringify({ checked: done.size, low: bad.length, worst: bad.slice(0, 25) });
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', state.apply, { once: true });
  state.apply();
  return 'on';
})()
