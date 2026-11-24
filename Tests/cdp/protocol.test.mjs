// Protocol-level behaviour: raw pipe client (no puppeteer) plus puppeteer helpers that exercise objectId plumbing.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync, mkdtempSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { rawClient } from './raw.mjs';
import { puppeteer, exe, fixtureURL } from './lib.mjs';

async function pageSession(c) {
  await c.send('Target.setDiscoverTargets', { discover: true });
  await c.send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: true, flatten: true });
  const created = await c.send('Target.createTarget', { url: 'about:blank' });
  const targetId = created.result.targetId;
  const att = await c.send('Target.attachToTarget', { targetId, flatten: true });
  return { targetId, sessionId: att.result.sessionId };
}

test('unknown method returns {code:-32601} and is logged once to the unsupported log', async () => {
  const dir = mkdtempSync(join(process.env.SCRATCH_DIR || tmpdir(), 'cdplog-'));
  const log = join(dir, 'unsupported.log');
  process.env.SAFARIUM_CDP_LOG = log;
  const c = rawClient();
  try {
    const r = await c.send('Made.up');
    assert.equal(r.error.code, -32601);
    assert.match(r.error.message, /Made\.up/);
    await c.send('Made.up');
    await c.send('Other.thing');
    await c.send('Browser.getVersion');
    await new Promise((r) => setTimeout(r, 100));
    const lines = readFileSync(log, 'utf8').trim().split('\n');
    assert.equal(lines.length, 2, lines.join('\n'));
    assert.match(lines[0], /Made\.up/);
    assert.match(lines[1], /Other\.thing/);
  } finally { c.kill(); delete process.env.SAFARIUM_CDP_LOG; }
});

test('unknown session id gets an error, not a hang', async () => {
  const c = rawClient();
  try {
    const r = await c.send('Runtime.enable', {}, 'NO-SUCH-SESSION');
    assert.ok(r.error);
  } finally { c.kill(); }
});

test('Runtime.evaluate: values, exceptions, unserializable numbers, promises', async () => {
  const c = rawClient();
  try {
    const { sessionId: s } = await pageSession(c);
    await c.send('Page.enable', {}, s);
    await c.send('Runtime.enable', {}, s);
    const ev = (expression, extra = {}) => c.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true, ...extra }, s);
    assert.deepEqual((await ev('1+1')).result.result, { type: 'number', value: 2, description: '2' });
    assert.deepEqual((await ev('undefined')).result.result, { type: 'undefined' });
    assert.equal((await ev('NaN')).result.result.unserializableValue, 'NaN');
    assert.deepEqual((await ev('({a:[1,{b:2}]})')).result.result.value, { a: [1, { b: 2 }] });
    assert.equal((await ev('Promise.resolve("p")')).result.result.value, 'p');
    const bad = (await ev('throw new TypeError("nope")')).result;
    assert.equal(bad.exceptionDetails.exception.subtype, 'error');
    assert.match(bad.exceptionDetails.exception.description, /^TypeError: nope/);
    const syn = (await ev('(')).result;
    assert.ok(syn.exceptionDetails, 'syntax error must surface as exceptionDetails');
    const ref = (await ev('({x:1})', { returnByValue: false })).result.result;
    assert.ok(ref.objectId, 'object by reference gets an objectId');
    const call = (await c.send('Runtime.callFunctionOn', {
      functionDeclaration: 'function (k) { return this[k]; }\n//# sourceURL=x', objectId: ref.objectId,
      arguments: [{ value: 'x' }], returnByValue: true }, s)).result.result;
    assert.equal(call.value, 1);
    const rel = await c.send('Runtime.releaseObject', { objectId: ref.objectId }, s);
    assert.deepEqual(rel.result, {});
    const stale = (await c.send('Runtime.callFunctionOn', { functionDeclaration: 'function () { return 1 }', objectId: ref.objectId, returnByValue: true }, s)).result;
    assert.ok(stale.exceptionDetails || stale.error, 'released object can no longer be used');
  } finally { c.kill(); }
});

test('Page.navigate to a missing file reports errorText; to a good file reports loaderId and fires load', async () => {
  const c = rawClient();
  try {
    const { sessionId: s, targetId } = await pageSession(c);
    await c.send('Page.enable', {}, s);
    await c.send('Page.setLifecycleEventsEnabled', { enabled: true }, s);
    await c.send('Runtime.enable', {}, s);
    const miss = await c.send('Page.navigate', { url: 'file:///definitely/not/here.html', frameId: targetId }, s);
    assert.match(miss.result.errorText, /net::ERR_/);
    const ok = await c.send('Page.navigate', { url: fixtureURL('basic.html'), frameId: targetId }, s);
    assert.ok(ok.result.loaderId && !ok.result.errorText);
    await c.waitEvent('Page.lifecycleEvent', (e) => e.params.name === 'load' && e.params.loaderId === ok.result.loaderId);
    const ctxs = c.events.filter((e) => e.method === 'Runtime.executionContextCreated');
    assert.ok(ctxs.length >= 2, 'a fresh default context is announced for the new document');
  } finally { c.kill(); }
});

test('Browser.close exits the process with code 0 after replying', async () => {
  const c = rawClient();
  await c.send('Target.setDiscoverTargets', { discover: true });
  const r = await c.send('Browser.close');
  assert.deepEqual(r.result, {});
  const { code } = await c.exited;
  assert.equal(code, 0);
});

test('closing stdin (client crash) makes the shim exit', async () => {
  const c = rawClient();
  await c.send('Browser.getVersion');
  c.child.stdio[3].end();
  const { code } = await Promise.race([c.exited, new Promise((r) => setTimeout(() => r({ code: 'hung' }), 8000))]);
  assert.equal(code, 0);
});

test('puppeteer helpers: waitForSelector, $eval, evaluateHandle, waitForFunction, setContent', async (t) => {
  const browser = await puppeteer.launch({ executablePath: exe, pipe: true });
  t.after(() => browser.close().catch(() => {}));
  const page = await browser.newPage();
  await page.setContent('<h1 id="h">hi</h1><script>setTimeout(()=>{document.body.insertAdjacentHTML("beforeend","<b id=late>x</b>")},100)</script>');
  assert.equal(await page.$eval('#h', (e) => e.textContent), 'hi');
  await page.waitForSelector('#late');
  const h = await page.evaluateHandle(() => ({ n: 7 }));
  assert.equal(await h.evaluate((o) => o.n), 7);
  assert.deepEqual(await h.jsonValue(), { n: 7 });
  await page.waitForFunction(() => document.getElementById('late') !== null);
  assert.match(await page.content(), /id="late"/);
});

test('reload and same page navigated twice keep working; evaluate during navigation does not wedge', async (t) => {
  const browser = await puppeteer.launch({ executablePath: exe, pipe: true });
  t.after(() => browser.close().catch(() => {}));
  const page = await browser.newPage();
  await page.goto(fixtureURL('basic.html'));
  await page.goto('data:text/html,<title>two</title>two');
  assert.equal(await page.title(), 'two');
  await page.reload();
  assert.equal(await page.title(), 'two');
  await page.goto(fixtureURL('basic.html'));
  assert.equal(await page.evaluate(() => document.title), 'basic fixture');
});
