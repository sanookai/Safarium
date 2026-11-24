// Optional, standalone capability probe; not part of `node --test`.
// SAFARIUM_CDP=... PPTR_DIR=... SCRATCH_DIR=... node Tests/cdp/fetch-scopes.mjs
// JSON on stdout. Unsupported scopes are observations; contradictory or unsafe results exit 1.
import { execFileSync } from 'node:child_process';
import { once } from 'node:events';
import { mkdir, rm, writeFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { exe, puppeteer, scratch } from './lib.mjs';

const WAIT = 5_000;
const INVALID = 'https://safarium-fetch.invalid/only-synthetic.js';
const html = '<!doctype html><meta charset="utf-8"><meta http-equiv="x-dns-prefetch-control" content="off"><body>Fetch scope fixture</body>';
const images = {
  origin: 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYPj/HwADAgH/5ncLrgAAAABJRU5ErkJggg==', // 1×1 blue
  synthetic: 'iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAADklEQVR4nGP4z8DwHwQBEPgD/U6VwW8AAAAASUVORK5CYII=', // 2×1 red/green
};
const result = (verdict, reason) => ({ verdict, reason });
const message = (e) => String(e?.message || e).split('\n')[0];

function asset(kind, source, allowOrigin) {
  const headers = { 'Cache-Control': 'no-store', 'X-Scope-Proof': source, 'X-Unexposed-Fixture': 'test-only' };
  if (allowOrigin) Object.assign(headers, { 'Access-Control-Allow-Origin': allowOrigin, 'Access-Control-Expose-Headers': 'X-Scope-Proof' });
  headers['Content-Type'] = { script: 'text/javascript', image: 'image/png', fetch: 'text/plain' }[kind];
  const body = kind === 'image' ? Buffer.from(images[source], 'base64') :
    Buffer.from(kind === 'script' ? `document.documentElement.dataset.scopeProof = ${JSON.stringify(source)};` : source);
  return { status: kind === 'fetch' && source === 'synthetic' ? 201 : 200, headers, body };
}

async function origin() {
  const routes = new Map(), hits = [];
  const server = createServer((req, res) => {
    hits.push({ path: req.url, method: req.method });
    const route = routes.get(req.url);
    if (!route) { res.writeHead(404); res.end(); return; }
    res.writeHead(route.status, route.headers);
    res.end(route.body);
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  return {
    base: `http://127.0.0.1:${server.address().port}`, routes,
    count(path) { return hits.filter((r) => r.path === path && r.method === 'GET').length; },
    close() { return new Promise((resolve) => { server.close(resolve); server.closeAllConnections(); }); },
  };
}

// Runs in the page. An image can display yet be unreadable via canvas; report both facts.
async function inPage({ kind, url, anonymous }) {
  if (kind === 'fetch') {
    try {
      const r = await fetch(url, { mode: 'cors', credentials: 'omit' });
      return { state: 'loaded', status: r.status, body: await r.text(), proof: r.headers.get('X-Scope-Proof'),
        unexposed: r.headers.get('X-Unexposed-Fixture'), type: r.type };
    } catch (e) { return { state: 'rejected', error: e.name }; }
  }
  delete document.documentElement.dataset.scopeProof;
  const element = document.createElement(kind === 'image' ? 'img' : 'script');
  if (anonymous) element.crossOrigin = 'anonymous';
  const loaded = new Promise((resolve) => {
    element.onload = () => resolve(true);
    element.onerror = () => resolve(false);
  });
  try {
    element.src = url;
    document.body.append(element);
    if (!await loaded) return { state: 'rejected', error: 'element error' };
    if (kind === 'script') return { state: 'loaded', marker: document.documentElement.dataset.scopeProof ?? null };
    const out = { state: 'loaded', size: [element.naturalWidth, element.naturalHeight] };
    try {
      const canvas = document.createElement('canvas');
      canvas.width = element.naturalWidth; canvas.height = element.naturalHeight;
      const ctx = canvas.getContext('2d');
      ctx.drawImage(element, 0, 0);
      out.pixels = [...ctx.getImageData(0, 0, Math.min(2, canvas.width), 1).data];
    } catch (e) { out.readError = e.name; }
    return out;
  } finally { element.remove(); }
}

// No request is continued by this handler, including unexpected events. It only answers its exact URL.
async function intercepted(page, url, answer, stage, work, originCount) {
  const cdp = await page.createCDPSession();
  const wire = { enabled: false, events: [] };
  const replies = [];
  cdp.on('Fetch.requestPaused', (e) => {
    const observation = { matches: e.request.url === url, type: e.resourceType, stageStatus: e.responseStatusCode ?? null,
      originAtPause: originCount?.() ?? null, sourceHeader: e.responseHeaders?.find((h) => h.name.toLowerCase() === 'x-scope-proof')?.value ?? null };
    wire.events.push(observation);
    replies.push((async () => {
      try {
        if (!observation.matches) return await cdp.send('Fetch.failRequest', { requestId: e.requestId, errorReason: 'BlockedByClient' });
        await cdp.send('Fetch.fulfillRequest', {
          requestId: e.requestId, responseCode: answer.status, body: answer.body.toString('base64'),
          responseHeaders: Object.entries(answer.headers).map(([name, value]) => ({ name, value })),
        });
        observation.fulfilled = true;
      } catch (e2) {
        observation.error = message(e2);
        await cdp.send('Fetch.failRequest', { requestId: e.requestId, errorReason: 'Failed' }).catch(() => {});
      }
    })());
  });
  try {
    try {
      await cdp.send('Fetch.enable', { patterns: [{ urlPattern: url, requestStage: stage }] });
      wire.enabled = true;
    } catch (e) { wire.error = message(e); return { wire, dom: null }; }
    const dom = await work(() => wire.events.length === 0).catch((e) => ({ state: 'command-error', error: message(e) }));
    await Promise.all(replies);
    return { wire, dom };
  } finally { await cdp.detach(); }
}

function classify({ scope, kind, anonymous, allow, phase, stage }, { wire, dom, hits }) {
  const cross = scope === 'loopback-cross';
  const synthetic = phase === 'synthetic';
  const deny = cross && !allow && (kind === 'fetch' || anonymous);
  const displayOnly = cross && kind === 'image' && !anonymous;
  if (dom?.state === 'not-attempted') return result(dom.wrongFilter ? 'incorrect' : 'unsupported', dom.reason);
  // Evaluate access first: an accidental native fallback does not excuse exposing disallowed data.
  if (deny && dom?.state === 'loaded') return result('incorrect', 'CORS-mode read/load succeeded without ACAO');
  if (displayOnly && dom?.pixels) return result('incorrect', 'cross-origin no-CORS image exposed canvas pixels');
  if (cross && kind === 'fetch' && dom?.unexposed != null) return result('incorrect', 'unexposed response header visible to cross-origin JS');
  if (synthetic) {
    if (!wire.enabled) return result(/^Protocol error/.test(wire.error) ? 'unsupported' : 'error', wire.error);
    const [event] = wire.events;
    if (!event) {
      if (stage === 'Response') return result('incorrect', 'Response pattern ACKed without a response pause');
      return result(dom?.state === 'command-error' ? 'error' : 'unsupported', 'no matching pause; no substitution proven');
    }
    if (wire.events.length !== 1 || !event.matches) return result('incorrect', 'wrong or duplicate paused request');
    if (event.type !== { fetch: 'Fetch', image: 'Image', script: 'Script' }[kind]) return result('incorrect', 'wrong resource type');
    if (stage === 'Response') {
      if (event.stageStatus !== 200 || event.originAtPause !== 1 || event.sourceHeader !== 'origin')
        return result('incorrect', 'Response pattern ACKed but not paused on the real origin response');
    } else if (event.stageStatus !== null || (hits !== null && hits !== 0)) {
      return result('incorrect', 'request-stage interception did not precede origin delivery');
    }
    if (!event.fulfilled) return result(event.error?.startsWith('Protocol error') ? 'unsupported' : 'error', event.error || 'no fulfillment');
    if (stage === 'Response' && hits !== 1) return result('incorrect', 'response substitution did not use exactly one origin response');
  }
  if (dom?.state === 'command-error') return result('error', dom.error);
  if (!synthetic && hits !== null && hits !== 1) return result('unsupported', 'native resource did not reach its fixture origin exactly once');
  if (deny) return result(dom?.state === 'rejected' ? 'verified' : 'incorrect', 'expected CORS denial');
  if (dom?.state !== 'loaded') return result(stage === 'Response' ? 'incorrect' : 'unsupported', 'resource did not load in the document');
  const source = synthetic ? 'synthetic' : 'origin';
  let correct;
  if (kind === 'script') correct = dom.marker === source;
  if (kind === 'fetch') {
    if (scope === 'file-project' && dom.type === 'opaque') return result('unsupported', 'file-project response is opaque');
    correct = dom.body === source && ((scope === 'file-project' && !synthetic) ||
      (dom.status === (synthetic ? 201 : 200) && dom.proof === source));
  }
  if (kind === 'image') {
    const size = synthetic ? [2, 1] : [1, 1];
    if (String(dom.size) !== String(size)) return result('incorrect', 'wrong decoded image size');
    if (displayOnly) correct = dom.readError === 'SecurityError';
    else if (scope === 'file-project' && dom.readError === 'SecurityError') return result('unsupported', 'image displays; file-origin policy denies pixel read');
    else correct = String(dom.pixels) === String(synthetic ? [255, 0, 0, 255, 0, 255, 0, 255] : [0, 0, 255, 255]);
  }
  return result(correct ? 'verified' : 'incorrect', correct ? (displayOnly ? 'image displayed; canvas read denied' : 'fixture content observed') : 'wrong DOM content/status/headers');
}

async function openPage(browser, url) {
  const page = await browser.newPage();
  try {
    page.setDefaultTimeout(WAIT);
    await page.goto(url);
    return page;
  } catch (e) { await page.close(); throw e; }
}

// Prove that a real, allowed cross-origin script no longer reaches loopback before assigning
// the reserved HTTPS URL. No proxy or host mapping. The optional worker only blocks requests;
// it never forwards anything or supplies test bytes. No verified fence => no .invalid request.
async function offlinePage(browser, a, b) {
  const failures = [];
  for (const fence of ['cdp-offline', 'blocking-service-worker']) {
    let page;
    const canary = async (suffix) => {
      const path = `/fence-canary-${fence}-${suffix}.js`;
      b.routes.set(path, asset('script', 'origin', a.base));
      const dom = await page.evaluate(inPage, { kind: 'script', url: b.base + path, anonymous: true });
      return { dom, hits: b.count(path) };
    };
    try {
      page = await openPage(browser, a.base + (fence === 'cdp-offline' ? '/index.html' : '/fence/index.html'));
      const online = await canary('online');
      if (online.dom.marker !== 'origin' || online.hits !== 1) throw new Error('online canary did not execute from the second origin');
      if (fence === 'cdp-offline') {
        const gate = await page.createCDPSession();
        await gate.send('Network.enable');
        await gate.send('Network.emulateNetworkConditions', { offline: true, latency: 0, downloadThroughput: 0, uploadThroughput: 0 });
      } else {
        const worker = `
          self.addEventListener('install', e => e.waitUntil(self.skipWaiting()));
          self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
          self.addEventListener('fetch', e => {
            if (new URL(e.request.url).origin !== self.location.origin) e.respondWith(Response.error());
          });`;
        a.routes.set('/fence/blocker.js', { status: 200, headers: { 'Content-Type': 'text/javascript', 'Cache-Control': 'no-store' }, body: worker });
        await page.evaluate(async () => {
          const sw = navigator.serviceWorker;
          await sw.register('./blocker.js', { scope: './' });
          await sw.ready;
          if (!sw.controller) await new Promise((resolve) => sw.addEventListener('controllerchange', resolve, { once: true }));
          if (sw.controller?.scriptURL !== new URL('./blocker.js', location.href).href) throw new Error('different controller');
        });
      }
      const blocked = await canary('blocked');
      if (blocked.dom.state !== 'rejected' || blocked.hits !== 0) throw new Error('offline canary was not rejected before reaching its origin');
      return { page, fence, online, blocked, checkEnabled: () => canary('after-fetch-enable') };
    } catch (e) {
      failures.push(`${fence}: ${message(e)}`);
      await page?.close();
    }
  }
  return { failures };
}

const rows = [];
async function main() {
  const banner = execFileSync(exe, ['--version'], { encoding: 'utf8', timeout: WAIT }).trim();
  if (!/^Safarium CDP shim .+ \(WebKit\)$/.test(banner)) throw new Error('SAFARIUM_CDP must name the Safarium WebKit shim');
  const dir = scratch(), project = join(dir, 'project');
  let a, b, browser;
  try {
    await mkdir(project);
    await writeFile(join(project, 'index.html'), html);
    a = await origin(); b = await origin();
    const index = { status: 200, headers: { 'Content-Type': 'text/html', 'X-DNS-Prefetch-Control': 'off' }, body: html };
    a.routes.set('/index.html', index); a.routes.set('/fence/index.html', index);
    const env = { ...process.env, TMPDIR: dir, SAFARIUM_CDP_LOG: join(dir, 'unsupported.log'), NO_PROXY: '*', no_proxy: '*' };
    for (const key of Object.keys(env)) if (/^(all|http|https)_proxy$/i.test(key) || key === 'SAFARIUM_CDP_TRACE') delete env[key];
    browser = await puppeteer.launch({ executablePath: exe, pipe: true, protocolTimeout: WAIT, userDataDir: join(dir, 'profile'), env });

    async function run(page, c, target, reply, originCount, checkEnabled) {
      const work = async (noPauses = () => true) => {
        if (checkEnabled) {
          c.afterFetchEnable = await checkEnabled();
          if (!noPauses())
            return { state: 'not-attempted', wrongFilter: true, reason: 'Fetch paused the unmatched canary; reserved host was not requested' };
          if (c.afterFetchEnable.dom.state !== 'rejected' || c.afterFetchEnable.hits !== 0)
            return { state: 'not-attempted', reason: 'offline fence not verified with Fetch enabled; reserved host was not requested' };
        }
        return page.evaluate(inPage, { kind: c.kind, url: target.domURL, anonymous: !!c.anonymous });
      };
      try {
        const obs = c.phase === 'synthetic' ? await intercepted(page, target.url, reply, c.stage ?? 'Request', work, originCount) :
          { dom: await work().catch((e) => ({ state: 'command-error', error: message(e) })) };
        obs.hits = originCount?.() ?? null;
        rows.push({ ...c, ...classify(c, obs), ...obs });
      } catch (e) { rows.push({ ...c, ...result('error', message(e)) }); }
    }
    async function cases(page, scope, specs, site) {
      for (const spec of specs) for (const phase of spec.stage ? ['synthetic'] : ['origin', 'synthetic']) {
        const c = { scope, ...spec, phase };
        const name = `${scope}-${spec.name}-${phase}.${{ script: 'js', image: 'png', fetch: 'txt' }[c.kind]}`;
        const path = '/' + name;
        const allowed = c.allow ? a.base : null;
        const fallback = asset(c.kind, 'origin', allowed);
        if (site) site.routes.set(path, fallback);
        else await writeFile(join(project, name), fallback.body);
        const url = site ? site.base + path : pathToFileURL(join(project, name)).href;
        await run(page, c, { url, domURL: site ? url : `./${name}` }, asset(c.kind, 'synthetic', allowed), site ? () => site.count(path) : null);
      }
    }
    // "File project" means same freshly made directory, not universal file:// access.
    let filePage;
    try { filePage = await openPage(browser, pathToFileURL(join(project, 'index.html')).href); }
    catch (e) { rows.push({ scope: 'file-project', ...result('unsupported', `file navigation: ${message(e)}`) }); }
    if (filePage) {
      try { await cases(filePage, 'file-project', ['script', 'image', 'fetch'].map((kind) => ({ name: kind, kind }))); }
      finally { await filePage.close(); }
    }
    const httpPage = await openPage(browser, a.base + '/index.html');
    await cases(httpPage, 'loopback-same', [
      { name: 'fetch', kind: 'fetch' }, { name: 'response-stage', kind: 'fetch', stage: 'Response' },
    ], a);
    await cases(httpPage, 'loopback-cross', [
      { name: 'classic-script', kind: 'script' },
      { name: 'display-image', kind: 'image' },
      { name: 'cors-image-allow', kind: 'image', anonymous: true, allow: true },
      { name: 'cors-image-deny', kind: 'image', anonymous: true },
      { name: 'fetch-allow', kind: 'fetch', allow: true }, { name: 'fetch-deny', kind: 'fetch' },
    ], b);
    await httpPage.close();

    const { page, checkEnabled, ...evidence } = await offlinePage(browser, a, b);
    const c = { scope: 'offline-https-invalid', kind: 'script', phase: 'synthetic', anonymous: true, ...evidence };
    if (page) {
      try { await run(page, c, { url: INVALID, domURL: INVALID }, asset('script', 'synthetic', a.base), null, checkEnabled); }
      finally { await page.close(); }
    } else rows.push({ ...c, ...result('unsupported', 'no verified offline fence; reserved host was not requested') });
  } finally {
    try {
      if (browser) {
        let timer;
        const child = browser.process();
        try {
          await Promise.race([browser.close(), new Promise((_, reject) => {
            timer = setTimeout(() => reject(new Error('browser cleanup timed out')), WAIT);
          })]);
        } finally {
          clearTimeout(timer);
          if (child?.exitCode === null && child.signalCode === null) {
            const exited = once(child, 'exit'); child.kill('SIGKILL'); await exited;
          }
        }
      }
    } finally {
      try { await Promise.all([a?.close(), b?.close()]); }
      finally { await rm(dir, { recursive: true, force: true }); }
    }
  }
}

try { await main(); }
catch (e) { rows.push({ scope: 'probe', ...result('error', message(e)) }); }
const counts = Object.fromEntries(['verified', 'unsupported', 'incorrect', 'error'].map((k) => [k, rows.filter((r) => r.verdict === k).length]));
console.log(JSON.stringify({ counts, rows }, null, 2));
if (counts.incorrect || counts.error) process.exitCode = 1;
