// Fixture-only tap for Puppeteer's two inherited local pipe FDs. The bytes being
// forwarded never pass through a JSON serializer. Only allowlisted metadata is saved.
import { spawn } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { writeFileSync } from 'node:fs';
import { Socket } from 'node:net';
import { isAbsolute, join } from 'node:path';
import { pathToFileURL } from 'node:url';

const MAX_PACKET = 4 * 1024 * 1024; // The smoke scene's source frames are 160×120.
const MAX_ENTRIES = 1024;
const methods = new Set(['Fetch.enable', 'Fetch.requestPaused', 'Fetch.fulfillRequest', 'Page.captureScreenshot']);
const token = (s) => typeof s === 'string' && s.length > 0 && s.length <= 256;
const key = (session, id) => JSON.stringify([session, id]);

function videoFrame(raw) {
  try {
    const u = new URL(raw);
    return ['http:', 'https:'].includes(u.protocol) && ['127.0.0.1', 'localhost', '[::1]', 'hyperframes-render.invalid'].includes(u.hostname) &&
      !u.username && !u.password && !u.search && !u.hash &&
      /^\/__hyperframes_video_frames__\/[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\/[0-9]+$/i.test(u.pathname);
  } catch { return false; }
}

function imageMetadata(p) {
  const type = p.responseHeaders?.find((h) => typeof h?.name === 'string' && h.name.toLowerCase() === 'content-type')?.value;
  const mime = typeof type === 'string' ? type.split(';', 1)[0].trim().toLowerCase() : '';
  if (!['image/jpeg', 'image/png'].includes(mime) || p.responseCode !== 200 || typeof p.body !== 'string' || !p.body.length) return null;
  const body = Buffer.from(p.body, 'base64');
  if (body.toString('base64') !== p.body) return null;
  const valid = mime === 'image/jpeg'
    ? body.length > 4 && body[0] === 255 && body[1] === 216 && body[2] === 255 && body.at(-2) === 255 && body.at(-1) === 217
    : body.length >= 45 && body.subarray(0, 8).equals(Buffer.from('89504e470d0a1a0a', 'hex')) &&
      body.toString('ascii', 12, 16) === 'IHDR' && body.toString('ascii', body.length - 8, body.length - 4) === 'IEND';
  return valid ? { responseCode: 200, contentType: mime, length: body.length, sha256: createHash('sha256').update(body).digest('hex') } : null;
}

// One fixed slab per direction. An oversized packet is discarded *only from the
// observer*, through its next NUL. Fragmentation, UTF-8 boundaries and batching
// have no effect on transmission or on subsequent frames.
function framer(limit, accept, dropped) {
  const slab = Buffer.allocUnsafe(limit);
  let length = 0, over = false;
  return {
    push(buf) {
      let start = 0;
      while (start < buf.length) {
        const nul = buf.indexOf(0, start), end = nul < 0 ? buf.length : nul;
        if (!over) {
          if (length + end - start > limit) { over = true; dropped(); }
          else { buf.copy(slab, length, start, end); length += end - start; }
        }
        if (nul < 0) return;
        if (!over && length) {
          try { accept(JSON.parse(slab.toString('utf8', 0, length))); }
          catch { dropped(); }
        }
        length = 0; over = false; start = end + 1;
      }
    },
    partial: () => over || length !== 0,
  };
}

export function createAudit(limit = MAX_PACKET) {
  const counts = {}, frames = [], pauses = new Set(), pending = new Map();
  let drops = 0;
  const count = (m) => { counts[m] = (counts[m] ?? 0) + 1; };
  function see(side, m) {
    if (!m || typeof m !== 'object') return;
    const { method, sessionId, id, params: p } = m;
    if (methods.has(method) && (method === 'Fetch.requestPaused' ? side === 'from' : side === 'to')) count(method);
    if (!token(sessionId)) return;
    const req = token(p?.requestId) ? key(sessionId, p.requestId) : null;
    const cmd = Number.isSafeInteger(id) && id >= 0 ? key(sessionId, id) : null;
    if (side === 'from') {
      if (method === 'Fetch.requestPaused' && req && p.responseStatusCode === undefined && p.responseErrorReason === undefined && videoFrame(p.request?.url)) {
        count('video_frame_pauses_visible_in_trace');
        if (pauses.has(req) || pauses.size >= MAX_ENTRIES) { drops++; return; }
        pauses.add(req);
      } else if (!method && cmd && pending.has(cmd)) {
        const row = pending.get(cmd);
        pending.delete(cmd);
        row.reply = !Object.hasOwn(m, 'error') && m.result !== null && typeof m.result === 'object' && !Array.isArray(m.result) ? 'success' : 'error';
      }
      return;
    }
    // A command ID cannot identify two in-flight commands within one session.
    if (cmd && pending.has(cmd)) { pending.delete(cmd); drops++; return; }
    if (!req || !pauses.has(req)) return;
    if (method === 'Fetch.failRequest' || method === 'Fetch.continueRequest') { pauses.delete(req); return; }
    if (method !== 'Fetch.fulfillRequest' || !cmd) return;
    pauses.delete(req);
    const image = imageMetadata(p);
    if (!image) return;
    if (frames.length >= MAX_ENTRIES) { drops++; return; }
    const row = { route: 'hf-video-frame', sessionId, requestId: p.requestId, commandId: id, ...image, reply: 'missing' };
    frames.push(row);
    pending.set(cmd, row);
  }
  const make = (side) => framer(limit, (m) => see(side, m), () => { drops++; });
  const to = make('to'), from = make('from');
  return {
    to: to.push, from: from.push,
    report: () => ({ format: 1, complete: drops === 0 && !to.partial() && !from.partial(), drops, counts, frames }),
  };
}

async function main([shim, outputDir, ...args]) {
  if (!shim || !outputDir || !isAbsolute(shim) || !isAbsolute(outputDir) || !args.includes('--remote-debugging-pipe')) {
    throw new Error('expected absolute fixture shim, audit directory and --remote-debugging-pipe');
  }
  // Socket wraps inherited pipe descriptors (including Unix socketpairs); no listen/connect.
  const input = new Socket({ fd: 3, readable: true, writable: false });
  const output = new Socket({ fd: 4, readable: false, writable: true });
  const audit = createAudit();
  const env = { ...process.env };
  delete env.SAFARIUM_CDP_TRACE; // A raw trace would leak body fragments.
  const child = spawn(shim, args, { stdio: ['inherit', 'inherit', 'inherit', 'pipe', 'pipe'], env });
  const toChild = child.stdio[3], fromChild = child.stdio[4];
  let streamError = false;
  const stop = (sig) => { if (child.exitCode === null && child.signalCode === null) child.kill(sig); };
  const signals = ['SIGTERM', 'SIGINT', 'SIGHUP'].map((sig) => {
    const handler = () => stop(sig);
    process.on(sig, handler);
    return [sig, handler];
  });
  const flushed = new Promise((resolve) => { output.once('finish', resolve); output.once('close', resolve); });
  const closed = new Promise((resolve) => {
    child.once('error', () => { streamError = true; });
    child.once('close', (code, signal) => resolve({ code, signal }));
  });
  input.on('error', () => { streamError = true; toChild.end(); });
  toChild.on('error', () => { input.destroy(); }); // e.g. orderly peer close after Browser.close
  fromChild.on('error', () => { streamError = true; output.end(); stop('SIGTERM'); });
  output.on('error', () => { streamError = true; input.destroy(); stop('SIGTERM'); });
  // Observe before forwarding, so a fast reply can never race registration of its command.
  input.on('data', audit.to).pipe(toChild);   // EOF closes the child's fd 3 after queued bytes.
  fromChild.on('data', audit.from).pipe(output); // .pipe supplies backpressure on both directions.
  const { code, signal } = await closed;
  input.destroy();
  output.end();
  await flushed;
  const report = audit.report();
  report.complete &&= !streamError;
  writeFileSync(join(outputDir, `audit-${randomUUID()}.json`), JSON.stringify(report) + '\n', { flag: 'wx', mode: 0o600 });
  for (const [sig, handler] of signals) process.off(sig, handler);
  if (signal) process.kill(process.pid, signal);
  else process.exitCode = code ?? 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try { await main(process.argv.slice(2)); }
  catch (e) { console.error(`fetch-audit-pipe: ${e.message}`); process.exitCode = 1; }
}
