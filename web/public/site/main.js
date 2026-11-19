// usetotality.com: scroll-driven scenes. No network, no HTML parsing, and nothing stored but a remembered theme.
(() => {
  'use strict';
  const RM = matchMedia('(prefers-reduced-motion: reduce)').matches;
  if (RM) document.documentElement.classList.add('rm');
  const $ = (s, r = document) => r.querySelector(s), $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
  const lerp = (a, b, t) => a + (b - a) * t;
  const ease = t => t < .5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;
  const prog = el => { const r = el.getBoundingClientRect(); const run = r.height - innerHeight; return run > 0 ? clamp(-r.top / run) : (r.top < 0 ? 1 : 0); };

  /* Themes: a pick is kept on this device only */
  const SKINS = ['light', 'blush', 'sky', 'sage', 'lilac', 'graphite'];
  const discs = $$('.disc');
  let chosen = null, held = false;
  function skin(s) {
    if (!SKINS.includes(s)) return;
    chosen = s; document.body.dataset.skin = s;
    discs.forEach(b => b.setAttribute('aria-pressed', String(b.dataset.skin === s)));
    try { localStorage.setItem('theme', s); } catch (e) { /* storage blocked: the pick lasts this visit */ }
  }
  discs.forEach(b => b.addEventListener('click', () => { held = true; clearSweep(); skin(b.dataset.skin); }));
  try { skin(localStorage.getItem('theme')); } catch (e) { /* no stored theme */ }

  /* Hero: parallax on scroll, depth on pointer */
  const word = $('#word'), hcopy = $('#hcopy'), hphone = $('#hphone'), hphoneIn = $('#hphone-in');
  const orbs = $$('.orb');
  let mx = 0, my = 0, tx = 0, ty = 0;
  if (!RM) addEventListener('pointermove', e => { tx = e.clientX / innerWidth * 2 - 1; ty = e.clientY / innerHeight * 2 - 1; }, { passive: true });
  function hero() {
    const y = scrollY, vh = innerHeight;
    if (y > vh * 1.4) return;
    const k = clamp(y / (vh * .9));
    mx += (tx - mx) * .08; my += (ty - my) * .08;
    word.style.transform = `translate3d(${mx * -14}px, ${y * .42}px, 0) scale(${1 - k * .12})`;
    word.style.opacity = String(1 - k * .9);
    hcopy.style.transform = `translate3d(0, ${y * .18}px, 0)`;
    hcopy.style.opacity = String(1 - clamp(k * 1.6));
    hphone.style.transform = `translate3d(calc(-50% + ${mx * 10}px), ${-y * .38}px, 0)`;
    hphoneIn.style.transform = `rotateX(${lerp(34, 0, ease(k))}deg) rotateY(${mx * -6}deg)`;
    orbs.forEach(o => {
      const d = +o.dataset.d;
      o.style.transform = `translate3d(${mx * 26 * d}px, ${my * 20 * d - y * d * .75}px, 0)`;
    });
  }

  /* Seal: the sentence turns to ciphertext and drifts off */
  const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  const sent = $('#sentence'), cap1 = $('#cap1'), cap2 = $('#cap2');
  const plain = sent.textContent;
  sent.textContent = '';
  const chars = [];
  let h = 2166136261;
  plain.split(' ').forEach((w, wi, arr) => {
    const ws = document.createElement('span'); ws.className = 'wrd'; ws.setAttribute('aria-hidden', 'true');
    for (const ch of w) {
      h = Math.imul(h ^ ch.charCodeAt(0), 16777619);
      const s = document.createElement('span'); s.className = 'c'; s.textContent = ch;
      chars.push({ el: s, p: ch, x: B64[(h >>> 9) & 63], r: ((h >>> 3) & 255) / 255, r2: ((h >>> 17) & 255) / 255, on: false });
      ws.append(s);
    }
    sent.append(ws); if (wi < arr.length - 1) sent.append(' ');
  });
  function seal(p) {
    const n = chars.length;
    const q = clamp((p - .14) / .46);
    const drift = RM ? 0 : clamp((p - .55) / .4);
    chars.forEach((c, i) => {
      const at = i / n * .85 + c.r * .15;
      const on = q > at;
      if (on !== c.on) { c.on = on; c.el.textContent = on ? c.x : c.p; c.el.classList.toggle('x', on); }
      if (RM) return;
      const pop = on ? (1 - clamp((q - at) * 6)) * -12 : 0;
      c.el.style.transform = `translate3d(${drift * (c.r2 - .5) * 70}px, ${pop - drift * (40 + c.r * 150)}px, 0)`;
      c.el.style.opacity = String(1 - drift * (.25 + c.r * .45));
    });
    if (RM) return;
    cap1.style.opacity = String(1 - clamp((p - .1) / .12));
    const c2 = clamp((p - .58) / .14);
    cap2.style.opacity = String(c2);
    cap2.style.transform = `translate3d(0, ${(1 - c2) * 40}px, 0)`;
  }

  /* Seven apps: tiles lift off the phone and spread to fill the screen */
  const cards = $$('.card'), slots = $$('#slots > div'), sphone = $('#sphone'), appsH = $('.apps-h');
  let geo = [];
  function measure() {
    cards.forEach(c => { c.style.transform = 'none'; });
    sphone.style.transform = 'translate(-50%,-50%)';
    geo = cards.map((c, i) => {
      const a = c.getBoundingClientRect(), b = slots[i].getBoundingClientRect();
      return { dx: b.left - a.left, dy: b.top - a.top, sx: b.width / a.width, sy: b.height / a.height };
    });
  }
  function apps(p) {
    if (RM) return;
    if (!geo.length) measure();
    const e = ease(clamp((p - .08) / .62));
    cards.forEach((c, i) => {
      const g = geo[i], s = ease(clamp(e * 1.25 - i * .035));
      c.style.transform = s >= 1 ? 'none' : `translate3d(${g.dx * (1 - s)}px, ${g.dy * (1 - s)}px, 0) scale(${lerp(g.sx, 1, s)}, ${lerp(g.sy, 1, s)})`;
      c.firstElementChild.style.opacity = String(clamp((s - .55) / .4));
    });
    sphone.style.opacity = String(1 - clamp(e * 2.2));
    sphone.style.transform = `translate(-50%,-50%) scale(${1 + e * .5})`;
    const hh = clamp((p - .55) / .15);
    appsH.style.opacity = String(hh);
    appsH.style.transform = `translate3d(0, ${(1 - hh) * 30}px, 0)`;
  }

  /* Themes: scrolling sweeps the whole page through all six (values from Tokens.swift) */
  const T = [
    ['#E8EBEF','#EDEFF2','#E2E5EA',[255,255,255,.9],[195,201,211,.7],'#15181D','#555C68','#1F5FBF','#FFFFFF','#D3E0F4','#A9C5EE'],
    ['#F2E6E6','#F7ECEC','#EADCDC',[255,255,255,.9],[214,190,190,.7],'#15181D','#6A5555','#A83636','#FFFFFF','#F3D3D3','#E8B4B4'],
    ['#E3ECF5','#EAF1F8','#D9E3EE',[255,255,255,.9],[186,200,218,.7],'#15181D','#4F5D6E','#1F5FBF','#FFFFFF','#CFE0F2','#A9C5EE'],
    ['#E5EEE7','#ECF3EE','#DAE5DD',[255,255,255,.9],[188,206,194,.7],'#15181D','#52625A','#2E6B47','#FFFFFF','#D2E6D8','#AFD2B9'],
    ['#ECE8F3','#F1EEF7','#E1DCEB',[255,255,255,.9],[203,196,219,.7],'#15181D','#5C5870','#5B45A8','#FFFFFF','#E0D8F0','#C7B8E6'],
    ['#2A2E34','#30353C','#25292E',[255,255,255,.06],[0,0,0,.45],   '#E7E9ED','#A7AEB9','#8DB2EE','#16191E','#33405A','#44577D']
  ];
  const KEYS = ['--bg','--surface','--flat','--sl','--sd','--fg','--muted','--accent','--on','--hl','--hls'];
  const rgba = v => typeof v === 'string' ? [1,3,5].map(i => parseInt(v.slice(i, i + 2), 16)).concat(1) : v;
  const mix = (a, b, t) => { const A = rgba(a), B = rgba(b); return `rgba(${A.map((v, i) => i < 3 ? Math.round(lerp(v, B[i], t)) : +lerp(v, B[i], t).toFixed(3)).join(',')})`; };
  const names = $$('#thnames span');
  let sweeping = false;
  function clearSweep() {
    if (!sweeping) return; sweeping = false;
    KEYS.forEach(k => document.body.style.removeProperty(k)); document.body.style.removeProperty('color-scheme');
    discs.forEach(b => b.setAttribute('aria-pressed', String(b.dataset.skin === chosen)));
  }
  function themes(p) {
    if (p <= 0 || p >= 1) held = false;
    if (RM || held || p <= 0 || p >= 1) { clearSweep(); return; }
    sweeping = true;
    const f = clamp(p * 1.08 - .02) * (T.length - 1);
    const i = Math.min(T.length - 2, Math.floor(f));
    const t = ease(clamp((f - i - .55) / .45));
    KEYS.forEach((k, j) => document.body.style.setProperty(k, mix(T[i][j], T[i + 1][j], t)));
    const cur = i + t;
    document.body.style.setProperty('color-scheme', cur > 4.5 ? 'dark' : 'light');
    names.forEach((n, k) => {
      const d = k - cur;
      n.style.opacity = String(clamp(1 - Math.abs(d) * 1.6));
      n.style.transform = `translate3d(0, ${d * 60}px, 0) scale(${1 - Math.min(.2, Math.abs(d) * .2)})`;
    });
    const near = Math.round(cur);
    discs.forEach((b, k) => b.setAttribute('aria-pressed', String(k === near)));
  }

  /* Listen: scroll reads the paragraph, word by word */
  const para = $('#para');
  const words = [];
  const ptext = para.textContent.trim();
  para.textContent = '';
  (ptext.match(/[^.]+\.\s*/g) || [ptext]).forEach(sx => {
    const s = document.createElement('span'); s.className = 's';
    sx.trim().split(/\s+/).forEach((w, i, a) => { const ws = document.createElement('span'); ws.className = 'w'; ws.textContent = w; s.append(ws); if (i < a.length - 1) s.append(' '); words.push([ws, s]); });
    para.append(s, ' ');
  });
  let lastW = -2;
  function listen(p) {
    const q = RM ? .28 : clamp((p - .1) / .8);
    const at = q <= 0 ? -1 : Math.min(words.length - 1, Math.floor(q * words.length));
    if (at === lastW) return; lastW = at;
    words.forEach(([w], i) => { w.classList.toggle('now', i === at); w.classList.toggle('ahead', !RM && at >= 0 && i > at); });
    $$('.s', para).forEach(s => s.classList.remove('on'));
    if (at >= 0) words[at][1].classList.add('on');
  }

  /* Sign-up lines slide against each other */
  const none = $('#none'), lines = $$('.line');
  function slide() {
    if (RM) return;
    const r = none.getBoundingClientRect();
    if (r.bottom < 0 || r.top > innerHeight) return;
    const p = clamp((innerHeight - r.top) / (innerHeight + r.height));
    lines.forEach(l => { const d = +l.dataset.x; l.style.transform = `translate3d(${(d > 0 ? -45 : -5) + p * d * 40}%, 0, 0)`; });
  }

  /* Photo thumbnails, painted locally */
  const skies = [['#F4C7A1','#E98B6D'],['#A9C9E8','#E8F0F7'],['#2E3A55','#6B5A8E'],['#CFE3C9','#F3F0DA']];
  const land = ['#3F5F4A','#4E6B80','#2B2F45','#5E7A52'];
  const alts = ['Beach at dusk','Morning sky over the bay','Night drive home','Meadow behind the cabin'];
  const thumbs = $('#thumbs');
  skies.forEach(([a, b], i) => {
    const c = document.createElement('canvas'); c.width = c.height = 80; c.setAttribute('role', 'img'); c.setAttribute('aria-label', alts[i]);
    const x = c.getContext('2d');
    if (x) {
      const g = x.createLinearGradient(0, 0, 0, 80); g.addColorStop(0, a); g.addColorStop(1, b);
      x.fillStyle = g; x.fillRect(0, 0, 80, 80);
      x.fillStyle = 'rgba(255,255,255,.75)'; x.beginPath(); x.arc(22 + i * 12, 26, 8, 0, 7); x.fill();
      x.fillStyle = land[i]; x.beginPath(); x.moveTo(0, 62); for (let k = 0; k <= 6; k++) x.lineTo(k * 80 / 6, 52 + 10 * Math.sin(k * 1.7 + i)); x.lineTo(80, 80); x.lineTo(0, 80); x.fill();
    }
    thumbs.append(c);
  });

  /* One frame loop for everything */
  const sealS = $('#seal'), appsS = $('#apps'), themesS = $('#themes'), listenS = $('#listen');
  let queued = false;
  function frame() {
    queued = false;
    if (!RM) hero();
    seal(RM ? .42 : prog(sealS));
    apps(prog(appsS));
    themes(prog(themesS));
    listen(prog(listenS));
    slide();
    if (!RM && Math.abs(tx - mx) + Math.abs(ty - my) > .002) queue();
  }
  const queue = () => { if (!queued) { queued = true; requestAnimationFrame(frame); } };
  addEventListener('scroll', queue, { passive: true });
  addEventListener('pointermove', queue, { passive: true });
  addEventListener('resize', () => { geo = []; queue(); });
  if (document.fonts) document.fonts.ready.then(() => { geo = []; queue(); });
  frame();
})();
