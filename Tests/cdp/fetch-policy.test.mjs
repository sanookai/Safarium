// Ordinary renderer documents and anonymous loopback fixtures only.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { mkdtemp, rename, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { exe, puppeteer } from './lib.mjs';
import { rawClient } from './raw.mjs';

async function site(t, serve) {
  const hits = [];
  const s = createServer((req, res) => { hits.push(req.url); serve(req.url, res); });
  s.listen(0, '127.0.0.1'); await once(s, 'listening');
  t.after(() => new Promise(done => { s.close(done); s.closeAllConnections(); }));
  return { origin: `http://127.0.0.1:${s.address().port}`, hits };
}
async function page(t) {
  const b = await puppeteer.launch({ executablePath: exe, pipe: true, protocolTimeout: 8000 });
  t.after(() => b.close());
  const p = await b.newPage(); p.setDefaultTimeout(8000);
  return p;
}
const header = (name, value) => ({ name, value });

test('two subscribers each see the real response; continuing with partial metadata retains native policy and bytes', async t => {
  const s = await site(t, (path, r) => {
    if (path === '/') { r.writeHead(200, { 'Content-Type': 'text/html' }); r.end('<title>Owned renderer</title>'); }
    else {
      r.writeHead(200, { 'Content-Type': 'text/plain', 'Content-Security-Policy': "default-src 'none'",
        'Cross-Origin-Resource-Policy': 'same-origin', 'X-Caption-Locale': 'th' });
      r.end('คำบรรยาย');
    }
  });
  const p = await page(t); await p.goto(s.origin);
  const url = s.origin + '/caption.txt', stages = [], errors = [];
  for (const label of ['first', 'second']) {
    const c = await p.createCDPSession();
    await c.send('Fetch.enable', { patterns: [{ urlPattern: url }] });
    c.on('Fetch.requestPaused', async e => {
      try {
        const id = { requestId: e.requestId };
        if (!Object.hasOwn(e, 'responseStatusCode')) {
          stages.push(label + ':request');
          await c.send('Fetch.continueRequest', { ...id, interceptResponse: true });
        } else {
          stages.push(label + ':response');
          assert.equal(e.responseHeaders.find(h => h.name.toLowerCase() === 'content-security-policy')?.value, "default-src 'none'");
          const partial = { ...id, responseHeaders: [header('Content-Type', 'text/plain')] };
          if (label === 'first') await c.send('Fetch.continueResponse', partial);
          else await c.send('Fetch.fulfillRequest', { ...partial, responseCode: 200 }); // retain the same body
        }
      } catch (err) { errors.push(err.message); await c.send('Fetch.failRequest', { requestId: e.requestId, errorReason: 'Failed' }).catch(() => {}); }
    });
  }
  const actual = await p.evaluate(async url => {
    const r = await fetch(url);
    return [await r.text(), r.headers.get('content-security-policy'), r.headers.get('cross-origin-resource-policy'),
      r.headers.get('x-caption-locale')];
  }, url);
  assert.deepEqual(errors, []);
  assert.deepEqual(stages, ['first:request', 'second:request', 'first:response', 'second:response']);
  assert.deepEqual(actual, ['คำบรรยาย', "default-src 'none'", 'same-origin', 'th']);
  assert.equal(s.hits.filter(path => path === '/caption.txt').length, 1);
});

test('a relative renderer script honors a different mapped base; its bytes are solely the fixture reply', async t => {
  const assets = await site(t, (_, r) => { r.writeHead(404); r.end(); });
  const s = await site(t, (_, r) => { r.writeHead(200, { 'Content-Type': 'text/html' });
    r.end(`<base href="${assets.origin}/library/"><title>Fixture</title>`); });
  const p = await page(t), c = await p.createCDPSession(), events = [];
  const main = s.origin + '/project.html', label = assets.origin + '/library/label.js';
  await c.send('Fetch.enable', { patterns: [{ urlPattern: main, resourceType: 'Document' }, { urlPattern: assets.origin + '/library/*' }] });
  c.on('Fetch.requestPaused', e => {
    events.push([e.resourceType, e.request.url]);
    const id = { requestId: e.requestId };
    if (e.request.url === main) return c.send('Fetch.continueRequest', id);
    return c.send('Fetch.fulfillRequest', { ...id, responseCode: 200,
      responseHeaders: [header('Content-Type', 'text/javascript')], body: Buffer.from(`document.title='Library label'`).toString('base64') });
  });
  await p.goto(main);
  await p.evaluate(() => new Promise((done, fail) => {
    const el = document.createElement('script'); el.onload = () => done(); el.onerror = () => fail(Error('fixture script'));
    el.src = 'label.js'; document.head.append(el);
  }));
  assert.equal(await p.title(), 'Library label');
  assert.deepEqual(events, [['Document', main], ['Script', label]]);
  assert.deepEqual(assets.hits, []); assert.deepEqual(s.hits, ['/project.html']);
});

test('an already framed page reports hot enable as unsupported; a fresh single-frame navigation works', async t => {
  const s = await site(t, (path, r) => {
    r.writeHead(200, { 'Content-Type': 'text/html' });
    r.end(path === '/credits' ? '<title>Credits</title><iframe src="/names"></iframe>' : '<title>Names</title>');
  });
  const p = await page(t), c = await p.createCDPSession();
  await p.goto(s.origin + '/credits');
  const options = { patterns: [{ urlPattern: s.origin + '/captions/*' }] };
  await assert.rejects(c.send('Fetch.enable', options), /child frames/);
  await p.goto(s.origin + '/names');
  await c.send('Fetch.enable', options);
  await p.reload(); assert.equal(await p.title(), 'Names');
});

test('a selected project file and relative parser asset survive a pinned reload', async t => {
  const dir = await mkdtemp(join(process.env.SCRATCH_DIR || tmpdir(), 'owned-policy-'));
  const index = join(dir, 'index.html');
  await writeFile(index, "<title>Loading</title><script src='label.js'></script>");
  await writeFile(join(dir, 'label.js'), "document.title='Project caption'");
  const p = await page(t), c = await p.createCDPSession();
  await c.send('Fetch.enable', { patterns: [{ resourceType: 'Document' }] });
  let documents = 0;
  c.on('Fetch.requestPaused', e => { documents++; return c.send('Fetch.continueRequest', { requestId: e.requestId }); });
  await p.goto(pathToFileURL(index).href);
  assert.equal(await p.title(), 'Project caption');
  await rename(dir, dir + '-renamed'); // an ordinary project move; reload retains its selected directory
  await p.reload(); assert.equal(await p.title(), 'Project caption');
  assert.equal(documents, 2);
});

test('a single-frame parser still receives its script when the authored page also references a child document', async t => {
  const s = await site(t, (path, r) => {
    if (path === '/label.js') { r.writeHead(200, { 'Content-Type': 'text/javascript' }); r.end("document.title='Caption loaded'"); }
    else { r.writeHead(200, { 'Content-Type': 'text/html' }); r.end("<title>Scene</title><script src='/label.js'></script><iframe src='/credits'></iframe>"); }
  });
  const p = await page(t), c = await p.createCDPSession();
  await c.send('Fetch.enable', { patterns: [{ urlPattern: s.origin + '/label.js' }] });
  c.on('Fetch.requestPaused', e => c.send('Fetch.continueRequest', { requestId: e.requestId }));
  await p.goto(s.origin + '/scene');
  assert.equal(await p.title(), 'Caption loaded');
  assert.deepEqual(s.hits, ['/scene', '/label.js']);
});

test('detaching a tab session closes its auto-attached child but not an independent page session', async t => {
  const c = rawClient();
  t.after(async () => { c.child.stdio[3].end(); await c.exited; });
  async function send(m, p = {}, sid) { const r = await c.send(m, p, sid); assert.ok(!r.error, r.error?.message); return r.result; }
  const { targetInfos } = await send('Target.getTargets');
  const attach = async kind => (await send('Target.attachToTarget', { targetId: targetInfos.find(t => t.type === kind).targetId })).sessionId;
  const parent = await attach('tab'), independent = await attach('page');
  await send('Target.setAutoAttach', { autoAttach: true, flatten: true }, parent);
  const child = (await c.waitEvent('Target.attachedToTarget', e => e.sessionId === parent)).params.sessionId;
  await send('Fetch.enable', { patterns: [{ resourceType: 'Image' }] }, child);
  await send('Target.detachFromTarget', { sessionId: parent });
  assert.equal((await c.send('Fetch.disable', {}, child)).error?.code, -32001);
  await send('Runtime.enable', {}, independent);
});

test('a HyperFrames virtual localhost helper receives its document and Fetch resource entirely from CDP', async t => {
  const p = await page(t), c = await p.createCDPSession(), types = [];
  const base = 'http://hyperframes-123.localhost', doc = base + '/scene', prop = base + '/caption.json';
  await c.send('Fetch.enable', { patterns: [{ urlPattern: doc, resourceType: 'Document' },
    { urlPattern: prop, resourceType: 'Fetch' }] });
  c.on('Fetch.requestPaused', e => {
    types.push([e.resourceType, e.request.url]);
    const isDoc = e.request.url === doc;
    return c.send('Fetch.fulfillRequest', { requestId: e.requestId, responseCode: 200,
      responseHeaders: [header('Content-Type', isDoc ? 'text/html' : 'application/json')],
      body: Buffer.from(isDoc ? '<title>Owned helper</title>' : '{"text":"คำบรรยาย"}').toString('base64') });
  });
  await p.goto(doc);
  assert.equal(await p.evaluate(async () => (await (await fetch('./caption.json')).json()).text), 'คำบรรยาย');
  assert.deepEqual(types, [['Document', doc], ['Fetch', prop]]);
});
