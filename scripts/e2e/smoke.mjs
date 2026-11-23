#!/usr/bin/env node
// Smoke test de ponta a ponta contra um servidor DeckOS de verdade (sem dependencias: Node 22+).
//
//   node scripts/e2e/smoke.mjs [--base http://localhost:4787] [--log caminho\server.out.log]
//                              [--no-media] [--no-desktop] [--no-browser]
//
// Rode no proprio PC do servidor: a chave vem de /api/pairing/local-key (so loopback) e as
// acoes privilegiadas so rodam de la. Crie os perfis num DECKOS_DATA_DIR separado: o script
// cria e apaga perfis "e2e-*", mexe no volume (e devolve) e pausa/retoma a midia que estiver
// tocando (--no-media pula). --no-desktop pula o que precisa de janela/teclado (atalho, tecla,
// abrir programa). --no-browser pula abrir uma URL no navegador padrao.
// Nunca chama bloquear/suspender/desligar tela, nem troca o dispositivo de audio padrao.

import dgram from 'node:dgram';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const args = process.argv.slice(2);
const opt = (name, def) => {
  const i = args.indexOf(name);
  return i >= 0 && args[i + 1] ? args[i + 1] : def;
};
const flag = (name) => args.includes(name);
const BASE = opt('--base', 'http://localhost:4787').replace(/\/$/, '');
const LOG = opt('--log', null);
const NO_MEDIA = flag('--no-media');
const NO_DESKTOP = flag('--no-desktop') || process.platform !== 'win32';
const NO_BROWSER = flag('--no-browser');
const HERE = path.dirname(fileURLToPath(import.meta.url));
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'deckos-e2e-'));

const results = [];
// Erros que o proprio teste provoca (entrada invalida de proposito): nao contam no log.
const expectedLogErrors = [];
let KEY = '';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const logStart = LOG && fs.existsSync(LOG) ? fs.statSync(LOG).size : 0;

function record(section, name, status, detail = '') {
  results.push({ section, name, status, detail });
  const mark = { PASS: '\x1b[32mPASS\x1b[0m', FAIL: '\x1b[31mFAIL\x1b[0m', SKIP: '\x1b[33mSKIP\x1b[0m' }[status];
  console.log(`${mark} [${section}] ${name}${detail ? ' — ' + detail : ''}`);
}

async function check(section, name, fn) {
  try {
    const r = await fn();
    if (r && r.skip) record(section, name, 'SKIP', r.skip);
    else record(section, name, 'PASS', typeof r === 'string' ? r : '');
  } catch (e) {
    record(section, name, 'FAIL', e?.message ?? String(e));
  }
}

function assert(cond, msg) {
  if (!cond) throw new Error(msg);
}

async function api(method, url, { body, headers = {}, key = KEY, raw = false, base = BASE } = {}) {
  const h = { ...headers };
  if (key) h['X-API-KEY'] = key;
  let payload = body;
  if (body !== undefined && !(body instanceof Uint8Array) && typeof body !== 'string') {
    h['Content-Type'] = 'application/json';
    payload = JSON.stringify(body);
  }
  const res = await fetch(base + url, { method, headers: h, body: payload });
  const buf = new Uint8Array(await res.arrayBuffer());
  let json = null;
  if (!raw) {
    try { json = JSON.parse(new TextDecoder().decode(buf)); } catch { }
  }
  return { status: res.status, json, buf, headers: res.headers };
}

async function ok(method, url, opts) {
  const r = await api(method, url, opts);
  assert(r.status >= 200 && r.status < 300, `${method} ${url} -> ${r.status} ${new TextDecoder().decode(r.buf).slice(0, 200)}`);
  return r;
}

async function waitFor(fn, ms = 8000, step = 200) {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    try {
      last = await fn();
      if (last) return last;
    } catch { }
    await sleep(step);
  }
  return last;
}

function lanIp() {
  for (const list of Object.values(os.networkInterfaces())) {
    for (const a of list ?? []) {
      if (a.family === 'IPv4' && !a.internal && /^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/.test(a.address)) return a.address;
    }
  }
  return null;
}

// ---------- Servidor de eco (webhook HTTP, URL aberta no navegador, info "url") ----------
const echo = { hits: [] };
const echoServer = http.createServer((req, res) => {
  let body = '';
  req.on('data', (c) => (body += c));
  req.on('end', () => {
    echo.hits.push({ method: req.method, url: req.url, headers: req.headers, body });
    if (req.url.startsWith('/json')) {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ a: { b: 'e2e-url-value' } }));
    } else {
      res.writeHead(200, { 'Content-Type': 'text/html' });
      res.end('<title>DeckOS e2e</title>ok');
    }
  });
});
await new Promise((r) => echoServer.listen(0, '127.0.0.1', r));
const ECHO = `http://127.0.0.1:${echoServer.address().port}`;

// ---------- SignalR (protocolo JSON, sem cliente oficial) ----------
class Hub {
  constructor() { this.events = []; this.waiters = []; }
  async connect() {
    const neg = await ok('POST', '/deckHub/negotiate?negotiateVersion=1');
    const token = neg.json.connectionToken ?? neg.json.connectionId;
    const wsUrl = BASE.replace(/^http/, 'ws') + `/deckHub?id=${encodeURIComponent(token)}&access_token=${encodeURIComponent(KEY)}`;
    this.ws = new WebSocket(wsUrl);
    await new Promise((res, rej) => {
      this.ws.onopen = res;
      this.ws.onerror = () => rej(new Error('WebSocket do hub falhou'));
    });
    this.ws.onmessage = (ev) => {
      for (const part of String(ev.data).split('\x1e')) {
        if (!part) continue;
        let m;
        try { m = JSON.parse(part); } catch { continue; }
        if (m.type === 1) {
          const e = { target: m.target, args: m.arguments, at: Date.now() };
          this.events.push(e);
          this.waiters = this.waiters.filter((w) => (w.pred(e) ? (w.res(e), false) : true));
        } else if (m.type === 3 && this.pending?.[m.invocationId]) {
          this.pending[m.invocationId](m);
        }
      }
    };
    this.ws.send(JSON.stringify({ protocol: 'json', version: 1 }) + '\x1e');
    this.ping = setInterval(() => { try { this.ws.send('{"type":6}\x1e'); } catch { } }, 10000);
  }
  wait(target, pred = () => true, ms = 8000, since = 0) {
    const found = this.events.find((e) => e.at >= since && e.target === target && pred(e));
    if (found) return Promise.resolve(found);
    return new Promise((res, rej) => {
      const w = { pred: (e) => e.target === target && pred(e), res };
      this.waiters.push(w);
      setTimeout(() => {
        this.waiters = this.waiters.filter((x) => x !== w);
        rej(new Error(`sem ${target} em ${ms} ms`));
      }, ms);
    });
  }
  invoke(target, ...a) {
    this.pending ??= {};
    const id = String(Math.random()).slice(2, 10);
    return new Promise((res, rej) => {
      this.pending[id] = (m) => (m.error ? rej(new Error(m.error)) : res(m.result));
      this.ws.send(JSON.stringify({ type: 1, invocationId: id, target, arguments: a }) + '\x1e');
      setTimeout(() => rej(new Error(`${target}: sem resposta`)), 5000);
    });
  }
  close() { clearInterval(this.ping); try { this.ws.close(); } catch { } }
}

// ======================================================================================
const P_A = 'e2e-a', P_B = 'e2e-b';
const createdProfiles = new Set();
let hub;
let originalLayout;
let originalTriggers;
let targetPid = null;

console.log(`DeckOS smoke test -> ${BASE}  (echo ${ECHO}, tmp ${TMP})\n`);

// ---- Pareamento e autenticacao ----
await check('pairing', 'GET /api/ping (anonimo)', async () => {
  const r = await ok('GET', '/api/ping', { key: '' });
  assert(r.json.ok === true && r.json.name, 'resposta sem ok/name');
  return r.json.name;
});
await check('pairing', 'GET /api/pairing/local-key (loopback)', async () => {
  const r = await ok('GET', '/api/pairing/local-key', { key: '' });
  KEY = r.json.key;
  assert(KEY && KEY.length >= 20, 'chave curta');
});
if (!KEY) {
  console.error('Sem chave: nao da para seguir.');
  process.exit(1);
}
await check('pairing', 'local-key recusa Sec-Fetch-Site cross-site', async () => {
  const r = await api('GET', '/api/pairing/local-key', { key: '', headers: { 'Sec-Fetch-Site': 'cross-site' } });
  assert(r.status === 403, `status ${r.status}`);
});
await check('pairing', 'local-key recusa Origin publico', async () => {
  const r = await api('GET', '/api/pairing/local-key', { key: '', headers: { Origin: 'https://evil.example' } });
  assert(r.status === 403, `status ${r.status}`);
});
await check('pairing', 'API sem chave -> 401, chave errada -> 401', async () => {
  const a = await api('GET', '/api/streamdeck/profiles', { key: '' });
  const b = await api('GET', '/api/streamdeck/profiles', { key: 'errada' });
  assert(a.status === 401 && b.status === 401, `${a.status}/${b.status}`);
});
await check('pairing', 'Authorization: Bearer e ?access_token= aceitos', async () => {
  const a = await api('GET', '/api/system/info', { key: '', headers: { Authorization: 'Bearer ' + KEY } });
  const b = await api('GET', '/api/system/info?access_token=' + encodeURIComponent(KEY), { key: '' });
  assert(a.status === 200 && b.status === 200, `${a.status}/${b.status}`);
});
const LAN = lanIp();
const LAN_BASE = LAN ? `http://${LAN}:${new URL(BASE).port || 80}` : null;
await check('pairing', 'local-key pelo IP da LAN -> 403 (so loopback)', async () => {
  if (!LAN_BASE) return { skip: 'sem IP de LAN' };
  const r = await api('GET', '/api/pairing/local-key', { key: '', base: LAN_BASE });
  assert(r.status === 403, `status ${r.status}`);
});
await check('pairing', 'GET /api/system/info', async () => {
  const r = await ok('GET', '/api/system/info');
  assert(r.json.name && r.json.version, 'sem name/version');
  return `${r.json.name} v${r.json.version}`;
});

// ---- SignalR ----
await check('signalr', 'conecta em /deckHub (negotiate + WebSocket + handshake)', async () => {
  hub = new Hub();
  await hub.connect();
  await hub.wait('ReceiveLayoutUpdate', () => true, 5000);
  return 'recebeu ReceiveLayoutUpdate ao conectar';
});
await check('signalr', 'SetLanguage', async () => {
  if (!hub) return { skip: 'sem hub' };
  await hub.invoke('SetLanguage', 'en');
});

// ---- Plataforma e apps ----
let apps = [];
await check('platform', 'GET /api/platform', async () => {
  const r = await ok('GET', '/api/platform');
  assert(r.json.os && Array.isArray(r.json.capabilities), 'sem os/capabilities');
  return `${r.json.os} ${r.json.arch}, ${r.json.capabilities.length} capacidades, faltam: ${(r.json.missing ?? []).join(',') || 'nada'}`;
});
await check('platform', 'GET /api/apps', async () => {
  const r = await ok('GET', '/api/apps');
  apps = r.json;
  assert(Array.isArray(apps) && apps.length > 0, 'lista vazia');
  assert(apps.every((a) => a.id && a.name && a.iconUrl), 'item sem id/name/iconUrl');
  return `${apps.length} apps`;
});
await check('platform', 'icone do app: X-API-KEY, ?access_token= e sem chave', async () => {
  if (!apps.length) return { skip: 'sem apps' };
  // Pega o primeiro que tem icone (atalho sem icone devolve 404, que e valido).
  let found = null;
  for (const a of apps.slice(0, 40)) {
    const r = await api('GET', a.iconUrl, { raw: true });
    if (r.status === 200) { found = { a, r }; break; }
    assert(r.status === 404, `${a.name}: status ${r.status}`);
  }
  assert(found, 'nenhum dos 40 primeiros tem icone');
  const ct = found.r.headers.get('content-type');
  assert(/image\//.test(ct) && found.r.buf.length > 100, `content-type ${ct}, ${found.r.buf.length} bytes`);
  const viaToken = await api('GET', `${found.a.iconUrl}?access_token=${encodeURIComponent(KEY)}`, { key: '', raw: true });
  assert(viaToken.status === 200, `access_token -> ${viaToken.status}`);
  const anon = await api('GET', found.a.iconUrl, { key: '', raw: true });
  assert(anon.status === 401, `sem chave -> ${anon.status}`);
  return `${found.a.name}: ${ct}, ${found.r.buf.length} bytes`;
});
await check('platform', 'GET /api/apps/{id}/icon inexistente -> 404', async () => {
  const r = await api('GET', '/api/apps/naoexiste123/icon', { raw: true });
  assert(r.status === 404, `status ${r.status}`);
});
await check('platform', 'GET /api/system/apps (apps abertos)', async () => {
  const r = await ok('GET', '/api/system/apps');
  assert(Array.isArray(r.json), 'nao e lista');
  return `${r.json.length} abertos`;
});

// ---- Grade ----
await check('layout', 'GET/POST /api/streamdeck/layout (+ ReceiveLayoutUpdate) e restaura', async () => {
  originalLayout = (await ok('GET', '/api/streamdeck/layout')).json;
  const since = Date.now();
  const saved = (await ok('POST', '/api/streamdeck/layout', { body: { rows: 4, columns: 6 } })).json;
  assert(saved.rows === 4 && saved.columns === 6, JSON.stringify(saved));
  if (hub) await hub.wait('ReceiveLayoutUpdate', (e) => e.args[0].rows === 4 && e.args[0].columns === 6, 4000, since);
  const bad = await api('POST', '/api/streamdeck/layout', { body: { rows: 0, columns: 3 } });
  assert(bad.status === 400, `rows=0 -> ${bad.status}`);
  await ok('POST', '/api/streamdeck/layout', { body: originalLayout });
});

// ---- Perfis CRUD ----
const btn = (id, row, column, extra = {}) => ({ id, row, column, label: id, ...extra });
const profileA = {
  id: P_A, name: 'E2E A', rows: 3, columns: 4,
  buttons: [
    btn('e2e-copy', 0, 0, { iconName: 'star', backgroundColor: '#FF3366', action: { type: 'media', parameters: { command: 'playpause' } } }),
    btn('e2e-counter', 0, 1, { action: { type: 'timer', parameters: { mode: 'counter', operation: 'increment', step: '1' } } }),
    btn('e2e-countdown', 0, 2, { action: { type: 'timer', parameters: { mode: 'countdown', durationMin: '1', operation: 'toggle' } } }),
    btn('e2e-toggle', 0, 3, { toggle: true, action: { type: 'none', parameters: {} }, activeAction: { type: 'none', parameters: {} }, activeLabel: 'ON' }),
    btn('e2e-info-cmd', 1, 0, { dynamicType: 'command', dynamicParameters: { command: 'echo e2e-info-ok', interval: '5' } }),
    btn('e2e-info-url', 1, 1, { dynamicType: 'url', dynamicParameters: { url: `${ECHO}/json`, path: 'a.b', interval: '5' } }),
    btn('e2e-clock', 1, 2, { dynamicType: 'clock', dynamicParameters: { format: 'HH:mm' } }),
    btn('e2e-http', 1, 3, { action: { type: 'http', parameters: { method: 'POST', url: `${ECHO}/press`, body: '{"via":"press"}', contentType: 'application/json' } } }),
    btn('e2e-gestures', 2, 0, {
      action: { type: 'http', parameters: { method: 'GET', url: `${ECHO}/gesture-tap` } },
      longPressAction: { type: 'http', parameters: { method: 'GET', url: `${ECHO}/gesture-long` } },
      doubleTapAction: { type: 'http', parameters: { method: 'GET', url: `${ECHO}/gesture-double` } },
    }),
  ],
};
await check('profiles', 'POST /api/streamdeck/profiles (cria A e B) + ReceiveDeckUpdate', async () => {
  const since = Date.now();
  await ok('POST', '/api/streamdeck/profiles', { body: profileA });
  createdProfiles.add(P_A);
  await ok('POST', '/api/streamdeck/profiles', { body: { id: P_B, name: 'E2E B', rows: 3, columns: 4, buttons: [] } });
  createdProfiles.add(P_B);
  if (hub) await hub.wait('ReceiveDeckUpdate', (e) => e.args[0]?.profileId === P_A, 4000, since);
});
await check('profiles', 'GET lista e GET por id', async () => {
  const list = (await ok('GET', '/api/streamdeck/profiles')).json;
  assert(list.some((p) => p.id === P_A) && list.some((p) => p.id === P_B), 'perfis nao aparecem');
  const a = (await ok('GET', `/api/streamdeck/profiles/${P_A}`)).json;
  assert(a.buttons.length === profileA.buttons.length, `botoes: ${a.buttons.length}`);
  const g = a.buttons.find((b) => b.id === 'e2e-gestures');
  assert(g.longPressAction && g.doubleTapAction, 'gestos nao salvos');
  const nf = await api('GET', '/api/streamdeck/profiles/naoexiste');
  assert(nf.status === 404, `inexistente -> ${nf.status}`);
  return `${list.length} perfis`;
});
await check('profiles', 'atualiza (renomeia) o perfil', async () => {
  await ok('POST', '/api/streamdeck/profiles', { body: { ...profileA, name: 'E2E A renomeado' } });
  const a = (await ok('GET', `/api/streamdeck/profiles/${P_A}`)).json;
  assert(a.name === 'E2E A renomeado', a.name);
});
await check('profiles', 'pelo IP da LAN: botao privilegiado novo -> 403 (ActionPolicy)', async () => {
  if (!LAN_BASE) return { skip: 'sem IP de LAN' };
  const evil = { id: 'e2e-remote', name: 'remote', rows: 3, columns: 4, buttons: [btn('x', 0, 0, { action: { type: 'launch_app', parameters: { path: 'calc.exe' } } })] };
  const r = await api('POST', '/api/streamdeck/profiles', { body: evil, base: LAN_BASE });
  assert(r.status === 403, `status ${r.status}`);
  const ex = await api('POST', '/api/streamdeck/execute', { body: { type: 'script', parameters: { code: 'exit 0' } }, base: LAN_BASE });
  assert(ex.status === 403, `execute -> ${ex.status}`);
  const key = await api('POST', '/api/streamdeck/key', { body: { key: 'A' }, base: LAN_BASE });
  assert(key.status === 403, `key -> ${key.status}`);
});

// ---- Botoes: copiar / mover ----
await check('buttons', 'copia para outro perfil, recusa casa ocupada, move', async () => {
  await ok('POST', '/api/streamdeck/buttons/copy', { body: { fromProfileId: P_A, buttonId: 'e2e-copy', toProfileId: P_B, row: 0, column: 1, move: false } });
  let b = (await ok('GET', `/api/streamdeck/profiles/${P_B}`)).json;
  const copy = b.buttons.find((x) => x.row === 0 && x.column === 1);
  assert(copy && copy.id !== 'e2e-copy' && copy.label === 'e2e-copy' && copy.backgroundColor === '#FF3366', 'copia errada');
  const occ = await api('POST', '/api/streamdeck/buttons/copy', { body: { fromProfileId: P_A, buttonId: 'e2e-copy', toProfileId: P_B, row: 0, column: 1 } });
  assert(occ.status === 409, `ocupada -> ${occ.status}`);
  const nf = await api('POST', '/api/streamdeck/buttons/copy', { body: { fromProfileId: P_A, buttonId: 'naoexiste', toProfileId: P_B, row: 2, column: 2 } });
  assert(nf.status === 404, `inexistente -> ${nf.status}`);
  await ok('POST', '/api/streamdeck/buttons/copy', { body: { fromProfileId: P_A, buttonId: 'e2e-copy', toProfileId: P_B, row: 2, column: 3, move: true } });
  const a = (await ok('GET', `/api/streamdeck/profiles/${P_A}`)).json;
  b = (await ok('GET', `/api/streamdeck/profiles/${P_B}`)).json;
  assert(!a.buttons.some((x) => x.id === 'e2e-copy'), 'mover nao tirou da origem');
  assert(b.buttons.some((x) => x.row === 2 && x.column === 3), 'mover nao colocou no destino');
  return `B tem ${b.buttons.length} botoes`;
});
await check('buttons', 'duplica no mesmo perfil', async () => {
  await ok('POST', '/api/streamdeck/buttons/copy', { body: { fromProfileId: P_A, buttonId: 'e2e-http', toProfileId: P_A, row: 2, column: 3 } });
  const a = (await ok('GET', `/api/streamdeck/profiles/${P_A}`)).json;
  assert(a.buttons.filter((x) => x.label === 'e2e-http').length === 2, 'nao duplicou');
});

// ---- Catalogo de acoes ----
let schema = [];
await check('actions', 'GET /api/actions/schema', async () => {
  schema = (await ok('GET', '/api/actions/schema')).json;
  assert(schema.length > 20, `so ${schema.length} tipos`);
  for (const t of ['key', 'hotkey', 'launch_app', 'media', 'mixer', 'multi', 'http', 'script', 'timer', 'windows', 'network'])
    assert(schema.some((s) => s.type === t), `falta ${t}`);
  assert(schema.find((s) => s.type === 'script').privileged === true, 'script deveria ser privilegiado');
  return `${schema.length} tipos`;
});
await check('actions', 'schema traduzido (Accept-Language pt/en/es)', async () => {
  const pt = (await ok('GET', '/api/actions/schema', { headers: { 'Accept-Language': 'pt-BR' } })).json;
  const en = (await ok('GET', '/api/actions/schema', { headers: { 'Accept-Language': 'en' } })).json;
  const es = (await ok('GET', '/api/actions/schema', { headers: { 'Accept-Language': 'es' } })).json;
  const t = (l) => l.find((s) => s.type === 'mixer').title;
  assert(t(pt) !== t(en), `pt e en iguais: ${t(pt)}`);
  return `${t(pt)} / ${t(en)} / ${t(es)}`;
});
await check('actions', 'GET /api/actions/state/timer e /timer/targets', async () => {
  await ok('GET', '/api/actions/state/timer');
  const t = (await ok('GET', '/api/actions/timer/targets')).json;
  assert(t.some((x) => x.value === 'e2e-countdown'), 'botao-timer salvo nao aparece nos alvos');
  const nf = await api('GET', '/api/actions/state/naoexiste');
  assert(nf.status === 404, `inexistente -> ${nf.status}`);
});
await check('actions', 'GET /api/actions/windows/audio-devices (so lista; nao troca o padrao)', async () => {
  const out = (await ok('GET', '/api/actions/windows/audio-devices?kind=output')).json;
  const inp = (await ok('GET', '/api/actions/windows/audio-devices?kind=input')).json;
  return `${out.length} saidas, ${inp.length} entradas`;
});
await check('actions', 'tipo desconhecido em /execute nao derruba (200)', async () => {
  await ok('POST', '/api/streamdeck/execute', { body: { type: 'naoexiste', parameters: {} } });
});

// ---- Acoes: HTTP, multi, rede, script ----
await check('exec', 'http (webhook POST para eco local, headers e corpo)', async () => {
  echo.hits.length = 0;
  await ok('POST', '/api/streamdeck/execute', { body: { type: 'http', parameters: { method: 'POST', url: `${ECHO}/hook`, headers: 'X-E2E: 1', body: '{"hello":"deck"}', contentType: 'application/json' } } });
  const hit = await waitFor(() => echo.hits.find((h) => h.url === '/hook'), 5000);
  assert(hit, 'eco nao recebeu');
  assert(hit.body === '{"hello":"deck"}', `corpo ${hit.body}`);
  assert(hit.headers['x-e2e'] === '1', 'header X-E2E nao chegou');
  assert(/application\/json/.test(hit.headers['content-type'] ?? ''), `content-type ${hit.headers['content-type']}`);
});
await check('exec', 'press de botao salvo (http) e gestos longPress/doubleTap', async () => {
  echo.hits.length = 0;
  await ok('POST', '/api/streamdeck/press', { body: { profileId: P_A, buttonId: 'e2e-http' } });
  await ok('POST', '/api/streamdeck/press', { body: { profileId: P_A, buttonId: 'e2e-gestures', gesture: 'longPress' } });
  await ok('POST', '/api/streamdeck/press', { body: { profileId: P_A, buttonId: 'e2e-gestures', gesture: 'doubleTap' } });
  await ok('POST', '/api/streamdeck/press', { body: { profileId: P_A, buttonId: 'e2e-gestures' } });
  const all = await waitFor(() => ['/press', '/gesture-long', '/gesture-double', '/gesture-tap'].every((u) => echo.hits.some((h) => h.url === u)), 5000);
  assert(all, 'chegou: ' + echo.hits.map((h) => h.url).join(','));
  const nf = await api('POST', '/api/streamdeck/press', { body: { profileId: P_A, buttonId: 'naoexiste' } });
  assert(nf.status === 404, `inexistente -> ${nf.status}`);
  const bad = await api('POST', '/api/streamdeck/press', { body: {} });
  assert(bad.status === 400, `vazio -> ${bad.status}`);
});
await check('exec', 'multi (2 passos http com espera, ordem)', async () => {
  echo.hits.length = 0;
  const steps = [
    { type: 'http', parameters: { method: 'GET', url: `${ECHO}/multi-1` } },
    { type: 'http', parameters: { method: 'GET', url: `${ECHO}/multi-2` }, delayMs: 300 },
  ];
  const t0 = Date.now();
  await ok('POST', '/api/streamdeck/execute', { body: { type: 'multi', parameters: { steps: JSON.stringify(steps) } } });
  const done = await waitFor(() => echo.hits.filter((h) => h.url.startsWith('/multi')).length === 2, 5000);
  assert(done, 'chegou: ' + echo.hits.map((h) => h.url).join(','));
  assert(echo.hits[0].url === '/multi-1' && echo.hits[1].url === '/multi-2', 'ordem errada');
  return `${Date.now() - t0} ms`;
});
await check('exec', 'network (UDP para socket local)', async () => {
  const sock = dgram.createSocket('udp4');
  await new Promise((r) => sock.bind(0, '127.0.0.1', r));
  const got = new Promise((res) => sock.once('message', (m) => res(m.toString())));
  await ok('POST', '/api/streamdeck/execute', { body: { type: 'network', parameters: { protocol: 'udp', host: '127.0.0.1', port: String(sock.address().port), message: 'e2e-udp', encoding: 'text', ending: 'none' } } });
  const msg = await Promise.race([got, sleep(4000).then(() => null)]);
  sock.close();
  assert(msg === 'e2e-udp', `recebeu ${msg}`);
});
await check('exec', 'script (PowerShell inline grava um arquivo)', async () => {
  if (process.platform !== 'win32') return { skip: 'teste usa PowerShell' };
  const out = path.join(TMP, 'script-ok.txt');
  const code = `Set-Content -LiteralPath '${out.replace(/'/g, "''")}' -Value 'e2e-script-ok'`;
  await ok('POST', '/api/streamdeck/execute', { body: { type: 'script', parameters: { source: 'inline', language: 'powershell', code } } });
  const okFile = await waitFor(() => fs.existsSync(out) && fs.readFileSync(out, 'utf8').includes('e2e-script-ok'), 15000, 300);
  assert(okFile, 'arquivo nao apareceu');
});
await check('exec', 'script (cmd inline)', async () => {
  if (process.platform !== 'win32') return { skip: 'so Windows' };
  const out = path.join(TMP, 'cmd-ok.txt');
  await ok('POST', '/api/streamdeck/execute', { body: { type: 'script', parameters: { source: 'inline', language: 'cmd', code: `echo e2e-cmd-ok> "${out}"` } } });
  assert(await waitFor(() => fs.existsSync(out) && fs.readFileSync(out, 'utf8').includes('e2e-cmd-ok'), 10000, 300), 'arquivo nao apareceu');
});

// ---- Timers, contador, dois estados ----
await check('timers', 'contador: +1 duas vezes via press, estado no hub e no REST', async () => {
  const since = Date.now();
  await ok('POST', '/api/streamdeck/press', { body: { profileId: P_A, buttonId: 'e2e-counter' } });
  await ok('POST', '/api/streamdeck/press', { body: { profileId: P_A, buttonId: 'e2e-counter' } });
  const state = (await ok('GET', '/api/actions/state/timer')).json;
  const s = JSON.stringify(state);
  assert(s.includes('e2e-counter'), 'contador nao aparece no estado: ' + s.slice(0, 200));
  if (hub) await hub.wait('ReceiveTimerState', (e) => JSON.stringify(e.args).includes('e2e-counter'), 4000, since);
  return s.slice(0, 160);
});
await check('timers', 'countdown: inicia, corre, zera', async () => {
  await ok('POST', '/api/streamdeck/press', { body: { profileId: P_A, buttonId: 'e2e-countdown' } });
  await sleep(1500);
  const s1 = JSON.stringify((await ok('GET', '/api/actions/state/timer')).json);
  assert(s1.includes('e2e-countdown'), 'countdown nao aparece: ' + s1.slice(0, 200));
  await ok('POST', '/api/streamdeck/execute', { body: { type: 'timer', parameters: { target: 'e2e-countdown', operation: 'reset' } } });
  return s1.slice(0, 160);
});
await check('timers', 'botao de dois estados alterna (ReceiveButtonToggles + /api/info)', async () => {
  const since = Date.now();
  await ok('POST', '/api/streamdeck/press', { body: { profileId: P_A, buttonId: 'e2e-toggle' } });
  const info = (await ok('GET', '/api/info')).json;
  assert(info.toggles['e2e-toggle'] === true, 'toggles: ' + JSON.stringify(info.toggles));
  if (hub) await hub.wait('ReceiveButtonToggles', (e) => JSON.stringify(e.args).includes('e2e-toggle'), 4000, since);
  await ok('POST', '/api/streamdeck/press', { body: { profileId: P_A, buttonId: 'e2e-toggle' } });
  const info2 = (await ok('GET', '/api/info')).json;
  assert(!info2.toggles['e2e-toggle'], 'nao voltou: ' + JSON.stringify(info2.toggles));
});

// ---- Botoes de informacao ----
await check('info', 'saida de comando e valor de URL (JSON path) chegam em /api/info e no hub', async () => {
  const v = await waitFor(async () => {
    const b = (await ok('GET', '/api/info')).json.buttons;
    return b['e2e-info-cmd'] && b['e2e-info-url'] ? b : null;
  }, 20000, 500);
  assert(v, 'valores nao chegaram: ' + JSON.stringify((await ok('GET', '/api/info')).json.buttons).slice(0, 300));
  const cmd = JSON.stringify(v['e2e-info-cmd']);
  const url = JSON.stringify(v['e2e-info-url']);
  assert(cmd.includes('e2e-info-ok'), 'comando: ' + cmd);
  assert(url.includes('e2e-url-value'), 'url: ' + url);
  if (hub) await hub.wait('ReceiveInfoState', (e) => JSON.stringify(e.args).includes('e2e-info-ok'), 2000);
  return `${cmd.slice(0, 60)} | ${url.slice(0, 60)}`;
});
await check('info', 'relogio e calculado no app (servidor nao precisa mandar)', async () => ({ skip: 'clock e calculado no celular/navegador; coberto no teste de UI' }));
await check('info', 'monitor do sistema: ReceiveSystemStats com CPU/RAM', async () => {
  if (!hub) return { skip: 'sem hub' };
  const e = await hub.wait('ReceiveSystemStats', () => true, 8000);
  const s = e.args[0];
  assert(typeof s.cpuUsage === 'number' && s.ramTotal > 0, JSON.stringify(s).slice(0, 200));
  return `cpu ${s.cpuUsage.toFixed(1)}% ram ${s.ramUsage?.toFixed?.(1)}% discos ${s.disks?.length}`;
});

// ---- Volume, mixer, slider (sempre devolve o valor original) ----
await check('audio', 'GET /api/v1/mixer/out e /in, por id', async () => {
  const out = (await ok('GET', '/api/v1/mixer/out')).json;
  const inp = (await ok('GET', '/api/v1/mixer/in')).json;
  if (!out.length) return { skip: 'sem dispositivo de saida' };
  await ok('GET', `/api/v1/mixer/out/${encodeURIComponent(out[0].id)}`);
  if (inp.length) await ok('GET', `/api/v1/mixer/in/${encodeURIComponent(inp[0].id)}`);
  const nf = await api('PUT', '/api/v1/mixer/out/naoexiste', { body: { volume: 10 } });
  assert(nf.status === 404 || nf.status === 400, `id inexistente -> ${nf.status}`);
  return `${out.length} saidas, ${inp.length} entradas`;
});
await check('audio', 'slider GET/PUT do volume padrao (muda 1 ponto e devolve)', async () => {
  const before = (await ok('GET', '/api/slider')).json;
  const target = before.volume >= 50 ? before.volume - 1 : before.volume + 1;
  try {
    const after = (await ok('PUT', '/api/slider', { body: { target: 'output', volume: target } })).json;
    assert(Math.round(after.volume) === Math.round(target), `pediu ${target}, ficou ${after.volume}`);
  } finally {
    await ok('PUT', '/api/slider', { body: { target: 'output', volume: Math.round(before.volume) } });
  }
  const restored = (await ok('GET', '/api/slider')).json;
  assert(Math.round(restored.volume) === Math.round(before.volume), `nao restaurou: ${restored.volume}`);
  return `${before.label}: ${before.volume} -> ${target} -> ${restored.volume}`;
});
await check('audio', 'acao mixer volumeDown/volumeUp no dispositivo padrao (+ ReceiveVolumeChange)', async () => {
  const before = (await ok('GET', '/api/slider')).json;
  const down = before.volume >= 5;
  const since = Date.now();
  try {
    await ok('POST', '/api/streamdeck/execute', { body: { type: 'mixer', parameters: { operation: down ? 'volumeDown' : 'volumeUp', deviceId: 'default', step: '2' } } });
    const mid = (await ok('GET', '/api/slider')).json;
    assert(Math.round(mid.volume) === Math.round(before.volume + (down ? -2 : 2)), `${before.volume} -> ${mid.volume}`);
  } finally {
    await ok('PUT', '/api/slider', { body: { target: 'output', volume: Math.round(before.volume) } });
  }
  if (hub) await hub.wait('ReceiveVolumeChange', () => true, 3000, since).catch(() => null);
  const after = (await ok('GET', '/api/slider')).json;
  assert(Math.round(after.volume) === Math.round(before.volume), `nao restaurou: ${after.volume}`);
});
await check('audio', 'PUT /api/v1/mixer/out/{id} (volume -1 e devolve)', async () => {
  const out = (await ok('GET', '/api/v1/mixer/out')).json;
  if (!out.length) return { skip: 'sem saida' };
  const d = out[0];
  const vol = d.device.volume;
  try {
    const r = (await ok('PUT', `/api/v1/mixer/out/${encodeURIComponent(d.id)}`, { body: { volume: Math.max(0, vol - 1) } })).json;
    assert(r.device?.volume === Math.max(0, vol - 1) || r.volume === Math.max(0, vol - 1), JSON.stringify(r).slice(0, 200));
  } finally {
    await ok('PUT', `/api/v1/mixer/out/${encodeURIComponent(d.id)}`, { body: { volume: vol } });
  }
  const again = (await ok('GET', `/api/v1/mixer/out/${encodeURIComponent(d.id)}`)).json;
  assert((again.device?.volume ?? again.volume) === vol, 'nao restaurou');
});
await check('audio', 'GET /api/slider/options e /api/software/mute-state/{proc}', async () => {
  await ok('GET', '/api/slider/options');
  const r = await api('GET', '/api/software/mute-state/explorer');
  assert(r.status === 200 || r.status === 404, `mute-state -> ${r.status}`);
});
await check('audio', '/api/software/activate desligado por padrao -> 403', async () => {
  const r = await api('POST', '/api/software/activate', { body: { name: 'x', action: 'y' } });
  assert(r.status === 403, `status ${r.status}`);
});

// ---- Midia (pausa e retoma o que estiver tocando) ----
await check('media', 'GET /api/v1/media/sessions e por id', async () => {
  const s = (await ok('GET', '/api/v1/media/sessions')).json;
  if (!s.length) return { skip: 'nenhuma sessao de midia' };
  await ok('GET', `/api/v1/media/sessions/${encodeURIComponent(s[0].id)}`);
  return s.map((x) => `${x.id}:${x.playbackStatus}`).join(', ');
});
await check('media', 'comando na sessao (pause -> play) e ReceiveMediaState', async () => {
  if (NO_MEDIA) return { skip: '--no-media' };
  const s = (await ok('GET', '/api/v1/media/sessions')).json.find((x) => x.playbackStatus === 'Playing');
  if (!s) return { skip: 'nada tocando (nao vou dar play no que esta parado)' };
  const since = Date.now();
  const id = encodeURIComponent(s.id);
  const p = (await ok('POST', `/api/v1/media/sessions/${id}/command`, { body: { command: 'pause' } })).json;
  await sleep(700);
  const r = (await ok('POST', `/api/v1/media/sessions/${id}/command`, { body: { command: 'play' } })).json;
  if (hub) await hub.wait('ReceiveMediaState', () => true, 3000, since);
  assert(p.playing === false && r.playing === true, `pause=${p.playing} play=${r.playing}`);
  return s.id;
});
await check('media', 'acao media playpause (tecla de midia) duas vezes: volta como estava', async () => {
  if (NO_MEDIA) return { skip: '--no-media' };
  const before = (await ok('GET', '/api/v1/media/sessions')).json.find((x) => x.playbackStatus === 'Playing');
  if (!before) return { skip: 'nada tocando' };
  await ok('POST', '/api/streamdeck/execute', { body: { type: 'media', parameters: { command: 'playpause' } } });
  const paused = await waitFor(async () => (await ok('GET', `/api/v1/media/sessions/${encodeURIComponent(before.id)}`)).json.playbackStatus !== 'Playing', 4000, 300);
  await ok('POST', '/api/streamdeck/execute', { body: { type: 'media', parameters: { command: 'playpause' } } });
  const back = await waitFor(async () => (await ok('GET', `/api/v1/media/sessions/${encodeURIComponent(before.id)}`)).json.playbackStatus === 'Playing', 4000, 300);
  if (!back) await api('POST', `/api/v1/media/sessions/${encodeURIComponent(before.id)}/command`, { body: { command: 'play' } });
  assert(paused, 'a tecla de midia nao pausou ' + before.id);
  assert(back, 'nao voltou a tocar (retomei pelo comando da sessao)');
});

// ---- Teclado, janela, abrir programa/URL (janela alvo propria) ----
const TARGET_TITLE = 'DeckOS E2E Target';
const targetOut = path.join(TMP, 'target.txt');
const targetText = () => (fs.existsSync(targetOut) ? fs.readFileSync(targetOut, 'utf8').replace(/^text=/, '') : null);
await check('desktop', 'launch_app abre a janela alvo (powershell + WinForms)', async () => {
  if (NO_DESKTOP) return { skip: 'sem desktop (--no-desktop ou fora do Windows)' };
  await ok('POST', '/api/streamdeck/execute', {
    body: { type: 'launch_app', parameters: { path: 'powershell.exe', arguments: `-NoProfile -ExecutionPolicy Bypass -File "${path.join(HERE, 'target.ps1')}" -Out "${targetOut}" -Title "${TARGET_TITLE}"` } },
  });
  assert(await waitFor(() => targetText() !== null, 15000, 300), 'janela alvo nao abriu');
  const ps = spawnSync('powershell', ['-NoProfile', '-Command', `(Get-Process powershell | ? { $_.MainWindowTitle -eq '${TARGET_TITLE}' } | select -First 1).Id`], { encoding: 'utf8' });
  targetPid = parseInt(ps.stdout.trim(), 10) || null;
  return `pid ${targetPid}`;
});
await check('desktop', 'activatewindow + hotkey digita "deck" na janela alvo', async () => {
  if (NO_DESKTOP || targetText() === null) return { skip: 'sem janela alvo' };
  await ok('POST', '/api/streamdeck/execute', { body: { type: 'activatewindow', parameters: { windowName: TARGET_TITLE } } });
  await sleep(400);
  await ok('POST', '/api/streamdeck/execute', { body: { type: 'hotkey', parameters: { keys: 'deck' } } });
  const t = await waitFor(() => (targetText()?.includes('deck') ? targetText() : null), 4000);
  assert(t, `texto na janela: "${targetText()}" (foco pode ter ficado em outra janela)`);
  return `"${t}"`;
});
await check('desktop', 'acao key (tap BACKSPACE) e /api/streamdeck/key', async () => {
  if (NO_DESKTOP || !targetText()?.includes('deck')) return { skip: 'hotkey anterior falhou' };
  await ok('POST', '/api/streamdeck/execute', { body: { type: 'activatewindow', parameters: { windowName: TARGET_TITLE } } });
  await ok('POST', '/api/streamdeck/execute', { body: { type: 'key', parameters: { key: 'BACKSPACE', mode: 'tap' } } });
  assert(await waitFor(() => targetText() === 'dec', 3000), `depois do key: "${targetText()}"`);
  await ok('POST', '/api/streamdeck/key', { body: { key: 'BACKSPACE', state: 'tap' } });
  assert(await waitFor(() => targetText() === 'de', 3000), `depois do /key: "${targetText()}"`);
  const bad = await api('POST', '/api/streamdeck/key', { body: { key: 'NAOEXISTE' } });
  assert(bad.status === 400, `tecla invalida -> ${bad.status}`);
  expectedLogErrors.push(/Error executing action hotkey.*FormatException/);
  const badHotkey = await api('POST', '/api/streamdeck/execute', { body: { type: 'hotkey', parameters: { keys: '{NAOEXISTE' } } });
  assert(badHotkey.status === 200 && targetText() === 'de', 'atalho invalido digitou algo');
});
await check('desktop', 'macro: grava e para (sem reproduzir)', async () => {
  const s = await api('POST', '/api/macro/start');
  if (s.status === 404 || s.status === 501) return { skip: `start -> ${s.status}` };
  assert(s.status === 200, `start -> ${s.status}`);
  await sleep(300);
  const st = (await ok('GET', '/api/macro')).json;
  assert(st.recording === true, JSON.stringify(st));
  const stop = await ok('POST', '/api/macro/stop');
  return JSON.stringify(stop.json).slice(0, 120);
});
await check('desktop', 'launch_app com URL abre o navegador padrao (eco recebe)', async () => {
  if (NO_DESKTOP || NO_BROWSER) return { skip: '--no-browser/--no-desktop' };
  echo.hits.length = 0;
  await ok('POST', '/api/streamdeck/execute', { body: { type: 'launch_app', parameters: { path: `${ECHO}/opened-by-deckos` } } });
  assert(await waitFor(() => echo.hits.some((h) => h.url === '/opened-by-deckos'), 15000, 300), 'o navegador nao abriu a URL');
});
if (targetPid) {
  try { process.kill(targetPid); } catch { }
}

// ---- Acoes que nao rodamos aqui (so validamos a entrada) ----
await check('safety', 'windows lock/sleep/displayOff/setDefaultAudio: so schema, nao executa', async () => {
  const w = schema.find((s) => s.type === 'windows');
  if (!w) return { skip: 'tipo windows ausente (fora do Windows)' };
  const ops = w.fields.find((f) => f.key === 'operation').options.map((o) => o.value);
  for (const o of ['setDefaultAudio', 'lock', 'sleep', 'displayOff']) assert(ops.includes(o), `falta ${o}`);
  return 'nao executado de proposito (bloquearia/suspenderia este PC); coberto pelos testes de unidade';
});

// ---- Backup ----
await check('backup', 'exporta .deckos e importa de volta (round-trip)', async () => {
  const exp = await ok('GET', '/api/backup', { raw: true });
  assert(exp.buf[0] === 0x50 && exp.buf[1] === 0x4b, 'nao e zip');
  assert(/\.deckos/.test(exp.headers.get('content-disposition') ?? ''), 'sem nome .deckos');
  const before = (await ok('GET', '/api/streamdeck/profiles')).json.length;
  const imp = (await ok('POST', '/api/backup', { body: exp.buf, headers: { 'Content-Type': 'application/octet-stream' } })).json;
  assert(imp.imported >= 2, JSON.stringify(imp));
  const after = (await ok('GET', '/api/streamdeck/profiles')).json;
  assert(after.length === before, `perfis ${before} -> ${after.length} (import deveria sobrescrever pelos ids)`);
  assert(after.find((p) => p.id === P_A)?.buttons.length > 0, 'perfil A vazio depois do import');
  const bad = await api('POST', '/api/backup', { body: new TextEncoder().encode('lixo'), headers: { 'Content-Type': 'application/octet-stream' } });
  assert(bad.status === 400, `lixo -> ${bad.status}`);
  return `${exp.buf.length} bytes, ${imp.imported} perfis`;
});
await check('backup', 'import Stream Deck invalido -> 400 limpo', async () => {
  const bad = await api('POST', '/api/import/streamdeck', { body: new TextEncoder().encode('lixo'), headers: { 'Content-Type': 'application/octet-stream' } });
  assert(bad.status === 400 && bad.json?.error, `status ${bad.status}`);
});

// ---- Compartilhar ----
await check('share', 'link + QR do perfil e import como perfil novo', async () => {
  const s = (await ok('GET', `/api/share/${P_A}`)).json;
  assert(s.data && s.url.includes('#'), JSON.stringify(s).slice(0, 200));
  const qr = await ok('GET', `/api/share/${P_A}/qr`, { raw: true });
  assert(qr.buf[1] === 0x50 && qr.buf[2] === 0x4e && qr.buf[3] === 0x47, 'QR nao e PNG');
  const imp = (await ok('POST', '/api/share/import', { body: { data: s.data } })).json;
  assert(imp.profileId && imp.profileId !== P_A, JSON.stringify(imp));
  createdProfiles.add(imp.profileId);
  const p = (await ok('GET', `/api/streamdeck/profiles/${imp.profileId}`)).json;
  assert(p.buttons.length === imp.buttons, 'botoes diferentes');
  const bad = await api('POST', '/api/share/import', { body: { data: 'lixo' } });
  assert(bad.status === 400, `lixo -> ${bad.status}`);
  assert((await api('GET', '/api/share/naoexiste')).status === 404, 'inexistente nao deu 404');
  return `${s.data.length} chars, qr=${s.qr}, importado ${imp.profileId}`;
});
await check('share', 'import pelo IP da LAN tira as acoes privilegiadas', async () => {
  if (!LAN_BASE) return { skip: 'sem IP de LAN' };
  await ok('POST', '/api/streamdeck/profiles', { body: { id: 'e2e-priv', name: 'priv', rows: 3, columns: 4, buttons: [btn('p1', 0, 0, { action: { type: 'script', parameters: { code: 'exit 0' } } })] } });
  createdProfiles.add('e2e-priv');
  const s = (await ok('GET', '/api/share/e2e-priv')).json;
  const imp = (await ok('POST', '/api/share/import', { body: { data: s.data }, base: LAN_BASE })).json;
  createdProfiles.add(imp.profileId);
  assert(imp.stripped === 1, JSON.stringify(imp));
});

// ---- Automacoes ----
await check('triggers', 'PUT/GET/run e restaura a lista', async () => {
  originalTriggers = (await ok('GET', '/api/triggers')).json;
  const t = { id: 'e2e-trigger', name: 'e2e', enabled: false, event: 'schedule', time: '03:33', days: '0', profileId: P_A, buttonId: 'e2e-http' };
  const saved = (await ok('PUT', '/api/triggers', { body: [...originalTriggers, t] })).json;
  assert(saved.some((x) => x.id === 'e2e-trigger'), 'nao salvou');
  echo.hits.length = 0;
  await ok('POST', '/api/triggers/e2e-trigger/run');
  assert(await waitFor(() => echo.hits.some((h) => h.url === '/press'), 5000), 'run nao apertou o botao');
  assert((await api('POST', '/api/triggers/naoexiste/run')).status === 404, 'inexistente nao deu 404');
  await ok('PUT', '/api/triggers', { body: originalTriggers });
  assert((await ok('GET', '/api/triggers')).json.length === originalTriggers.length, 'nao restaurou');
});

// ---- Steam ----
await check('steam', 'GET /api/steam/games (pode ser vazio) e icone inexistente', async () => {
  const g = (await ok('GET', '/api/steam/games')).json;
  assert(Array.isArray(g), 'nao e lista');
  assert((await api('GET', '/api/steam/icon/0')).status === 404, 'icone 0 nao deu 404');
  if (g.length) await ok('GET', `/api/steam/icon/${g[0].value}`);
  return `${g.length} jogos`;
});

// ---- Integracoes sem conta: estado "nao configurado" e validacao ----
await check('integrations', 'GET /api/integrations', async () => {
  const l = (await ok('GET', '/api/integrations')).json;
  assert(l.length >= 10, `so ${l.length}`);
  return l.map((i) => `${i.name}${i.connected ? '*' : ''}`).join(' ');
});
const ACCOUNT = ['homeassistant', 'spotify', 'twitch', 'youtube', 'mqtt', 'hue', 'streamerbot', 'vtubestudio', 'vmix', 'companion', 'mairlist', 'radiodj'];
for (const name of ACCOUNT) {
  await check('integrations', `${name}: status, POST vazio valida, options sem conta`, async () => {
    const st = await api('GET', `/api/integrations/${name}`);
    if (st.status === 404) return { skip: 'nao registrada' };
    assert(st.status === 200, `status -> ${st.status}`);
    const conf = await api('POST', `/api/integrations/${name}`, { body: {} });
    assert(conf.status === 200, `POST vazio -> ${conf.status}`);
    const opts = await api('GET', `/api/integrations/${name}/options/naoexiste`);
    assert([200, 404, 502].includes(opts.status), `options -> ${opts.status}`);
    return `connected=${st.json.connected} msg=${(conf.json?.message ?? '').slice(0, 60)}`;
  });
}
await check('integrations', 'callback OAuth anonimo com state invalido nao quebra', async () => {
  const r = await api('GET', '/api/integrations/spotify/callback?state=x&code=y', { key: '', raw: true });
  assert(r.status === 200, `status ${r.status}`);
  const u = await api('GET', '/api/integrations/naoexiste/callback', { key: '', raw: true });
  assert(u.status === 200, `desconhecida -> ${u.status}`);
});
await check('integrations', 'OBS: estado desconectado e listas vazias', async () => {
  const s = (await ok('GET', '/api/obs/state')).json;
  for (const u of ['scenes', 'sources', 'audio-inputs']) {
    const r = await api('GET', `/api/obs/${u}`);
    // Sem OBS: 502 com a mensagem para o editor mostrar.
    assert(r.status === 200 || (r.status === 502 && r.json?.error), `${u} -> ${r.status}`);
  }
  return `connected=${s.connected}`;
});
await check('integrations', 'Discord: estado nao configurado, guilds sem conexao', async () => {
  const s = (await ok('GET', '/api/discord/state')).json;
  const g = await api('GET', '/api/discord/guilds');
  assert(g.status === 200 || (g.status === 502 && g.json?.error), `guilds -> ${g.status}`);
  return `configured=${s.configured} connected=${s.connected} guilds=${g.status}`;
});
await check('integrations', 'Tuya, Govee, Soundboard, Companion, Tally', async () => {
  await ok('GET', '/api/tuya/state');
  const gv = await api('GET', '/api/govee/devices');
  assert(gv.status < 500, `govee -> ${gv.status}`);
  await ok('GET', '/api/soundboard/state');
  await ok('GET', '/api/soundboard/config');
  const dev = await api('GET', '/api/soundboard/devices');
  assert(dev.status < 500, `soundboard devices -> ${dev.status}`);
  await ok('GET', '/api/companion/keys');
  await ok('GET', '/api/tally/targets');
});

// ---- Descoberta ----
await check('discovery', 'UDP 7573 "DeckOSDiscoveryRequest" responde ip/name', async () => {
  const sock = dgram.createSocket('udp4');
  await new Promise((r) => sock.bind(0, r));
  const got = new Promise((res) => sock.once('message', (m) => res(m.toString())));
  sock.send('DeckOSDiscoveryRequest', 7573, LAN ?? '127.0.0.1');
  const msg = await Promise.race([got, sleep(3000).then(() => null)]);
  sock.close();
  assert(msg, 'sem resposta');
  const j = JSON.parse(msg);
  assert(j.ip && j.name, msg);
  return msg;
});
await check('discovery', 'mDNS: PTR _deckos._tcp.local responde', async () => {
  const q = mdnsQuery('_deckos._tcp.local');
  const sock = dgram.createSocket({ type: 'udp4', reuseAddr: true });
  const answers = [];
  sock.on('message', (m) => { if (m.includes(Buffer.from('_deckos'))) answers.push(m); });
  await new Promise((r) => sock.bind(5353, () => { try { sock.addMembership('224.0.0.251', LAN ?? undefined); } catch { } r(); }));
  for (let i = 0; i < 3 && !answers.some(isResponse); i++) {
    sock.send(q, 5353, '224.0.0.251');
    await sleep(700);
  }
  // Pergunta "legacy unicast" (porta de origem != 5353): a resposta volta direto.
  const uni = dgram.createSocket('udp4');
  await new Promise((r) => uni.bind(0, r));
  uni.on('message', (m) => answers.push(m));
  uni.send(q, 5353, '224.0.0.251');
  await sleep(1200);
  uni.close();
  sock.close();
  const resp = answers.filter(isResponse);
  assert(resp.length, 'nenhuma resposta mDNS com _deckos');
  return `${resp.length} respostas`;
});
function isResponse(m) { return m.length > 3 && (m[2] & 0x80) !== 0 && m.includes(Buffer.from('_deckos')); }
function mdnsQuery(name) {
  const labels = name.split('.').flatMap((l) => [Buffer.from([l.length]), Buffer.from(l)]);
  return Buffer.concat([Buffer.from([0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]), ...labels, Buffer.from([0, 0, 12, 0, 1])]);
}

// ---- Limpeza ----
await check('cleanup', 'apaga os perfis e2e (+ ReceiveDeckUpdate)', async () => {
  for (const id of createdProfiles) await ok('DELETE', `/api/streamdeck/profiles/${id}`);
  const list = (await ok('GET', '/api/streamdeck/profiles')).json;
  const left = list.filter((p) => createdProfiles.has(p.id));
  assert(!left.length, 'sobrou: ' + left.map((p) => p.id).join(','));
});
await check('cleanup', 'grade original restaurada', async () => {
  if (!originalLayout) return { skip: 'sem grade' };
  const l = (await ok('GET', '/api/streamdeck/layout')).json;
  assert(l.rows === originalLayout.rows && l.columns === originalLayout.columns, JSON.stringify(l));
});

hub?.close();
echoServer.close();

// ---- Log do servidor: erros durante o teste ----
if (LOG && fs.existsSync(LOG)) {
  const text = fs.readFileSync(LOG, 'utf8').slice(logStart);
  const lines = text.split(/\r?\n/);
  const bad = [];
  lines.forEach((l, i) => {
    if (!(/^(fail|crit):/.test(l) || /Unhandled exception/.test(l))) return;
    const ctx = lines.slice(i, i + 3).join(' | ');
    if (!expectedLogErrors.some((re) => re.test(ctx))) bad.push(ctx.slice(0, 300));
  });
  if (bad.length) record('server-log', `${bad.length} erro(s) no log do servidor`, 'FAIL', '\n    ' + bad.slice(0, 15).join('\n    '));
  else record('server-log', 'nenhum fail/crit no log do servidor', 'PASS');
}

const n = (s) => results.filter((r) => r.status === s).length;
console.log(`\n${n('PASS')} passaram, ${n('FAIL')} falharam, ${n('SKIP')} pulados`);
fs.writeFileSync(path.join(TMP, 'results.json'), JSON.stringify(results, null, 2));
console.log(`resultados: ${path.join(TMP, 'results.json')}`);
process.exit(n('FAIL') ? 1 : 0);
