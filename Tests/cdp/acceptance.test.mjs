// Acceptance 1: plain puppeteer-core 25.x drives safarium-cdp over --remote-debugging-pipe (no mocks).
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { exe, puppeteer, fixtureURL, decode } from './lib.mjs';

const near = (a, b, tol = 6) => a.every((v, i) => Math.abs(v - b[i]) <= tol);

test('--version prints a version and exits 0', () => {
  const out = execFileSync(exe, ['--version']).toString();
  assert.match(out, /\d+\.\d+/);
});

test('puppeteer flow: newPage, viewport, goto, evaluate, init script, screenshots, close', async (t) => {
  const browser = await puppeteer.launch({ executablePath: exe, pipe: true, args: ['--window-size=800,600'] });
  let closed = false;
  t.after(async () => { if (!closed) await browser.close().catch(() => {}); });
  assert.ok((await browser.version()).length > 0);

  const page = await browser.newPage();
  await page.setViewport({ width: 400, height: 300 });
  await page.evaluateOnNewDocument(() => { window.__pre = 'set-before-page-scripts'; });
  const logs = [];
  page.on('console', (m) => logs.push(m.text()));
  await page.goto(fixtureURL('basic.html'), { waitUntil: 'load' });

  assert.equal(await page.title(), 'basic fixture');
  assert.equal(await page.evaluate(() => document.getElementById('msg').textContent), 'hello safarium');
  assert.equal(await page.evaluate(() => document.documentElement.dataset.pre), 'set-before-page-scripts');
  assert.equal(await page.evaluate((a, b) => a + b, 2, 3), 5);
  assert.deepEqual(await page.evaluate(() => ({ a: [1, 2], s: 'x', n: null })), { a: [1, 2], s: 'x', n: null });
  assert.equal(await page.evaluate(async () => { await new Promise((r) => setTimeout(r, 30)); return 'async-ok'; }), 'async-ok');
  assert.deepEqual(await page.evaluate(() => [window.innerWidth, window.innerHeight]), [400, 300]);
  await assert.rejects(page.evaluate(() => { throw new Error('boom-42'); }), /boom-42/);
  await new Promise((r) => setTimeout(r, 100));
  assert.ok(logs.some((l) => l.includes('fixture-log')), `console relay, got ${JSON.stringify(logs)}`);

  const png = decode(await page.screenshot({ type: 'png' }));
  assert.deepEqual([png.width, png.height], [400, 300]);
  assert.ok(near(png.px(50, 50), [255, 0, 0, 255]), `red box ${png.px(50, 50)}`);
  assert.ok(near(png.px(350, 280), [255, 255, 255, 255]), `white bg ${png.px(350, 280)}`);

  const jpgBuf = await page.screenshot({ type: 'jpeg', quality: 90 });
  assert.equal(jpgBuf[0], 0xff); assert.equal(jpgBuf[1], 0xd8);
  const jpg = decode(jpgBuf, 'jpg');
  assert.deepEqual([jpg.width, jpg.height], [400, 300]);

  const clip = decode(await page.screenshot({ clip: { x: 0, y: 0, width: 100, height: 50, scale: 2 } }));
  assert.deepEqual([clip.width, clip.height], [200, 100]);
  assert.ok(near(clip.px(100, 50), [255, 0, 0, 255]));

  const transparent = decode(await page.screenshot({ omitBackground: true }));
  assert.ok(near(transparent.px(50, 50), [255, 0, 0, 255]));
  assert.equal(transparent.px(350, 280)[3], 0, `alpha ${transparent.px(350, 280)}`);

  await page.close();
  closed = true;
  await browser.close();
  assert.equal(browser.process()?.exitCode ?? 0, 0);
});

test('unknown CDP method answers -32601', async (t) => {
  const browser = await puppeteer.launch({ executablePath: exe, pipe: true });
  t.after(() => browser.close().catch(() => {}));
  const page = await browser.newPage();
  const cdp = await page.createCDPSession();
  await assert.rejects(cdp.send('Foo.nope'), (e) => /wasn't found|-32601/.test(String(e.message)) || e.code === -32601);
});

test('two pages are independent', async (t) => {
  const browser = await puppeteer.launch({ executablePath: exe, pipe: true });
  t.after(() => browser.close().catch(() => {}));
  const a = await browser.newPage(), b = await browser.newPage();
  await a.goto('data:text/html,<title>A</title>a');
  await b.goto('data:text/html,<title>B</title>b');
  assert.equal(await a.title(), 'A');
  assert.equal(await b.title(), 'B');
});
