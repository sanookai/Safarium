// Public, request-stage CDP over a real Safarium pipe. Only the ephemeral origin below is contacted.
// The two HF-shaped tests use a local stand-in for its CDN and an actual DOM image decode.
import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter, once } from 'node:events';
import { readFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { exe, fixtureURL, puppeteer } from './lib.mjs';
import { rawClient } from './raw.mjs';

const WAIT = 8_000;
const PAUSED = 'Fetch.requestPaused';
const INDEX = '/project/index.html';
const checkHTML = readFileSync(new URL(fixtureURL('fetch-check.html')));
const indexHTML = '<!doctype html><meta charset="utf-8"><title>Fetch lab</title><output></output>';
// 2 × 1 RGBA PNG, red then green. The origin never serves these bytes.
const framePNG = 'iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAADklEQVR4nGP4z8DwHwQBEPgD/U6VwW8AAAAASUVORK5CYII=';
const requestPattern = (urlPattern) => ({ urlPattern, requestStage: 'Request' });
const b64 = (value) => Buffer.from(value).toString('base64');
const header = (name, value) => ({ name, value });

async function bounded(promise, label) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(`Timed out: ${label}`)), WAIT);
    })]);
  } finally { clearTimeout(timer); }
}

async function origin(t) {
  const hits = [];
  const server = createServer((req, res) => {
    const path = req.url;
    hits.push({ path, method: req.method, probe: req.headers['x-fixture-probe'] });
    res.setHeader('Cache-Control', 'no-store');
    if (path === INDEX || path === '/project/check.html') {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(path === INDEX ? indexHTML : checkHTML);
    } else if (path.endsWith('.js')) {
      res.writeHead(200, { 'Content-Type': 'text/javascript; charset=utf-8' });
      res.end(`(window.originScripts ??= []).push(${JSON.stringify(path)});`);
    } else {
      res.writeHead(200, { 'Content-Type': 'text/plain', 'X-Source': 'origin' });
      res.end(`origin:${path}`);
    }
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => new Promise((resolve) => {
    server.close(resolve);
    server.closeAllConnections();
  }));
  return { base: `http://127.0.0.1:${server.address().port}`, hits, count: (path) => hits.filter((h) => h.path === path).length };
}

async function browserPage(t) {
  const browser = await puppeteer.launch({ executablePath: exe, pipe: true, protocolTimeout: WAIT });
  const child = browser.process();
  t.after(async () => {
    try {
      if (browser.connected) await bounded(browser.close(), 'browser cleanup');
    } finally {
      if (child && child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
    }
  });
  const page = await browser.newPage();
  page.setDefaultTimeout(WAIT);
  return { page, browser };
}

// Record before starting page JS. wait() also sees events delivered before evaluate() returns.
function observe(cdp) {
  const seen = [];
  const bus = new EventEmitter();
  cdp.on(PAUSED, (event) => {
    seen.push(event);
    bus.emit(event.request.url, event);
  });
  return { seen, async wait(url) {
    const found = seen.find((p) => p.request.url === url);
    if (found) return found;
    try {
      const [event] = await once(bus, url, { signal: AbortSignal.timeout(WAIT) });
      return event;
    } catch {
      assert.fail(`No ${PAUSED} for ${url}; saw ${seen.map((e) => e.request.url).join(', ') || 'none'}`);
    }
  } };
}

function requestPause(event, url, type) {
  assert.equal(event.request.url, url);
  assert.equal(event.request.method, 'GET');
  assert.ok(event.request.headers && typeof event.request.headers === 'object' && !Array.isArray(event.request.headers));
  assert.ok(typeof event.requestId === 'string' && event.requestId.length);
  assert.ok(typeof event.frameId === 'string' && event.frameId.length);
  assert.equal(event.resourceType, type);
  assert.equal(event.responseStatusCode, undefined);
  assert.equal(event.responseErrorReason, undefined);
  return event.requestId;
}

// Runs a real (possibly parser-blocking) navigation/evaluation concurrently with its CDP replies.
async function routeWhile(cdp, respond, work) {
  const failure = Promise.withResolvers();
  const replies = [];
  const events = [];
  const listener = (event) => {
    events.push(event);
    const reply = Promise.resolve().then(() => respond(event));
    replies.push(reply);
    reply.catch(failure.reject);
  };
  cdp.on(PAUSED, listener);
  try {
    const value = await Promise.race([failure.promise, work()]);
    await Promise.all(replies);
    return { value, events };
  } finally { cdp.off(PAUSED, listener); }
}

test('continue: a matching fetch stays off the wire while an unmatched fetch completes', async (t) => {
  const site = await origin(t);
  const { page } = await browserPage(t);
  await page.goto(site.base + INDEX);
  const cdp = await page.createCDPSession();
  const pauses = observe(cdp);
  const path = '/project/io/pass?sequence=1';
  await cdp.send('Fetch.enable', { patterns: [requestPattern(`${site.base}/project/io/*`)] });
  await page.evaluate(() => {
    window.held = fetch('./io/pass?sequence=1', { headers: { 'X-Fixture-Probe': 'round-trip' } })
      .then(async (r) => [r.status, r.headers.get('X-Source'), await r.text()]);
  });
  const event = await pauses.wait(site.base + path);
  const id = requestPause(event, site.base + path, 'Fetch');
  assert.equal(site.count(path), 0);
  assert.equal(await page.evaluate(async () => (await fetch('./bypass')).text()), 'origin:/project/bypass');
  assert.equal(site.count('/project/bypass'), 1);
  assert.equal(site.count(path), 0, 'origin must still be untouched after an independent round trip');
  await cdp.send('Fetch.continueRequest', { requestId: id });
  assert.deepEqual(await page.evaluate(() => window.held), [200, 'origin', `origin:${path}`]);
  assert.deepEqual(site.hits.filter((h) => h.path === path), [{ path, method: 'GET', probe: 'round-trip' }]);
  assert.deepEqual(pauses.seen.map((e) => e.request.url), [site.base + path]);
});

test('named second loopback origin: synthetic CORS bytes work; continue cannot read the other server', async (t) => {
  const site = await origin(t), other = await origin(t);
  const { page } = await browserPage(t);
  await page.goto(site.base + INDEX);
  const cdp = await page.createCDPSession();
  const prefix = other.base + '/render/';
  await cdp.send('Fetch.enable', { patterns: [requestPattern(prefix + '*')] });
  const { value, events } = await routeWhile(cdp, (e) => {
    const id = requestPause(e, e.request.url, 'Fetch');
    if (e.request.url === prefix + 'forward') return cdp.send('Fetch.continueRequest', { requestId: id });
    assert.equal(e.request.url, prefix + 'memory');
    return cdp.send('Fetch.fulfillRequest', { requestId: id, responseCode: 200, body: b64('memory-only'),
      responseHeaders: [header('Content-Type', 'text/plain'), header('Access-Control-Allow-Origin', site.base)] });
  }, () => page.evaluate(async (p) => Promise.all(['memory', 'forward'].map(async (tail) => {
    try { return await (await fetch(p + tail, { mode: 'cors', credentials: 'omit' })).text(); }
    catch (error) { return error.name; }
  })), prefix));
  assert.deepEqual(value, ['memory-only', 'TypeError']);
  assert.equal(events.length, 2);
  assert.deepEqual(other.hits, []);
});

test('fulfill/fail: fetch exposes synthetic status, headers and binary bytes; only fail rejects', async (t) => {
  const site = await origin(t);
  const { page } = await browserPage(t);
  await page.goto(site.base + INDEX);
  const prefix = '/project/api/';
  const cdp = await page.createCDPSession();
  const pauses = observe(cdp);
  await cdp.send('Fetch.enable', { patterns: [requestPattern(site.base + prefix + '*')] });
  await page.evaluate(() => {
    const read = async (name) => {
      try {
        const r = await fetch(`./api/${name}`);
        return [r.status, r.headers.get('Content-Type'), r.headers.get('X-Fixture'), [...new Uint8Array(await r.arrayBuffer())]];
      } catch (e) { return ['rejected', e.name]; }
    };
    window.finished = Promise.all(['bytes', 'missing', 'failed'].map(read)).then((rows) => {
      document.querySelector('output').textContent = JSON.stringify(rows);
    });
  });
  const names = ['bytes', 'missing', 'failed'];
  const ids = await Promise.all(names.map(async (name) => {
    const url = site.base + prefix + name;
    return requestPause(await pauses.wait(url), url, 'Fetch');
  }));
  assert.equal(new Set(ids).size, 3);
  const bytes = [0, 255, 128, 13, 10, 65, 0];
  const responseHeaders = [header('Content-Type', 'application/octet-stream'), header('X-Fixture', 'from-shim')];
  await cdp.send('Fetch.failRequest', { requestId: ids[2], errorReason: 'Failed' });
  await cdp.send('Fetch.fulfillRequest', { requestId: ids[1], responseCode: 404, responseHeaders, body: '' });
  await cdp.send('Fetch.fulfillRequest', { requestId: ids[0], responseCode: 201, responseHeaders, body: b64(bytes) });
  await page.evaluate(() => window.finished);
  assert.deepEqual(JSON.parse(await page.$eval('output', (el) => el.textContent)), [
    [201, 'application/octet-stream', 'from-shim', bytes],
    [404, 'application/octet-stream', 'from-shim', []],
    ['rejected', 'TypeError'],
  ]);
  assert.deepEqual(names.map((name) => site.count(prefix + name)), [0, 0, 0]);
});

test('HF check shape: pre-navigation prefix fulfills a relative parser script and continues the fallback', async (t) => {
  const site = await origin(t);
  const { page } = await browserPage(t);
  const cdp = await page.createCDPSession();
  const prefix = site.base + '/project/vendor/';
  await cdp.send('Network.enable');
  await cdp.send('Fetch.enable', { patterns: [requestPattern(prefix + '*')] });
  const { events } = await routeWhile(cdp, (event) => {
    const { url } = event.request;
    const requestId = requestPause(event, url, 'Script');
    if (url === prefix + 'fallback.js') return cdp.send('Fetch.continueRequest', { requestId });
    assert.equal(url, prefix + 'known.js');
    return cdp.send('Fetch.fulfillRequest', {
      requestId, responseCode: 200,
      responseHeaders: [header('Content-Type', 'text/javascript; charset=utf-8'), header('Access-Control-Allow-Origin', '*')],
      body: b64('document.documentElement.dataset.synthetic = "เฟรม 42";'),
    });
  }, () => page.goto(`${site.base}/project/check.html`, { waitUntil: 'load' }));
  await cdp.detach();
  assert.deepEqual(events.map((e) => e.request.url).sort(), [prefix + 'fallback.js', prefix + 'known.js']);
  assert.deepEqual(await page.evaluate(() => [document.documentElement.dataset.synthetic, window.originScripts]), [
    'เฟรม 42', ['/project/vendor/fallback.js', '/project/plain.js'],
  ]);
  assert.deepEqual(['/project/vendor/known.js', '/project/vendor/fallback.js', '/project/plain.js'].map(site.count), [0, 1, 1]);
});

test('response stage: CDP reads the actual origin body, then the page receives that same response', async (t) => {
  const site = await origin(t);
  const { page } = await browserPage(t);
  await page.goto(site.base + INDEX);
  const path = '/project/inspect/body', url = site.base + path;
  const session = await page.createCDPSession();
  await session.send('Fetch.enable', { patterns: [{ urlPattern: url, requestStage: 'Response' }] });
  let inspected;
  const { value, events } = await routeWhile(session, async (e) => {
    assert.equal(e.request.url, url);
    assert.equal(e.responseStatusCode, 200);
    assert.equal(site.count(path), 1, 'the response exists before this pause');
    const r = await session.send('Fetch.getResponseBody', { requestId: e.requestId });
    inspected = Buffer.from(r.body, r.base64Encoded ? 'base64' : 'utf8').toString('utf8');
    await session.send('Fetch.continueResponse', { requestId: e.requestId });
  }, () => page.evaluate(async (u) => {
    const r = await fetch(u);
    return [r.status, r.headers.get('X-Source'), await r.text()];
  }, url));
  assert.equal(events.length, 1);
  assert.equal(inspected, `origin:${path}`);
  assert.deepEqual(value, [200, 'origin', inspected]);
  assert.equal(site.count(path), 1, 'continuing a response does not re-fetch it');
});

test('HF render shape: post-navigation fulfill supplies real PNG pixels to an awaiting img.decode()', async (t) => {
  const site = await origin(t);
  const { page } = await browserPage(t);
  await page.goto(site.base + INDEX);
  const path = '/__hyperframes_video_frames__/fixture/0';
  const cdp = await page.createCDPSession();
  await cdp.send('Fetch.enable', { patterns: [requestPattern(`${site.base}/__hyperframes_video_frames__/fixture/*`)] });
  const { value, events } = await routeWhile(cdp, (event) => cdp.send('Fetch.fulfillRequest', {
    requestId: requestPause(event, site.base + path, 'Image'), responseCode: 200,
    responseHeaders: [header('Content-Type', 'image/png'), header('Cache-Control', 'no-store'), header('Access-Control-Allow-Origin', '*')],
    body: framePNG,
  }), () => page.evaluate(async () => {
    const img = document.createElement('img');
    document.body.append(img);
    img.crossOrigin = 'anonymous';
    img.src = '../__hyperframes_video_frames__/fixture/0';
    await img.decode();
    const canvas = document.createElement('canvas');
    canvas.width = img.naturalWidth;
    canvas.height = img.naturalHeight;
    const ctx = canvas.getContext('2d');
    ctx.drawImage(img, 0, 0);
    return [img.naturalWidth, img.naturalHeight, [...ctx.getImageData(0, 0, 2, 1).data]];
  }));
  assert.deepEqual(value, [2, 1, [255, 0, 0, 255, 0, 255, 0, 255]]);
  assert.equal(events.length, 1);
  assert.equal(site.count(path), 0);
});

test('raw CDP: disjoint sessions on one target cannot resolve each other’s IDs or reuse an ID', async (t) => {
  const site = await origin(t);
  const c = rawClient();
  t.after(async () => {
    c.child.stdio[3].end();
    try { await bounded(c.exited, 'raw client exit after pipe EOF'); }
    finally {
      if (c.child.exitCode === null && c.child.signalCode === null) {
        c.kill();
        await bounded(c.exited, 'raw client cleanup');
      }
    }
  });
  async function send(method, params, sessionId) {
    const reply = await c.send(method, params, sessionId);
    assert.ok(!reply.error, `${method}: ${JSON.stringify(reply.error)}`);
    return reply.result;
  }
  async function evaluate(sessionId, expression) {
    const result = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }, sessionId);
    assert.ok(!result.exceptionDetails, JSON.stringify(result.exceptionDetails));
    return result.result.value;
  }
  const { targetId } = await send('Target.createTarget', { url: 'about:blank' });
  const attach = () => send('Target.attachToTarget', { targetId, flatten: true }).then((r) => r.sessionId);
  const a = await attach(), b = await attach();
  assert.notEqual(a, b);
  await send('Page.enable', {}, a);
  await send('Page.setLifecycleEventsEnabled', { enabled: true }, a);
  const nav = await send('Page.navigate', { url: site.base + INDEX }, a);
  assert.ok(nav.loaderId && !nav.errorText);
  await c.waitEvent('Page.lifecycleEvent', (e) => e.sessionId === a && e.params.loaderId === nav.loaderId && e.params.name === 'load', WAIT);
  const aPath = '/project/scope/a', bPath = '/project/scope/b';
  await send('Fetch.enable', { patterns: [requestPattern(site.base + aPath)] }, a);
  await send('Fetch.enable', { patterns: [requestPattern(site.base + bPath)] }, b);
  async function mustReject(method, params, sessionId) {
    const { error } = await c.send(method, params, sessionId);
    assert.ok(error && Number.isInteger(error.code) && error.message, `${method} ACKed an invalid request ID`);
  }
  await mustReject('Fetch.continueRequest', { requestId: 'never-issued' }, a);
  async function nextId(sessionId, path) {
    const url = site.base + path;
    const event = await c.waitEvent(PAUSED, (e) => e.sessionId === sessionId && e.params.request.url === url, WAIT);
    return requestPause(event.params, url, 'Fetch');
  }
  await evaluate(a, `void (window.replyA = fetch('./scope/a').then(r => r.text()))`);
  const idA = await nextId(a, aPath);
  // B has no outstanding ID of its own, even for implementations with per-session ID counters.
  await mustReject('Fetch.failRequest', { requestId: idA, errorReason: 'Failed' }, b);
  await evaluate(a, `void (window.replyB = fetch('./scope/b').then(r => r.text()))`);
  const idB = await nextId(b, bPath);
  await send('Fetch.fulfillRequest', { requestId: idA, responseCode: 200, body: b64('only A') }, a);
  await mustReject('Fetch.continueRequest', { requestId: idA }, a);
  await send('Fetch.continueRequest', { requestId: idB }, b);
  assert.deepEqual(await evaluate(a, 'Promise.all([window.replyA, window.replyB])'), ['only A', `origin:${bPath}`]);
  assert.deepEqual([site.count(aPath), site.count(bPath)], [0, 1]);
  assert.equal(c.events.filter((e) => e.method === PAUSED).length, 2, 'events must only reach their owners');
});

for (const release of ['Fetch.disable', 'detach']) {
  test(`${release} drains existing pauses and subsequent fetches reach the origin`, async (t) => {
    const site = await origin(t);
    const { page } = await browserPage(t);
    await page.goto(site.base + INDEX);
    const cdp = await page.createCDPSession();
    const pauses = observe(cdp);
    const prefix = '/project/held/';
    await cdp.send('Fetch.enable', { patterns: [requestPattern(site.base + prefix + '*')] });
    await page.evaluate(() => {
      window.drained = Promise.all(['one', 'two'].map((name) => fetch(`./held/${name}`).then((r) => r.text(), () => null)));
    });
    const requests = await Promise.all(['one', 'two'].map((name) => pauses.wait(site.base + prefix + name)));
    assert.deepEqual(['one', 'two'].map((name) => site.count(prefix + name)), [0, 0]);
    if (release === 'detach') await cdp.detach();
    else await cdp.send('Fetch.disable');
    const drained = await page.evaluate(() => window.drained);
    for (const [i, name] of ['one', 'two'].entries()) {
      // Either resume or cancel is a terminal outcome; a never-settled page promise is a failure.
      assert.ok(drained[i] === null || drained[i] === `origin:${prefix}${name}`, JSON.stringify(drained));
      if (drained[i] !== null) assert.equal(site.count(prefix + name), 1);
    }
    assert.equal(await page.evaluate(async () => (await fetch('./held/after')).text()), `origin:${prefix}after`);
    assert.equal(site.count(prefix + 'after'), 1);
    assert.equal(pauses.seen.length, 2);
    if (release === 'Fetch.disable') {
      await assert.rejects(cdp.send('Fetch.continueRequest', { requestId: requests[0].requestId }), /Protocol error/);
    }
  });
}

test('closing a page and then the browser with an unresolved pause does not hang or stall a sibling', async (t) => {
  const site = await origin(t);
  const { page, browser } = await browserPage(t);
  const sibling = await browser.newPage();
  await Promise.all([page.goto(site.base + INDEX), sibling.goto(site.base + INDEX)]);
  async function park(p) {
    const cdp = await p.createCDPSession();
    const pauses = observe(cdp);
    await cdp.send('Fetch.enable', { patterns: [requestPattern(`${site.base}/project/closing/*`)] });
    await p.evaluate(() => { void fetch('./closing/held').catch(() => {}); });
    await pauses.wait(`${site.base}/project/closing/held`);
  }
  await park(page);
  const probe = () => sibling.evaluate(async () => (await fetch('./closing/sibling')).text());
  assert.equal(await probe(), 'origin:/project/closing/sibling');
  assert.equal(site.count('/project/closing/held'), 0);
  await bounded(page.close(), 'page.close with held request');
  assert.equal(await probe(), 'origin:/project/closing/sibling');
  assert.equal(site.count('/project/closing/sibling'), 2);
  await park(sibling);
  await bounded(browser.close(), 'browser.close with held request');
  assert.equal(browser.process().exitCode, 0);
});

test('response-stage pattern is explicitly declined or actually pauses after the origin answers', async (t) => {
  const site = await origin(t);
  const { page } = await browserPage(t);
  await page.goto(site.base + INDEX);
  const cdp = await page.createCDPSession();
  const url = `${site.base}/project/response`;
  await cdp.send('Fetch.enable', { patterns: [requestPattern(url)] });
  const pauses = observe(cdp);
  try {
    await cdp.send('Fetch.enable', { patterns: [{ urlPattern: url, requestStage: 'Response' }] });
  } catch (e) {
    assert.match(e.message, /Protocol error \(Fetch\.enable\)/);
    t.diagnostic(`Response-stage interception not provided: ${e.message}`);
    return;
  }
  await page.evaluate(() => { window.answer = fetch('./response').then((r) => r.text()); });
  const event = await pauses.wait(url);
  assert.equal(event.responseStatusCode, 200, 'a request-stage pause cannot stand in for a response-stage one');
  assert.equal(site.count('/project/response'), 1);
  assert.ok(event.responseHeaders.some((h) => h.name.toLowerCase() === 'x-source' && h.value === 'origin'));
  await cdp.send('Fetch.continueRequest', { requestId: event.requestId });
  assert.equal(await page.evaluate(() => window.answer), 'origin:/project/response');
});
