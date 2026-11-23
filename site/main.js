/* DeckOS site: theme toggle, scroll reveals, the live hero deck and download detection.
   Plain ES2020, no dependencies. */
(() => {
  'use strict';

  const root = document.documentElement;
  const $ = (s, el = document) => el.querySelector(s);
  const $$ = (s, el = document) => [...el.querySelectorAll(s)];
  const motion = root.classList.contains('motion');
  const REPO = 'itskavin/DeckOS';
  const RELEASES = `https://github.com/${REPO}/releases/latest`;
  const DOCS = 'https://itskavin.github.io/DeckOS/docs/';

  /* ---------------- Theme ---------------- */
  const toggle = $('#theme-toggle');
  const lightQuery = matchMedia('(prefers-color-scheme: light)');
  const effective = () => root.getAttribute('data-theme') === 'light' || root.getAttribute('data-theme') === 'dark'
    ? root.getAttribute('data-theme')
    : (lightQuery.matches ? 'light' : 'dark');
  const syncTheme = () => {
    const t = effective();
    root.setAttribute('data-effective', t);
    toggle.setAttribute('aria-label', t === 'dark' ? 'Switch to light theme' : 'Switch to dark theme');
  };
  toggle.addEventListener('click', () => {
    const next = effective() === 'dark' ? 'light' : 'dark';
    root.setAttribute('data-theme', next);
    try { localStorage.setItem('deckos-theme', next); } catch (e) { /* private mode */ }
    syncTheme();
  });
  lightQuery.addEventListener?.('change', syncTheme);
  syncTheme();

  /* ---------------- Nav border on scroll ---------------- */
  const nav = $('.nav');
  const onScroll = () => nav.classList.toggle('scrolled', scrollY > 8);
  addEventListener('scroll', onScroll, { passive: true });
  onScroll();

  /* ---------------- Scroll-scrubbed statement ---------------- */
  for (const el of $$('[data-scrub]')) {
    const words = el.textContent.trim().split(/\s+/);
    el.textContent = '';
    words.forEach((w, i) => {
      const s = document.createElement('span');
      s.className = 'w';
      s.textContent = w;
      el.append(s, i < words.length - 1 ? ' ' : '');
    });
  }

  /* ---------------- Reveal on scroll ---------------- */
  const reveals = $$('[data-reveal]');
  const groups = new Map();
  for (const el of reveals) {
    const list = groups.get(el.parentElement) || [];
    el.style.setProperty('--d', `${Math.min(list.length, 7) * 0.06}s`);
    list.push(el);
    groups.set(el.parentElement, list);
  }
  if ('IntersectionObserver' in window && motion) {
    const io = new IntersectionObserver((entries) => {
      for (const e of entries) if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); }
    }, { rootMargin: '0px 0px -6% 0px', threshold: 0.08 });
    reveals.forEach((el) => io.observe(el));
  } else {
    reveals.forEach((el) => el.classList.add('in'));
  }

  /* Visibility helper: run callbacks only while an element is on screen. */
  const visible = new WeakMap();
  const vio = 'IntersectionObserver' in window
    ? new IntersectionObserver((es) => es.forEach((e) => visible.set(e.target, e.isIntersecting)), { threshold: 0.01 })
    : null;
  const watch = (el) => { if (vio && el) vio.observe(el); else if (el) visible.set(el, true); return el; };
  const onScreen = (el) => !!el && visible.get(el) === true && !document.hidden;

  /* ---------------- Hero deck ---------------- */
  const use = (id, brand) => `<svg class="${brand ? 'b' : 'i'}"><use href="#${id}"/></svg>`;
  const ring = '<svg class="ring" viewBox="0 0 88 88"><circle cx="44" cy="44" r="40"/><circle class="arc" cx="44" cy="44" r="40" pathLength="100"/></svg>';

  // Original, brand-neutral app icons: [glyph, gradient top, gradient bottom, optional glyph colour].
  const APP = {
    chat: ['i-chat', '#8f96ff', '#4a51d2'],
    recorder: ['i-record', '#ff6b60', '#c9231b'],
    player: ['i-play', '#46e582', '#139c48'],
    games: ['i-gamepad', '#62d3ff', '#1f6fd6'],
    live: ['i-radio', '#c58bff', '#7a3fe0'],
    video: ['i-video', '#ff6f8e', '#d11f48'],
    home: ['i-home', '#4fe0cc', '#168f82'],
    lights: ['i-bulb', '#ffd84d', '#f29a00'],
    terminal: ['i-terminal', '#33353c', '#17181c', '#5ee38a'],
    code: ['i-code', '#2c3340', '#15181f', '#3aa0ff'],
    files: ['i-folder', '#62bdff', '#2272d6'],
    music: ['i-music', '#ff6f8f', '#e0224f'],
    notes: ['i-pen', '#ffd34f', '#f0a000'],
    clock: ['i-clock', '#ffab33', '#e86a00'],
    photos: ['i-image', '#ff9566', '#e03f5a'],
    settings: ['i-sliders', '#b9b9c0', '#6c6c74'],
    browser: ['i-compass', '#5fcbff', '#1a6fe6'],
    design: ['i-pen', '#cf90ff', '#8639e0'],
  };
  const appIc = (k, extra = '') => {
    const [icon, g1, g2, ink] = APP[k];
    return `<span class="appic${extra}" style="--g1:${g1};--g2:${g2};${ink ? `--ink:${ink};` : ''}">${use(icon)}</span>`;
  };

  const GAMES = { id: 'games', app: 'games', c: '#62d3ff' };
  const SLOT = { id: 'slot', kind: 'empty' };
  // A tile is either an app icon (app) or a thin glyph (icon). Colour only shows in the glyph and as the glow when on.
  const PAGES = [
    { name: 'Stream', tiles: [
      { id: 'rec', icon: 'i-record', c: '#ff453a', toggle: true },
      { id: 'scene', icon: 'i-video', c: '#ff9f0a' },
      { id: 'mic', icon: 'i-mic', alt: 'i-mic-off', c: '#ff453a', toggle: true },
      { id: 'chat', app: 'chat', c: '#6f78ff', toggle: true },
      { id: 'cpu', kind: 'gauge', cap: 'CPU', c: '#30d158', v: 37 },
      { id: 'gpu', kind: 'gauge', cap: 'GPU', c: '#ff9f0a', v: 68 },
      { id: 'now', kind: 'now' },
      { id: 'timer', kind: 'timer', cap: 'Break', c: '#ffd60a' },
    ] },
    { name: 'Work', tiles: [
      { id: 'code', app: 'code', c: '#3aa0ff' },
      { id: 'web', app: 'browser', c: '#5fcbff' },
      { id: 'term', app: 'terminal', c: '#5ee38a' },
      { id: 'design', app: 'design', c: '#bf5af2' },
      { id: 'focus', icon: 'i-moon', c: '#8e8cff', toggle: true },
      { id: 'snip', icon: 'i-shot', c: '#ff9f0a' },
      { id: 'lock', icon: 'i-lock', c: '#98989d' },
      SLOT,
    ] },
    { name: 'Home', tiles: [
      { id: 'lamp', icon: 'i-bulb', c: '#ffd60a', toggle: true },
      { id: 'hue', icon: 'i-sun', c: '#ffb340', toggle: true },
      { id: 'movie', icon: 'i-film', c: '#bf5af2' },
      { id: 'away', app: 'home', c: '#4fe0cc' },
      { id: 'prev', icon: 'i-prev', c: '#f5f5f7' },
      { id: 'play', icon: 'i-play', alt: 'i-pause', c: '#30d158', toggle: true },
      { id: 'next', icon: 'i-next', c: '#f5f5f7' },
      { id: 'vol', kind: 'volume', c: '#2997ff' },
    ] },
  ];
  const LIB = [
    ['Chat', 'chat'], ['Recorder', 'recorder'], ['Player', 'player'], ['Games', 'games'], ['Live', 'live'], ['Video', 'video'],
    ['Home', 'home'], ['Lights', 'lights'], ['Terminal', 'terminal'], ['Code', 'code'], ['Files', 'files'], ['Music', 'music'],
    ['Notes', 'notes'], ['Clock', 'clock'], ['Photos', 'photos'], ['Settings', 'settings'], ['Browser', 'browser'], ['Design', 'design'],
  ];

  const tileHTML = (t, extra = '') => {
    const style = `--c:${t.c || '#f5f5f7'};`;
    const cls = `tile${t.app ? ' app' : ' sys'}${extra}`;
    switch (t.kind) {
      case 'empty':
        return `<div class="tile empty${extra}" data-t="${t.id}"><span class="ic">${use('i-plus')}</span></div>`;
      case 'gauge':
        return `<div class="tile gauge${extra}" data-t="${t.id}" style="${style}">${ring}<span class="val">${t.v}%</span><span class="cap">${t.cap}</span></div>`;
      case 'timer':
        return `<div class="tile timer${extra}" data-t="${t.id}" style="${style}">${ring}<span class="val">05:00</span><span class="cap">${t.cap}</span></div>`;
      case 'now':
        return `<div class="tile app now${extra}" data-t="${t.id}">${appIc('music', ' art')}</div>`;
      case 'volume':
        return `<div class="${cls}" data-t="${t.id}" style="${style}"><span class="ic">${use('i-volume')}</span><span class="bar" style="--v:64%"><i></i></span></div>`;
      default: {
        if (t.app) return `<div class="${cls}" data-t="${t.id}" style="${style}">${appIc(t.app)}</div>`;
        const ic = t.alt
          ? `<span class="ic def">${use(t.icon)}</span><span class="ic alt">${use(t.alt)}</span>`
          : `<span class="ic">${use(t.icon)}</span>`;
        return `<div class="${cls}" data-t="${t.id}" style="${style}">${ic}</div>`;
      }
    }
  };

  const decks = $$('[data-deck]');
  for (const deck of decks) {
    deck.innerHTML = `<div class="deck-view"><div class="deck-track">${
      PAGES.map((p) => `<div class="deck-page">${p.tiles.map((t) => tileHTML(t)).join('')}</div>`).join('')
    }</div><div class="dots">${PAGES.map(() => '<i></i>').join('')}</div></div>`;
  }
  const lib = $('#cc-lib');
  if (lib) {
    lib.innerHTML = LIB.map(([n, k]) =>
      `<div class="lib-item" data-lib="${n}"><span class="lib-ic">${appIc(k)}</span>${n}</div>`).join('');
  }
  // Thumbnails: a dark mini tile with a dot in the tile's icon or glyph colour.
  const thumbHTML = (t) => {
    if (t.kind === 'empty') return '<i style="--tb:transparent;--c:transparent"></i>';
    const c = t.app ? APP[t.app][1] : t.kind ? '#e8e8ed' : '#f2f2f7';
    return `<i style="--c:${c}"></i>`;
  };
  const drawThumb = (i) => {
    const el = $(`[data-thumb="${i}"]`);
    if (el) el.innerHTML = PAGES[i].tiles.map(thumbHTML).join('');
  };
  PAGES.forEach((_, i) => drawThumb(i));

  const tiles = (id) => $$(`[data-t="${id}"]`);
  const setOn = (id, on) => tiles(id).forEach((el) => el.classList.toggle('on', on));
  const isOn = (id) => tiles(id)[0]?.classList.contains('on');

  let page = -1;
  const setPage = (i) => {
    page = i;
    $$('.deck-track').forEach((tr) => { tr.style.transform = `translateX(${-600 * i}px)`; });
    $$('.dots').forEach((d) => [...d.children].forEach((dot, k) => dot.classList.toggle('on', k === i)));
    $$('#cc-pages li[data-page]').forEach((li) => li.classList.toggle('on', +li.dataset.page === i));
    const title = $('#cc-title');
    if (title) title.textContent = PAGES[i].name;
  };

  const setGauge = (id, v) => tiles(id).forEach((el) => {
    el.querySelector('.arc').style.strokeDashoffset = 100 - v;
    el.querySelector('.val').textContent = `${Math.round(v)}%`;
  });
  let timerLeft = 300;
  const drawTimer = () => tiles('timer').forEach((el) => {
    const m = String(Math.floor(timerLeft / 60)).padStart(2, '0');
    const s = String(timerLeft % 60).padStart(2, '0');
    el.querySelector('.val').textContent = `${m}:${s}`;
    el.querySelector('.arc').style.strokeDashoffset = 100 - (timerLeft / 300) * 100;
  });
  const setVolume = (v) => tiles('vol').forEach((el) => el.querySelector('.bar').style.setProperty('--v', `${v}%`));

  const setSlot = (filled) => {
    const t = filled ? GAMES : SLOT;
    const i = PAGES[1].tiles.findIndex((x) => x.id === 'slot' || x.id === 'games');
    PAGES[1].tiles[i] = t;
    $$('[data-t="slot"], [data-t="games"]').forEach((el) => { el.outerHTML = tileHTML(t, filled ? ' pop' : ''); });
    drawThumb(1);
    const count = $('[data-count]');
    if (count) count.textContent = filled ? '8' : '7';
  };

  // Stage scaling: the render is laid out at a fixed design size and scaled to fit.
  const wrap = $('#stage-wrap');
  const stage = $('#stage');
  let scale = 1;
  const fit = () => {
    const dw = parseFloat(getComputedStyle(wrap).getPropertyValue('--dw')) || 1280;
    scale = wrap.clientWidth / dw;
    stage.style.setProperty('--s', scale);
  };
  fit();
  new ResizeObserver(fit).observe(wrap);
  requestAnimationFrame(() => stage.classList.add('ready'));
  watch(wrap);

  setPage(0);
  setGauge('cpu', 37);
  setGauge('gpu', 68);
  drawTimer();

  // A wait that only counts down while the hero is on screen, so the demo pauses off-screen.
  const wait = (ms) => new Promise((res) => {
    let left = ms;
    const step = () => {
      if (onScreen(wrap)) left -= 100;
      if (left <= 0) res(); else setTimeout(step, 100);
    };
    setTimeout(step, 100);
  });
  const press = async (id, toggleTo) => {
    const els = tiles(id);
    els.forEach((el) => el.classList.add('press'));
    await wait(200);
    els.forEach((el) => el.classList.remove('press'));
    if (toggleTo !== undefined) setOn(id, toggleTo);
  };

  const laptopVisible = () => getComputedStyle($('.laptop')).display !== 'none';
  const cursor = $('#cursor');
  const ghost = $('#ghost');
  const cc = $('#cc');
  const moveCursor = (x, y, ms) => {
    cursor.style.transition = ms ? `transform ${ms}ms cubic-bezier(.45,0,.2,1), opacity .3s` : 'opacity .3s';
    cursor.style.transform = `translate(${x}px, ${y}px)`;
  };
  const centerIn = (el) => {
    const a = cc.getBoundingClientRect();
    const b = el.getBoundingClientRect();
    return { x: (b.left + b.width / 2 - a.left) / scale, y: (b.top + b.height / 2 - a.top) / scale };
  };

  const dragGames = async () => {
    if (!laptopVisible()) { setSlot(true); return; }
    const src = $('[data-lib="Games"]');
    const srcIc = src.querySelector('.lib-ic');
    const dst = $('[data-deck="mirror"] [data-t="slot"]');
    const p0 = centerIn(srcIc);
    ghost.innerHTML = srcIc.outerHTML;
    moveCursor(p0.x + 150, p0.y + 40, 0);
    cursor.classList.add('show');
    await wait(150);
    moveCursor(p0.x, p0.y, 800);
    await wait(900);
    cursor.classList.add('drag');
    src.classList.add('lifted');
    tiles('slot').forEach((el) => el.classList.add('target'));
    const p1 = centerIn(dst);
    moveCursor(p1.x, p1.y, 1100);
    await wait(1200);
    cursor.classList.remove('drag');
    src.classList.remove('lifted');
    setSlot(true);
    await wait(500);
    cursor.classList.remove('show');
  };

  const runDeck = async () => {
    for (;;) {
      setPage(0);
      await wait(1300);
      await press('rec', true);
      await wait(1100);
      await press('scene');
      await wait(900);
      await press('mic', true);
      await wait(1300);
      await press('chat', true);
      await wait(1100);
      await press('mic', false);
      await wait(900);
      await press('chat', false);
      await wait(1100);

      setPage(1);
      await wait(1300);
      await press('code');
      await wait(700);
      await dragGames();
      await wait(900);
      await press('focus', true);
      await wait(1100);
      await press('games');
      await wait(1300);

      setPage(2);
      await wait(1300);
      await press('lamp', true);
      await wait(700);
      await press('hue', true);
      await wait(1000);
      await press('play', true);
      await wait(800);
      await press('vol'); setVolume(82);
      await wait(1500);
      await press('lamp', false);
      await wait(600);
      await press('hue', false);
      await wait(1200);

      // Quiet reset while the Stream page is out of view.
      setOn('rec', false); setOn('focus', false); setOn('play', false); setVolume(64);
      setSlot(false);
    }
  };

  // Live readings tick regardless of the sequence.
  const liveTick = () => {
    if (!onScreen(wrap)) return;
    setGauge('cpu', 22 + Math.random() * 40);
    setGauge('gpu', 45 + Math.random() * 45);
    timerLeft = timerLeft <= 0 ? 300 : timerLeft - 1;
    drawTimer();
  };

  if (motion) {
    setInterval(liveTick, 1000);
    runDeck();
  } else {
    setOn('rec', true);
  }

  /* ---------------- Bento micro-demos ---------------- */
  if (motion) {
    const live = watch($('.c-live'));
    const miniGauges = $$('.mini-deck [data-gauge]');
    setInterval(() => {
      if (!onScreen(live)) return;
      miniGauges.forEach((g, i) => {
        const v = i ? 45 + Math.random() * 45 : 20 + Math.random() * 45;
        g.querySelector('.arc').style.strokeDashoffset = 100 - v;
        g.querySelector('b').textContent = `${Math.round(v)}%`;
      });
    }, 1300);

    const tog = watch($('.c-toggle'));
    const flip = $('.flip');
    const fill = $('.track .fill');
    setInterval(() => {
      if (!onScreen(tog)) return;
      flip.classList.toggle('on');
      fill.style.width = `${25 + Math.random() * 70}%`;
    }, 1800);

    const multi = watch($('.c-multi'));
    const links = $$('.chain li');
    let li = 0;
    setInterval(() => {
      if (!onScreen(multi)) return;
      links.forEach((l, k) => l.classList.toggle('lit', k === li % (links.length + 2)));
      li++;
    }, 650);

    const pal = watch($('.c-palette'));
    const typed = $('.typed');
    const full = typed.dataset.typed;
    let n = 0; let dir = 1; let hold = 0;
    setInterval(() => {
      if (!onScreen(pal)) return;
      if (hold > 0) { hold--; return; }
      n += dir;
      if (n >= full.length) { n = full.length; dir = -1; hold = 22; }
      if (n <= 0) { n = 0; dir = 1; hold = 5; }
      typed.textContent = full.slice(0, n);
    }, 110);

    const tapCard = watch($('.tap-vis'));
    const tap = $('.mtile.tap');
    const ripple = $('.ripple');
    setInterval(async () => {
      if (!onScreen(tapCard)) return;
      tap.classList.add('press');
      ripple.classList.remove('go'); void ripple.offsetWidth; ripple.classList.add('go');
      setTimeout(() => { tap.classList.remove('press'); tap.classList.toggle('on'); }, 180);
    }, 2000);
  } else {
    $('.typed').textContent = $('.typed').dataset.typed;
  }

  /* ---------------- Decorative QR ---------------- */
  const qr = $('#qr');
  if (qr) {
    const N = 25; let seed = 7; let d = '';
    const rnd = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);
    const finder = (x, y) => {
      d += `M${x} ${y}h7v7h-7zM${x + 1} ${y + 1}v5h5v-5zM${x + 2} ${y + 2}h3v3h-3z`;
    };
    const inFinder = (x, y) => (x < 8 && y < 8) || (x > N - 9 && y < 8) || (x < 8 && y > N - 9);
    for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) {
      if (!inFinder(x, y) && rnd() > 0.52) d += `M${x + 2} ${y + 2}h1v1h-1z`;
    }
    finder(2, 2); finder(N - 5, 2); finder(2, N - 5);
    qr.innerHTML = `<path fill="currentColor" fill-rule="evenodd" d="${d}"/>`;
  }

  /* ---------------- Download detection ---------------- */
  const detectOS = () => {
    const ua = navigator.userAgent;
    const plat = navigator.userAgentData?.platform || navigator.platform || '';
    if (/android/i.test(ua)) return 'android';
    if (/iPhone|iPad|iPod/.test(ua) || (/Mac/.test(plat) && navigator.maxTouchPoints > 1)) return 'ios';
    if (/Win/i.test(plat) || /Windows/.test(ua)) return 'windows';
    if (/Mac/i.test(plat) || /Mac OS X/.test(ua)) return 'mac';
    if (/Linux|X11|CrOS/i.test(plat + ua)) return 'linux';
    return null;
  };
  const OS = {
    windows: { label: 'Download for Windows', note: 'Windows 10 1809 or later · 64-bit' },
    mac: { label: 'Download for macOS', note: 'Apple Silicon and Intel' },
    linux: { label: 'Download for Linux', note: 'x64 and arm64 · runs as a user service' },
    android: { label: 'Download for Android', note: 'Android 7.0 or later · then install on your computer' },
    ios: { label: 'Set up on iPhone', note: 'Opens in Safari · install on your computer first', href: DOCS },
  };
  const os = detectOS();
  const heroBtn = $('#hero-download');
  if (os && OS[os]) {
    $('[data-download-label]').textContent = OS[os].label;
    if (OS[os].href) heroBtn.href = OS[os].href;
    const note = $('#hero-note');
    note.innerHTML = `${OS[os].note} · <a href="#download">Other platforms</a>`;
    const card = $(`.dl[data-os="${os}"]`);
    if (card) {
      card.classList.add('detected');
      card.insertAdjacentHTML('beforeend', '<small class="badge">This device</small>');
    }
  }

  // Point buttons straight at the release files when the GitHub API answers; otherwise they keep
  // linking to the latest release page.
  const ASSETS = {
    windows: [/setup\.exe$/i, /win-x64\.zip$/i],
    mac: [/arm64.*\.app\.zip$/i, /\.app\.zip$/i, /osx-arm64\.tar\.gz$/i],
    linux: [/linux-x64\.tar\.gz$/i],
    android: [/\.apk$/i],
  };
  const resolveAssets = () => fetch(`https://api.github.com/repos/${REPO}/releases/latest`, { headers: { Accept: 'application/vnd.github+json' } })
    .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
    .then((rel) => {
      const files = rel.assets || [];
      for (const [key, patterns] of Object.entries(ASSETS)) {
        const hit = patterns.map((p) => files.find((f) => p.test(f.name))).find(Boolean);
        if (!hit) continue;
        $$(`.dl[data-os="${key}"]`).forEach((a) => { a.href = hit.browser_download_url; });
        if (key === os) heroBtn.href = hit.browser_download_url;
      }
    })
    .catch(() => { heroBtn.href = OS[os]?.href || RELEASES; });
  (window.requestIdleCallback || ((f) => setTimeout(f, 1500)))(resolveAssets);
})();
