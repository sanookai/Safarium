// Real WebKit, anonymous loopback HTTP, no NSWindow. Optional EP30 oracle:
// SAFARIUM_WAV_FIXTURE=/path/to/assets/voice.wav node --test Tests/hf/wav-metadata.test.mjs
// The normal Tests/cdp SAFARIUM_CDP and PPTR_DIR environment variables are also required.
// Byte totals below are body bytes served by the actual 206 fixture endpoints; cancellation
// cannot bound bytes an origin that ignores Range has already sent onto the wire.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { open } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { exe, puppeteer } from '../cdp/lib.mjs';

function pcm(frames, edit = () => {}) {
  const rate = 8000, size = 44 + 2 * frames, header = Buffer.alloc(44);
  header.write('RIFF'); header.writeUInt32LE(size - 8, 4); header.write('WAVEfmt ', 8);
  header.writeUInt32LE(16, 16); header.writeUInt16LE(1, 20); header.writeUInt16LE(1, 22);
  header.writeUInt32LE(rate, 24); header.writeUInt32LE(rate * 2, 28); header.writeUInt16LE(2, 32);
  header.writeUInt16LE(16, 34); header.write('data', 36); header.writeUInt32LE(2 * frames, 40);
  edit(header);
  return { size, read: (start, length) => {
    const b = Buffer.alloc(length);
    if (start < header.length) header.copy(b, 0, start);
    return b;
  } };
}

async function probe(t, sources, { smallIgnoresRange = false, capture = false, privacy = false, inspect } = {}) {
  const names = Object.keys(sources), calls = [], outside = [];
  let foreignOrigin, lookup;
  if (privacy) {
    const foreign = createServer((req, res) => { outside.push(req.url); res.writeHead(404); res.end(); });
    foreign.listen(0, '127.0.0.1'); await once(foreign, 'listening');
    foreignOrigin = `http://127.0.0.1:${foreign.address().port}`;
    t.after(() => { foreign.closeAllConnections(); foreign.close(); });
  }
  const server = createServer(async (req, res) => {
    if (privacy && req.url === '/setup') {
      res.writeHead(200, { 'Content-Type': 'text/html', 'Set-Cookie': 'wav_fixture=present; Path=/; HttpOnly; SameSite=Lax' });
      res.end('<!doctype html><title>fixture setup</title>'); return;
    }
    if (privacy && req.url === '/cookie-lookup') {
      lookup = { cookie: /(?:^|;\s*)wav_fixture=present(?:;|$)/.test(req.headers.cookie ?? ''), referer: req.headers.referer };
      res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
      res.end(JSON.stringify(lookup)); return;
    }
    if (req.url === '/') {
      res.writeHead(200, { 'Content-Type': 'text/html', 'Content-Security-Policy': "frame-ancestors 'self'" });
      res.end('<!doctype html>' + (capture ? '<meta name="hyperframes-studio-preview" content="capture">' : '') +
        '<main data-composition-id="fixture">' + names.map(n => {
          const f = sources[n], path = f.raw ?? (f.foreign ? `${foreignOrigin}/direct.wav` : (f.staticAsset ? 'assets/' : '/') + n + '.wav');
          return `<audio id="${n}" data-duration="93" src="${path}"></audio>`;
        }).join('') + '</main>' +
        `<script>window.mediaEvents=[]; for(const k of ['loadedmetadata','canplay','playing']) document.addEventListener(k,e=>mediaEvents.push(e.type),true)</script>`);
      return;
    }
    const name = /^\/(?:assets\/)?(\w+)\.wav$/.exec(req.url)?.[1], fixture = sources[name];
    if (!fixture) { res.writeHead(404); res.end(); return; }
    const src = fixture.version?.(1 + calls.filter(c => c.name === name).length) ?? fixture;
    const call = { name, method: req.method, range: req.headers.range ?? null, ifRange: req.headers['if-range'] ?? null,
      cookie: !!req.headers.cookie, authorization: !!req.headers.authorization, referer: req.headers.referer ?? null, bytes: 0 };
    calls.push(call);
    const base = { 'Content-Type': 'audio/wav', 'Accept-Ranges': 'bytes' };
    if (src.etag !== null) base.ETag = src.etag ?? '"original"';
    if (src.modified) base['Last-Modified'] = src.modified;
    if (src.redirect) { call.status = 302; res.writeHead(302, { Location: privacy ? `${foreignOrigin}/redirected.wav` : '/small.wav' }); res.end(); return; }
    if (req.method === 'HEAD') {
      call.status = src.noHead ? 405 : 200;
      res.writeHead(call.status, { ...base, 'Content-Length': src.noHead ? 0 : src.size }); res.end(); return;
    }
    let a = 0, b = src.size - 1;
    const range = /^bytes=(\d+)-(\d+)$/.exec(call.range ?? '');
    if (range) { a = Number(range[1]); b = Math.min(+range[2], b); }
    if (src.size > 4 * 1024 * 1024 && (!range || b - a + 1 > 8192)) {
      res.writeHead(400); res.end(); return;  // never serve a full large file, even on a regression
    }
    if (name === 'small' && smallIgnoresRange) { a = 0; b = src.size - 1; }
    const body = await src.read(a, b - a + 1 - (src.short ? 1 : 0)); call.bytes = body.length;
    const headers = { ...base, 'Content-Length': body.length };
    const partial = !!range && !src.ignoreRange && !(name === 'small' && smallIgnoresRange);
    if (partial) headers['Content-Range'] = `bytes ${a}-${b}/${src.size}`;
    src.changeResponse?.(headers, a, b);
    call.status = partial ? 206 : 200;
    res.writeHead(call.status, headers); res.end(body);
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(() => { server.closeAllConnections(); server.close(); });
  const browser = await puppeteer.launch({ executablePath: exe, pipe: true, protocolTimeout: 6000 });
  t.after(() => browser.close());
  const page = await browser.newPage(), cdp = await page.createCDPSession();
  const base = `http://127.0.0.1:${server.address().port}`;
  if (privacy) {
    // Establish the HttpOnly fixture cookie through normal WebKit navigation. The positive
    // lookup must deliver both cookie and Referer before any metadata requests are started.
    await page.goto(base + '/setup', { timeout: 6000 });
    assert.deepEqual(await page.evaluate(async () => {
      const r = await fetch('/cookie-lookup', { credentials:'same-origin', referrer:location.href, referrerPolicy:'same-origin' });
      return await r.json();
    }), {cookie:true, referer:base + '/setup'});
    await page.goto('about:blank', { timeout: 6000 });
  }
  await cdp.send('Fetch.enable', { patterns: [{ urlPattern: 'https://unused.invalid/marker.js' }] });
  await page.goto(base + '/', { timeout: 6000 });
  // The last, valid one-second clip proves the serial metadata pass has finished.
  await page.waitForFunction(() => document.querySelector('#small').duration === 1, { polling: 20, timeout: 4000 });
  const result = await page.evaluate(() => ({
    clips: Object.fromEntries(Array.from(document.querySelectorAll('audio'), el =>
      [el.id, { duration: Number.isFinite(el.duration) ? el.duration : null, ready: el.readyState, paused: el.paused }])),
    mediaEvents, hidden: document.hidden,
  }));
  assert.equal(result.hidden, true); assert.deepEqual(result.mediaEvents, []);
  for (const c of Object.values(result.clips)) { assert.equal(c.ready, 0); assert.equal(c.paused, true); }
  for (const name of names) assert.ok(calls.filter(c => c.name === name).length <= 3, name);
  const inspected = inspect && await inspect(page, base);
  return { clips: result.clips, calls, lookup, outside, inspected };
}

test('Strong ETag and PCM layout', async t => {
  const frames = 2_400_001, good = pcm(frames);
  const { clips, calls } = await probe(t, {
    good, rate: pcm(frames, h => h.writeUInt32LE(42, 28)), trailing: pcm(frames, h => h.writeUInt32LE(frames * 2 - 2, 40)),
    wrongRIFF: pcm(frames, h => h.writeUInt32LE(44, 4)), rf64: pcm(frames, h => h.write('RF64')),
    compressed: pcm(frames, h => h.writeUInt16LE(17, 20)), small: pcm(8000),
  }, { smallIgnoresRange: true });
  assert.equal(clips.good.duration, frames / 8000); assert.equal(clips.small.duration, 1);
  for (const k of ['rate','trailing','wrongRIFF','rf64','compressed']) assert.equal(clips[k].duration, null, k);
  assert.deepEqual(calls.filter(c => c.name === 'good').map(c => [c.method, c.range, c.bytes]),
    [['GET', 'bytes=0-4095', 4096], ['GET', `bytes=${good.size-2}-${good.size-1}`, 2]]);
  assert.deepEqual(calls.filter(c => c.name === 'good').map(c => c.ifRange), [null, '"original"']);
});

test('Bad ranges and ignored ranges', async t => {
  const frames = 2_400_000, f = () => pcm(frames);
  const { clips } = await probe(t, {
    ignored: { ...f(), ignoreRange: true }, short: { ...f(), short: true }, redirect: { ...f(), redirect: true },
    address: { ...f(), changeResponse: h => { h['Content-Range'] = `bytes 1-4096/${f().size}`; } },
    length: { ...f(), changeResponse: h => { h['Content-Range'] = `bytes 0-4095/${f().size + 2}`; } },
    tail: { ...f(), changeResponse: (h, a) => { if (a) h['Content-Range'] = `bytes 0-1/${f().size}`; } },
    changed: { ...f(), changeResponse: (h, a) => { if (a) h.ETag = '"changed"'; } },
    small: { ...pcm(8000), noHead: true },
  });
  assert.equal(clips.small.duration, 1);
  for (const k of ['ignored','address','length','tail','changed','redirect','short']) assert.equal(clips[k].duration, null, k);
});

test('Malformed and reselected sources', async t => {
  const { clips, inspected } = await probe(t, {
    malformed: {raw:'http://['}, measured: pcm(16000), again: pcm(24000), small: pcm(8000),
  }, {inspect: p => p.evaluate(() => {
    const a = document.querySelector('#measured'), b = document.querySelector('#again');
    a.setAttribute('src', 'http://[');
    const malformed = Number.isNaN(a.duration); // the own getter must return native NaN, never throw
    a.setAttribute('src', '/measured.wav');
    // Change and restore a valid URL without reading in between or yielding a microtask.
    b.setAttribute('src', '/small.wav'); b.setAttribute('src', '/again.wav');
    return [malformed, Number.isNaN(a.duration), Number.isNaN(b.duration)];
  })});
  assert.equal(clips.malformed.duration, null); assert.equal(clips.measured.duration, 2); assert.equal(clips.again.duration, 3);
  assert.deepEqual(inspected, [true, true, true]);
});

test('Validator transitions on same-size replacements', async t => {
  const frames = 2_400_000, a = pcm(frames), b = pcm(frames, h => { h.writeUInt32LE(16000, 24); h.writeUInt32LE(32000, 28); });
  assert.equal(a.size, b.size); // samplerate (and duration) changes while all range addresses remain valid
  const stamp = 'Sun, 01 Nov 2026 13:00:00 GMT';
  const swap = (before, after) => ({version: n => n === 1 ? {...a, ...before} : {...b, ...after}});
  const { clips, calls } = await probe(t, {
    changed: swap({etag:'"a"'}, {etag:'"b"'}), lost: swap({etag:'"a"'}, {etag:null}),
    lostDate: swap({etag:'"a"', modified:stamp}, {etag:'"a"'}), addedDate: swap({etag:'"a"'}, {etag:'"a"', modified:stamp}),
    weak: {...a, etag:'W/"a"', staticAsset:true}, dateOnly: {...a, etag:null, modified:stamp, staticAsset:true},
    noTagDynamic: {...a, etag:null}, small: pcm(8000),
  }, {capture:true});
  for (const n of ['changed','lost','lostDate','addedDate']) {
    assert.equal(clips[n].duration, null, n);
    assert.deepEqual(calls.filter(c => c.name === n).map(c => c.ifRange), [null, '"a"'], n);
  }
  for (const n of ['weak','dateOnly','noTagDynamic']) {
    assert.equal(clips[n].duration, null, n);
    assert.deepEqual(calls.filter(c => c.name === n).map(c => c.ifRange), [null], n);
  }
});

test('Unversioned HF static asset uses one representation', async t => {
  const n = 2_400_000, a = pcm(n), b = pcm(n, h => { h.writeUInt32LE(16000, 24); h.writeUInt32LE(32000, 28); });
  const { clips, calls, inspected } = await probe(t, {
    voice: {staticAsset:true, version: i => ({...(i === 1 ? a : b), etag:null})}, small: pcm(8000),
  }, {capture:true, inspect: async (p, base) => {
    await p.goto(base + '/', {timeout:6000});
    await p.waitForFunction(() => document.querySelector('#small').duration === 1, {polling:20, timeout:4000});
    return p.$eval('#voice', el => el.duration);
  }});
  assert.equal(clips.voice.duration, n / 8000); assert.equal(inspected, n / 16000);
  assert.deepEqual(calls.filter(c => c.name === 'voice').map(c => [c.range, c.status, c.bytes]),
    [['bytes=0-4095',206,4096], ['bytes=0-4095',206,4096]]);
  const unmarked = await probe(t, {voice:{...a, staticAsset:true, etag:null}, small:pcm(8000)});
  assert.equal(unmarked.clips.voice.duration, null); // An assets/ URL alone is not an opt-in.
});

test('Cookie, Referer and foreign redirect isolation', async t => {
  const { clips, calls, outside, lookup } = await probe(t, {
    valid: pcm(2_400_000), redirect: {...pcm(8000), redirect:true}, foreign: {foreign:true}, small: pcm(8000),
  }, {privacy:true});
  assert.equal(lookup.cookie, true); assert.ok(lookup.referer.endsWith('/setup'));
  assert.equal(clips.valid.duration, 300); assert.equal(clips.redirect.duration, null); assert.equal(clips.foreign.duration, null);
  assert.equal(calls.filter(c => c.name === 'valid' && c.status === 206).length, 2);
  assert.equal(calls.filter(c => c.name === 'redirect' && c.status === 302).length, 1);
  assert.ok(calls.every(c => !c.cookie && !c.authorization && c.referer === null));
  assert.deepEqual(outside, []); // No redirected or direct request reached the second live origin.
  t.diagnostic(JSON.stringify({positiveLookupCookie:lookup.cookie, positiveLookupReferer:!!lookup.referer,
    metadataRequests:calls.length, withCredentials:calls.filter(c => c.cookie || c.authorization).length,
    withReferer:calls.filter(c => c.referer).length, foreignOriginRequests:outside.length}));
});

test('EP30 duration matches ffprobe',
  { skip: !process.env.SAFARIUM_WAV_FIXTURE }, async t => {
    const path = process.env.SAFARIUM_WAV_FIXTURE, file = await open(path, 'r'); t.after(() => file.close());
    const { size } = await file.stat(); assert.ok(size > 4 * 1024 * 1024);
    const info = JSON.parse(execFileSync('ffprobe', ['-v','error','-select_streams','a:0',
      '-show_entries','stream=duration_ts,time_base,codec_name,sample_rate,channels,bits_per_sample:format=size','-of','json',path]));
    const s = info.streams[0], [num, den] = s.time_base.split('/').map(Number);
    const expected = Number(s.duration_ts) * num / den; assert.equal(Number(info.format.size), size);
    const real = {size, async read(start, length) {
      const b = Buffer.alloc(length); const r = await file.read(b, 0, length, start); assert.equal(r.bytesRead, length); return b;
    }};
    const { clips, calls } = await probe(t, { real, hf: {...real, staticAsset:true, etag:null}, small: pcm(8000) }, {capture:true});
    const reads = calls.filter(c => c.name === 'real'), bytes = reads.reduce((n,c) => n + c.bytes, 0);
    assert.equal(clips.real.duration, expected); assert.equal(reads.length, 2);
    assert.ok(bytes <= 4096 + 33); assert.ok(reads.filter(r => r.method === 'GET').every(r => r.range));
    assert.ok(reads.every(r => r.status === 206));
    const hf = calls.filter(c => c.name === 'hf');
    assert.equal(clips.hf.duration, expected); assert.deepEqual(hf.map(c => [c.range,c.status,c.bytes]), [['bytes=0-4095',206,4096]]);
    t.diagnostic(JSON.stringify({ size, format: s.codec_name, frames: s.duration_ts, rate: s.sample_rate, ffprobe: expected,
      strongETag: {webkit:clips.real.duration, served206BodyBytes:bytes}, hfWithoutValidators: {webkit:clips.hf.duration, served206BodyBytes:hf[0].bytes} }));
  });
