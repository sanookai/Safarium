// Zero-dependency Node ESM SDK for `safarium-forge` routed strictly through `safarium-render forge` (SF-VIDEO-1).

import { spawn, spawnSync } from 'node:child_process';
import { chmodSync, closeSync, ftruncateSync, mkdtempSync, openSync, rmSync, writeSync } from 'node:fs';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';

export class SafariumForgeError extends Error {
  constructor(message, { returncode = 1, command = [], stderr = '', stdout = '' } = {}) {
    super(message);
    this.name = 'SafariumForgeError';
    this.returncode = returncode;
    this.command = command;
    this.stderr = stderr;
    this.stdout = stdout;
  }
}

export function defaultRenderBin() {
  const override = (process.env.SAFARIUM_RENDER_BIN || '').trim();
  return override || path.join(os.homedir(), '.local', 'bin', 'safarium-render');
}

function readExpandableLength(bytes, idx) {
  let val = 0;
  for (let i = 0; i < 4; i += 1) {
    if (idx >= bytes.length) return [null, idx];
    const b = bytes[idx];
    idx += 1;
    val = (val << 7) | (b & 0x7f);
    if ((b & 0x80) === 0) return [val, idx];
  }
  return [val, idx];
}

/**
 * Recursively unwraps Safari Bug 302253 39B/76B ES_Descriptor (0x03->0x04->0x05) into raw AudioSpecificConfig.
 */
export function unwrapWebCodecsESDS(input) {
  const raw = input instanceof Uint8Array ? input : new Uint8Array(input);
  if (raw.length === 0) throw new Error('ESDS payload is empty');
  let cur = (raw.length > 5 && raw[0] === 0 && raw[1] === 0 && raw[2] === 0 && raw[3] === 0 && raw[4] === 0x03)
    ? raw.subarray(4)
    : raw;
  let layers = 0;
  let firstLen = 0;
  while (cur.length > 0 && cur[0] === 0x03) {
    if (layers === 0) firstLen = cur.length;
    let idx = 1;
    let esLen;
    [esLen, idx] = readExpandableLength(cur, idx);
    if (esLen === null || idx + 3 > cur.length) throw new Error('malformed ES_Descriptor 0x03 header');
    const esEnd = Math.min(cur.length, idx + esLen);
    const flags = cur[idx + 2];
    idx += 3;
    if (flags & 0x80) idx += 2;
    if (flags & 0x40) {
      if (idx >= esEnd) throw new Error('truncated ES_Descriptor URL');
      idx += 1 + cur[idx];
    }
    if (flags & 0x20) idx += 2;
    if (idx >= esEnd || cur[idx] !== 0x04) throw new Error('missing DecoderConfigDescriptor 0x04');
    idx += 1;
    let dcLen;
    [dcLen, idx] = readExpandableLength(cur, idx);
    if (dcLen === null || idx + 13 > esEnd) throw new Error('malformed DecoderConfigDescriptor 0x04');
    const dcEnd = Math.min(esEnd, idx + dcLen);
    idx += 13;
    if (idx >= dcEnd || cur[idx] !== 0x05) throw new Error('missing DecoderSpecificInfo 0x05');
    idx += 1;
    let dsiLen;
    [dsiLen, idx] = readExpandableLength(cur, idx);
    if (dsiLen === null || idx + dsiLen > dcEnd) throw new Error('truncated DecoderSpecificInfo 0x05');
    cur = cur.subarray(idx, idx + dsiLen);
    layers += 1;
  }
  return {
    wasWrapped: layers > 0,
    wasBug302253: layers >= 2 || (layers === 1 && firstLen === 39),
    layersUnwrapped: layers,
    audioSpecificConfig: cur,
    audioSpecificConfigHex: Buffer.from(cur).toString('hex'),
  };
}

export class ForgePipeline {
  constructor(schema = 'safarium-forge/graph-v1') {
    this._recipe = {
      $schema: schema,
      inputs: [],
      timeline: { fps: 30, width: 1080, height: 1920 },
      videoOps: [],
      audioOps: [],
      output: { path: '' },
    };
  }

  setTimeline({ width, height, fps = 30, durationSeconds, frameCount }) {
    const tl = { fps, width, height };
    if (durationSeconds !== undefined) tl.durationSeconds = durationSeconds;
    if (frameCount !== undefined) tl.frameCount = frameCount;
    this._recipe.timeline = tl;
    return this;
  }

  addInput(spec) {
    this._recipe.inputs.push(spec);
    return this;
  }

  addVideo(id, filePath, opts = {}) {
    return this.addInput({ id, kind: 'video', path: String(filePath), ...opts });
  }

  addAudio(id, filePath, opts = {}) {
    return this.addInput({ id, kind: 'audio', path: String(filePath), ...opts });
  }

  addImage(id, filePath) {
    return this.addInput({ id, kind: 'image', path: String(filePath) });
  }

  addHtmlOverlay(id, filePath, { width, height, modeCDirtyHold = true } = {}) {
    const item = { id, kind: 'htmlOverlay', path: String(filePath), modeCDirtyHold };
    if (width !== undefined) item.width = width;
    if (height !== undefined) item.height = height;
    return this.addInput(item);
  }

  addSubtitles(id, filePath, lang = 'tha') {
    return this.addInput({ id, kind: 'subtitles', path: String(filePath), lang });
  }

  addSynthAudio(id, synth) {
    return this.addInput({ id, kind: 'synthAudio', synth });
  }

  addVideoOp(op) {
    this._recipe.videoOps.push(op);
    return this;
  }

  addAudioOp(op) {
    this._recipe.audioOps.push(op);
    return this;
  }

  setQA(qaOps) {
    this._recipe.qaOps = qaOps;
    return this;
  }

  setOutput(output) {
    this._recipe.output = {
      videoCodec: 'h264',
      pixelFormat: '420v',
      colorimetry: 'bt709_left_1_1_1',
      closedGOP: true,
      overwrite: false,
      ...output,
    };
    return this;
  }

  toJSON() {
    return JSON.parse(JSON.stringify(this._recipe));
  }

  validate(client = null) {
    return (client || new SafariumForge()).validateRecipe(this);
  }

  run(client = null, opts = {}) {
    return (client || new SafariumForge()).runRecipe(this, opts);
  }
}

export function htmlOverlayRecipe({
  htmlPath,
  outputPath,
  width,
  height,
  fps = 30,
  frames,
  durationSeconds,
  backgroundVideo,
  audioPath,
  subtitlesPath,
  lang = 'tha',
  codec = 'h264',
  modeCDirtyHold = true,
  overwrite = false,
}) {
  const pipe = new ForgePipeline().setTimeline({ width, height, fps, frameCount: frames, durationSeconds });
  pipe.addHtmlOverlay('html', htmlPath, { width, height, modeCDirtyHold });
  let videoOut = 'html';
  if (backgroundVideo) {
    pipe.addVideo('bg', backgroundVideo);
    pipe.addVideoOp({ id: 'comp', op: 'overlay', base: 'bg', over: 'html', x: '0', y: '0', opacity: '1.0' });
    videoOut = 'comp';
  }
  let audioOut;
  if (audioPath) {
    pipe.addAudio('aud', audioPath);
    pipe.addAudioOp({ id: 'master_a', op: 'loudnorm', in: 'aud', targetLUFS: -16.0, peakCeilingDBTP: -1.05 });
    audioOut = 'master_a';
  }
  let subtitles;
  if (subtitlesPath) {
    pipe.addSubtitles('subs', subtitlesPath, lang);
    subtitles = { in: 'subs', format: 'tx3g', lang };
  }
  pipe.setOutput({
    path: String(outputPath),
    videoCodec: codec,
    pixelFormat: (codec === 'hevc-alpha' || codec === 'prores4444') ? 'bgra' : '420v',
    videoOutNode: videoOut,
    ...(audioOut ? { audioOutNode: audioOut } : {}),
    ...(subtitles ? { subtitles } : {}),
    overwrite,
  });
  return pipe;
}

export class PipeEncodeSession {
  constructor(command, width, height, bpp) {
    this.command = command;
    this.expectedFrameBytes = width * height * bpp;
    this._proc = spawn(command[0], command.slice(1), { stdio: ['pipe', 'pipe', 'pipe'] });
    this._stdoutChunks = [];
    this._stderrChunks = [];
    this._proc.stdout.on('data', (d) => this._stdoutChunks.push(d));
    this._proc.stderr.on('data', (d) => this._stderrChunks.push(d));
  }

  async writeFrame(frameBytes) {
    const buf = Buffer.isBuffer(frameBytes) ? frameBytes : Buffer.from(frameBytes);
    if (buf.length !== this.expectedFrameBytes) {
      throw new Error(`expected ${this.expectedFrameBytes} bytes per frame, got ${buf.length}`);
    }
    if (!this._proc.stdin.write(buf)) {
      await new Promise((resolve) => this._proc.stdin.once('drain', resolve));
    }
  }

  finish() {
    return new Promise((resolve, reject) => {
      this._proc.on('error', reject);
      this._proc.on('close', (code) => {
        const stdout = Buffer.concat(this._stdoutChunks).toString('utf8');
        const stderr = Buffer.concat(this._stderrChunks).toString('utf8');
        if (code !== 0) {
          reject(new SafariumForgeError(`pipe-encode failed (${code}): ${stderr.trim()}`, {
            returncode: code ?? 1, command: this.command, stderr, stdout,
          }));
          return;
        }
        try {
          resolve(JSON.parse(stdout));
        } catch (err) {
          reject(new SafariumForgeError(`invalid JSON from pipe-encode: ${err.message}`, {
            returncode: code ?? 0, command: this.command, stderr, stdout,
          }));
        }
      });
      this._proc.stdin.end();
    });
  }
}

class SocketJsonLineReader {
  constructor(socket) {
    this._socket = socket;
    this._rx = '';
    this._lines = [];
    this._waiters = [];
    this._eof = false;
    this._err = null;
    socket.on('data', (chunk) => {
      this._rx += chunk.toString('utf8');
      let nl;
      while ((nl = this._rx.indexOf('\n')) >= 0) {
        const line = this._rx.slice(0, nl).trim();
        this._rx = this._rx.slice(nl + 1);
        if (!line) continue;
        if (this._waiters.length > 0) {
          this._waiters.shift().resolve(JSON.parse(line));
        } else {
          this._lines.push(JSON.parse(line));
        }
      }
    });
    socket.on('error', (err) => {
      this._err = err;
      while (this._waiters.length > 0) this._waiters.shift().reject(err);
    });
    socket.on('close', () => {
      this._eof = true;
      while (this._waiters.length > 0) {
        this._waiters.shift().reject(new SafariumForgeError('unexpected UDS EOF'));
      }
    });
  }

  next() {
    if (this._lines.length > 0) return Promise.resolve(this._lines.shift());
    if (this._err) return Promise.reject(this._err);
    if (this._eof) return Promise.reject(new SafariumForgeError('unexpected UDS EOF'));
    return new Promise((resolve, reject) => this._waiters.push({ resolve, reject }));
  }
}

function makeApfsRuntimeDir(prefix) {
  const dir = mkdtempSync(`/tmp/${prefix}`);
  chmodSync(dir, 0o700);
  return dir;
}

export class ForgeRingSession {
  constructor({ renderBin, outputPath, width, height, fps = 30, slots = 4, pixFmt = 'bgra', vflip = false, codec = 'h264', bitrate = 8000000, quality, secondary, secondaryCodec, secondaryBg = '#000000', audio, subtitles, lang = 'tha', closedGop = true, overwrite = false, daemonConn = null }) {
    const bpp = (pixFmt === 'rgb24' || pixFmt === 'bgr24') ? 3 : 4;
    this.renderBin = renderBin;
    this.width = width;
    this.height = height;
    this.slots = slots;
    this.slotBytes = width * height * bpp;
    this.totalBytes = this.slots * this.slotBytes;
    this._daemonConn = daemonConn;
    this._frameIdx = 0;
    this._finished = false;
    this.report = null;
    this._runtimeDir = makeApfsRuntimeDir('sfring-');
    this._shmPath = path.join(this._runtimeDir, 'ring.bin');
    this._shmFd = openSync(this._shmPath, 'w+', 0o600);
    chmodSync(this._shmPath, 0o600);
    ftruncateSync(this._shmFd, this.totalBytes);
    this._proc = null;
    this._socket = null;
    this._reader = null;
    this._spec = {
      width, height, fps, slots, pixFmt, vflip, codec, bitrate,
      outputPath: String(outputPath), secondaryBg, subtitleLang: lang,
      closedGOP: closedGop, shmPath: this._shmPath, overwrite,
    };
    if (quality !== undefined) this._spec.quality = quality;
    if (secondary) this._spec.secondaryPath = String(secondary);
    if (secondaryCodec) this._spec.secondaryCodec = secondaryCodec;
    if (audio) this._spec.audioPath = String(audio);
    if (subtitles) this._spec.subtitlesPath = String(subtitles);
  }

  async start() {
    try {
      if (this._daemonConn) {
        this._socket = this._daemonConn.socket;
        this._reader = this._daemonConn.reader;
        this._socket.write(`${JSON.stringify({ cmd: 'ring_start', spec: this._spec })}\n`);
        const ack = await this._reader.next();
        if (!ack.ok) throw new SafariumForgeError(`ring_start failed: ${ack.error || JSON.stringify(ack)}`);
        return this;
      }
      const sockPath = path.join(this._runtimeDir, 'ring.sock');
      this._proc = spawn(this.renderBin, ['forge', 'ring-encode', '--socket', sockPath], {
        stdio: ['ignore', 'pipe', 'pipe'],
      });
      await new Promise((resolve, reject) => {
        let stderrAcc = '';
        const onData = (chunk) => {
          stderrAcc += chunk.toString('utf8');
          if (stderrAcc.includes('RING_READY ')) {
            this._proc.stderr.off('data', onData);
            resolve();
          }
        };
        this._proc.stderr.on('data', onData);
        this._proc.once('exit', (code) => {
          reject(new SafariumForgeError(`ring-encode exited (${code}) before ready: ${stderrAcc.trim()}`, { returncode: code ?? 1, stderr: stderrAcc }));
        });
      });
      this._socket = net.createConnection(sockPath);
      await new Promise((resolve, reject) => {
        this._socket.once('connect', resolve);
        this._socket.once('error', reject);
      });
      this._reader = new SocketJsonLineReader(this._socket);
      this._socket.write(`RING_START ${JSON.stringify(this._spec)}\n`);
      const ack = await this._reader.next();
      if (!ack.ok) throw new SafariumForgeError(`RING_START failed: ${ack.error || JSON.stringify(ack)}`);
      return this;
    } catch (err) {
      await this.close();
      throw err;
    }
  }

  async writeFrame(buf, slot = null) {
    if (this._finished) throw new SafariumForgeError('cannot write frame to finished ForgeRingSession');
    const data = Buffer.isBuffer(buf) ? buf : Buffer.from(buf);
    if (data.byteLength !== this.slotBytes) {
      throw new RangeError(`expected ${this.slotBytes} bytes per frame, got ${data.byteLength}`);
    }
    const slotIdx = slot === null ? (this._frameIdx % this.slots) : slot;
    const offset = slotIdx * this.slotBytes;
    writeSync(this._shmFd, data, 0, this.slotBytes, offset);
    const idx = this._frameIdx;
    this._socket.write(`S ${slotIdx} ${idx}\n`);
    const ack = await this._reader.next();
    if (!ack.ok) throw new SafariumForgeError(`S ${slotIdx} ${idx} failed: ${ack.error || JSON.stringify(ack)}`);
    this._frameIdx += 1;
    return idx;
  }

  async finish() {
    if (this._finished) return this.report;
    this._finished = true;
    try {
      if (this._daemonConn) {
        this._socket.write('{"cmd":"ring_finish"}\n');
        const ack = await this._reader.next();
        if (!ack.ok) throw new SafariumForgeError(`ring_finish failed: ${ack.error || JSON.stringify(ack)}`);
        this.report = ack.result;
        return this.report;
      }
      this._socket.write('RING_FINISH\n');
      const ack = await this._reader.next();
      if (!ack.ok) throw new SafariumForgeError(`RING_FINISH failed: ${ack.error || JSON.stringify(ack)}`);
      if (this._proc) {
        await new Promise((resolve, reject) => {
          this._proc.once('close', (code) => {
            if (code !== 0) reject(new SafariumForgeError(`ring-encode exited ${code}`, { returncode: code ?? 1 }));
            else resolve();
          });
        });
      }
      this.report = ack.report || ack;
      return this.report;
    } finally {
      await this.close();
    }
  }

  async close() {
    if (this._shmFd !== null) {
      try { closeSync(this._shmFd); } catch {}
      this._shmFd = null;
    }
    if (!this._daemonConn && this._socket) {
      try { this._socket.destroy(); } catch {}
      this._socket = null;
    }
    if (this._proc && this._proc.exitCode === null && !this._finished) {
      try { this._proc.kill('SIGTERM'); } catch {}
    }
    if (this._runtimeDir) {
      try { rmSync(this._runtimeDir, { recursive: true, force: true }); } catch {}
      this._runtimeDir = null;
    }
  }
}

export class ForgeWarmSession {
  constructor({ renderBin, idleTimeout = 20, cacheRoot, preloadPq = true }) {
    this.renderBin = renderBin;
    this.idleTimeout = idleTimeout;
    this.cacheRoot = cacheRoot;
    this.preloadPq = preloadPq;
    this._runtimeDir = makeApfsRuntimeDir('sfwarm-');
    this.socketPath = path.join(this._runtimeDir, 'warm.sock');
    this._proc = null;
    this._socket = null;
    this._reader = null;
    this._closed = false;
  }

  async start() {
    const args = ['forge', 'daemon', '--socket', this.socketPath, '--idle-timeout', String(this.idleTimeout)];
    if (this.cacheRoot) args.push('--cache-root', String(this.cacheRoot));
    if (!this.preloadPq) args.push('--no-pq-preload');
    this._proc = spawn(this.renderBin, args, { stdio: ['ignore', 'pipe', 'pipe'] });
    try {
      await new Promise((resolve, reject) => {
        let stderrAcc = '';
        const onData = (chunk) => {
          stderrAcc += chunk.toString('utf8');
          if (stderrAcc.includes('DAEMON_READY ')) {
            this._proc.stderr.off('data', onData);
            resolve();
          }
        };
        this._proc.stderr.on('data', onData);
        this._proc.once('exit', (code) => {
          reject(new SafariumForgeError(`daemon exited (${code}) before ready: ${stderrAcc.trim()}`, { returncode: code ?? 1, stderr: stderrAcc }));
        });
      });
      this._socket = net.createConnection(this.socketPath);
      await new Promise((resolve, reject) => {
        this._socket.once('connect', resolve);
        this._socket.once('error', reject);
      });
      this._reader = new SocketJsonLineReader(this._socket);
      return this;
    } catch (err) {
      await this.shutdown();
      throw err;
    }
  }

  async call(cmd, params = {}) {
    if (this._closed || !this._socket) throw new SafariumForgeError('ForgeWarmSession is closed');
    this._socket.write(`${JSON.stringify({ cmd, ...params })}\n`);
    const resp = await this._reader.next();
    if (!resp.ok) throw new SafariumForgeError(`daemon '${cmd}' failed: ${resp.error || JSON.stringify(resp)}`);
    return resp;
  }

  async openRing(opts) {
    if (this._closed || !this._socket) throw new SafariumForgeError('ForgeWarmSession is closed');
    const session = new ForgeRingSession({
      renderBin: this.renderBin,
      daemonConn: { socket: this._socket, reader: this._reader },
      ...opts,
    });
    return session.start();
  }

  async shutdown() {
    if (this._closed) return null;
    this._closed = true;
    let ack = null;
    if (this._socket) {
      try {
        this._socket.write('{"cmd":"shutdown"}\n');
        ack = await this._reader.next();
      } catch {}
      try { this._socket.destroy(); } catch {}
      this._socket = null;
    }
    if (this._proc) {
      try {
        await new Promise((resolve) => {
          if (this._proc.exitCode !== null) resolve();
          else this._proc.once('close', resolve);
        });
      } catch {}
    }
    if (this._runtimeDir) {
      try { rmSync(this._runtimeDir, { recursive: true, force: true }); } catch {}
      this._runtimeDir = null;
    }
    return ack;
  }
}

export class SafariumForge {
  constructor(renderBin = null) {
    this.renderBin = renderBin || defaultRenderBin();
  }

  _invoke(forgeArgs, { stdinBuffer = null, parseJson = true, allowNonzeroJson = false } = {}) {
    const cmd = [this.renderBin, 'forge', ...forgeArgs];
    const res = spawnSync(cmd[0], cmd.slice(1), {
      input: stdinBuffer ?? undefined,
      encoding: 'utf8',
      maxBuffer: 64 * 1024 * 1024,
    });
    if (res.error) throw res.error;
    const stdout = res.stdout || '';
    const stderr = res.stderr || '';
    const status = res.status ?? 1;
    if (status !== 0) {
      if (status === 64 && stderr.includes('nested render refused')) {
        throw new SafariumForgeError(
          'SF-VIDEO-1 nested slot refusal (returncode 64): do not wrap SDK scripts inside `safarium-render run`',
          { returncode: status, command: cmd, stderr, stdout },
        );
      }
      if (allowNonzeroJson && parseJson && stdout.trim().startsWith('{')) {
        const parsed = JSON.parse(stdout);
        parsed._returncode = status;
        return parsed;
      }
      throw new SafariumForgeError(`command failed (${status}): ${stderr.trim() || stdout.trim()}`, {
        returncode: status, command: cmd, stderr, stdout,
      });
    }
    return parseJson ? JSON.parse(stdout) : stdout;
  }

  capabilities() {
    return this._invoke(['capabilities']);
  }

  version() {
    return this._invoke(['version'], { parseJson: false }).trim();
  }

  async runRecipe(recipe, { validateOnly = false, stdinBuffer = null } = {}) {
    if (typeof recipe === 'string') {
      const args = ['run', '--recipe', recipe];
      if (validateOnly) args.push('--validate-only');
      return this._invoke(args, { stdinBuffer });
    }
    const payload = recipe instanceof ForgePipeline ? recipe.toJSON() : recipe;
    const dir = await mkdtemp(path.join(os.tmpdir(), 'safarium-forge-node-'));
    try {
      const rpath = path.join(dir, 'recipe.json');
      await writeFile(rpath, JSON.stringify(payload, null, 2), 'utf8');
      const args = ['run', '--recipe', rpath];
      if (validateOnly) args.push('--validate-only');
      return this._invoke(args, { stdinBuffer });
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  }

  validateRecipe(recipe) {
    return this.runRecipe(recipe, { validateOnly: true });
  }

  remux(inputPath, outputPath, { to, subtitles, lang = 'tha', overwrite = false } = {}) {
    const args = ['remux', String(inputPath), '-o', String(outputPath)];
    if (to) args.push('--to', to);
    if (subtitles) args.push('--subtitles', String(subtitles), '--lang', lang);
    if (overwrite) args.push('--overwrite');
    return this._invoke(args);
  }

  inspect(targetPath, { includeAudioPackets = false } = {}) {
    const args = ['inspect', String(targetPath)];
    if (includeAudioPackets) args.push('--include-audio-packets');
    return this._invoke(args);
  }

  image(inputPath, outputPath, { quality, fps, frames, loop = 0, start = 0, overwrite = false } = {}) {
    const args = ['image', String(inputPath), '-o', String(outputPath), '--loop', String(loop)];
    if (quality !== undefined) args.push('--quality', String(quality));
    if (fps !== undefined) args.push('--fps', String(fps));
    if (frames !== undefined) args.push('--frames', String(frames));
    if (start > 0) args.push('--start', String(start));
    if (overwrite) args.push('--overwrite');
    return this._invoke(args);
  }

  audioProcess(inputPath, outputPath, opts = {}) {
    const args = ['audio', 'process', String(inputPath), '-o', String(outputPath)];
    for (const eq of opts.eq || []) args.push('--eq', eq);
    if (opts.compThresh !== undefined) args.push('--comp-thresh', String(opts.compThresh), '--comp-ratio', String(opts.compRatio ?? 4));
    if (opts.gain !== undefined) args.push('--gain', String(opts.gain));
    if (opts.lufs !== undefined) args.push('--lufs', String(opts.lufs));
    if (opts.peakDbtp !== undefined) args.push('--peak-dbtp', String(opts.peakDbtp));
    if (opts.sr !== undefined) args.push('--sr', String(opts.sr));
    if (opts.channels !== undefined) args.push('--channels', String(opts.channels));
    if (opts.bitrate !== undefined) args.push('--bitrate', String(opts.bitrate));
    if (opts.overwrite) args.push('--overwrite');
    return this._invoke(args);
  }

  crossfade(firstPath, secondPath, outputPath, { duration = 0.5, curve = 'eqpower', sr = 48000, channels = 2, overwrite = false } = {}) {
    const args = ['audio', 'crossfade', String(firstPath), String(secondPath), '-o', String(outputPath), '--duration', String(duration), '--curve', curve, '--sr', String(sr), '--channels', String(channels)];
    if (overwrite) args.push('--overwrite');
    return this._invoke(args);
  }

  silenceTrim(inputPath, outputPath, { thresholdDb = -42, padding = 0.05, sr = 48000, channels = 2, overwrite = false } = {}) {
    const args = ['audio', 'silence-trim', String(inputPath), '-o', String(outputPath), '--threshold-db', String(thresholdDb), '--padding', String(padding), '--sr', String(sr), '--channels', String(channels)];
    if (overwrite) args.push('--overwrite');
    return this._invoke(args);
  }

  waveform(inputPath, { bins = 120, sr = 8000, outputPath, overwrite = false } = {}) {
    const args = ['audio', 'waveform', String(inputPath), '--bins', String(bins), '--sr', String(sr)];
    if (outputPath) args.push('-o', String(outputPath));
    if (overwrite) args.push('--overwrite');
    return this._invoke(args);
  }

  synth(outputPath, { waveform = 'sine', freq = 440, endFreq, carriers, modHz, modDepth, amp = 0.25, duration = 1.0, sr = 48000, channels = 2, fadeIn, fadeOut, overwrite = false } = {}) {
    const args = ['audio', 'synth', '-o', String(outputPath), '--waveform', waveform, '--amp', String(amp), '--duration', String(duration), '--sr', String(sr), '--channels', String(channels)];
    if (freq !== undefined) args.push('--freq', String(freq));
    if (endFreq !== undefined) args.push('--end-freq', String(endFreq));
    if (carriers?.length) args.push('--carriers', carriers.join(','));
    if (modHz !== undefined) args.push('--mod-hz', String(modHz));
    if (modDepth !== undefined) args.push('--mod-depth', String(modDepth));
    if (fadeIn !== undefined) args.push('--fade-in', String(fadeIn));
    if (fadeOut !== undefined) args.push('--fade-out', String(fadeOut));
    if (overwrite) args.push('--overwrite');
    return this._invoke(args);
  }

  splitMp3(inputPath, outDir, { chunkSeconds = 1200, prefix = 'chunk', overwrite = false } = {}) {
    const args = ['audio', 'split-mp3', String(inputPath), '--out-dir', String(outDir), '--chunk-seconds', String(chunkSeconds), '--prefix', prefix];
    if (overwrite) args.push('--overwrite');
    return this._invoke(args);
  }

  sheet(inputPath, outputPath, { cols = 6, rows = 4, tileWidth = 270, tileHeight, padding = 8, bg = '#0F172A', everyFrames, everySec, timestamps, quality = 0.88, manifest, overwrite = false } = {}) {
    const args = ['sheet', String(inputPath), '-o', String(outputPath), '--cols', String(cols), '--rows', String(rows), '--tile-width', String(tileWidth), '--padding', String(padding), '--bg', bg, '--quality', String(quality)];
    if (tileHeight !== undefined) args.push('--tile-height', String(tileHeight));
    if (everyFrames !== undefined) args.push('--every-frames', String(everyFrames));
    else if (everySec !== undefined) args.push('--every-sec', String(everySec));
    else if (timestamps?.length) args.push('--timestamps', timestamps.join(','));
    if (manifest) args.push('--manifest', String(manifest));
    if (overwrite) args.push('--overwrite');
    return this._invoke(args);
  }

  compare(refPath, candPath, outputPath, { samples = 4, vertical = false, tileWidth = 360, padding = 8, bg = '#0F172A', overwrite = false } = {}) {
    const args = ['compare', String(refPath), String(candPath), '-o', String(outputPath), '--samples', String(samples), '--tile-width', String(tileWidth), '--padding', String(padding), '--bg', bg];
    if (vertical) args.push('--vertical');
    if (overwrite) args.push('--overwrite');
    return this._invoke(args);
  }

  pq(refPath, candPath, { samples = 12, thaiOcr = false, expectedThai, minScore = 85, maxDe00P95 = 2.0, minMsssim = 0.97, strict = false } = {}) {
    const args = ['pq', String(refPath), String(candPath), '--samples', String(samples), '--min-score', String(minScore), '--max-de00-p95', String(maxDe00P95), '--min-msssim', String(minMsssim)];
    if (thaiOcr) args.push('--thai-ocr');
    if (expectedThai !== undefined) args.push('--expected-thai', expectedThai);
    if (strict) args.push('--strict');
    return this._invoke(args, { allowNonzeroJson: !strict });
  }

  qa(inputPath, { ref, contactSheet, cols, rows, tileWidth, sceneThreshold = 0.2, silenceThresholdDb = -50, thaiOcr = false, strict = false, overwrite = false } = {}) {
    const args = ['qa', String(inputPath), '--scene-threshold', String(sceneThreshold), '--silence-threshold-db', String(silenceThresholdDb)];
    if (ref) args.push('--ref', String(ref));
    if (contactSheet) args.push('--contact-sheet', String(contactSheet));
    if (cols !== undefined) args.push('--cols', String(cols));
    if (rows !== undefined) args.push('--rows', String(rows));
    if (tileWidth !== undefined) args.push('--tile-width', String(tileWidth));
    if (thaiOcr) args.push('--thai-ocr');
    if (strict) args.push('--strict');
    if (overwrite) args.push('--overwrite');
    return this._invoke(args, { allowNonzeroJson: !strict });
  }

  reframe(inputPath, outputPath, { aspect = '9:16', detector = 'saliencyAndFace', ema = 0.14, height, codec = 'h264', overwrite = false } = {}) {
    const args = ['reframe', String(inputPath), '-o', String(outputPath), '--aspect', aspect, '--detector', detector, '--ema', String(ema), '--codec', codec];
    if (height !== undefined) args.push('--height', String(height));
    if (overwrite) args.push('--overwrite');
    return this._invoke(args);
  }

  matte(inputPath, outputPath, { mode = 'personBalanced', ema = 0.35, bg, bgImage, codec = 'hevc-alpha', maskOnly = false, maxFrames, overwrite = false } = {}) {
    const args = ['matte', String(inputPath), '-o', String(outputPath), '--mode', mode, '--ema', String(ema), '--codec', codec];
    if (bg) args.push('--bg', bg);
    if (bgImage) args.push('--bg-image', String(bgImage));
    if (maskOnly) args.push('--mask-only');
    if (maxFrames !== undefined) args.push('--max-frames', String(maxFrames));
    if (overwrite) args.push('--overwrite');
    return this._invoke(args);
  }

  _pipeEncodeArgs({ outputPath, width, height, fps = 30, pixFmt = 'bgra', vflip = false, codec = 'h264', bitrate = 8000000, quality, secondary, secondaryCodec, secondaryBg = '#000000', audio, subtitles, lang = 'tha', maxFrames, overwrite = false }) {
    const args = ['pipe-encode', '--width', String(width), '--height', String(height), '--fps', String(fps), '--pix-fmt', pixFmt, '--codec', codec, '--bitrate', String(bitrate), '-o', String(outputPath)];
    if (vflip) args.push('--vflip');
    if (quality !== undefined) args.push('--quality', String(quality));
    if (secondary) {
      args.push('--secondary', String(secondary), '--secondary-bg', secondaryBg);
      if (secondaryCodec) args.push('--secondary-codec', secondaryCodec);
    }
    if (audio) args.push('--audio', String(audio));
    if (subtitles) args.push('--subtitles', String(subtitles), '--lang', lang);
    if (maxFrames !== undefined) args.push('--max-frames', String(maxFrames));
    if (overwrite) args.push('--overwrite');
    return args;
  }

  openPipeEncode(opts) {
    const bpp = (opts.pixFmt === 'rgb24' || opts.pixFmt === 'bgr24') ? 3 : 4;
    const args = this._pipeEncodeArgs(opts);
    return new PipeEncodeSession([this.renderBin, 'forge', ...args], opts.width, opts.height, bpp);
  }

  async openRingEncode(opts) {
    const session = new ForgeRingSession({ renderBin: this.renderBin, ...opts });
    return session.start();
  }

  async openWarmSession(opts = {}) {
    const session = new ForgeWarmSession({ renderBin: this.renderBin, ...opts });
    return session.start();
  }

  cacheHash({ namespace = 'default', params = {}, inputs = [] } = {}) {
    const args = ['cache', 'hash', '--namespace', namespace, '--params', JSON.stringify(params)];
    if (inputs?.length) args.push('--inputs', inputs.map(String).join(','));
    return this._invoke(args);
  }

  cacheStore(inputPath, { key, namespace = 'default', params, root } = {}) {
    const args = ['cache', 'store', '--input', String(inputPath), '--namespace', namespace];
    if (key) args.push('--key', key);
    if (params !== undefined) args.push('--params', JSON.stringify(params));
    if (root) args.push('--root', String(root));
    return this._invoke(args);
  }

  cacheLookup(key, destPath = null, { root, overwrite = false } = {}) {
    const args = ['cache', 'lookup', '--key', key];
    if (destPath) args.push('-o', String(destPath));
    if (root) args.push('--root', String(root));
    if (overwrite) args.push('--overwrite');
    return this._invoke(args);
  }

  cacheStats({ root } = {}) {
    const args = ['cache', 'stats'];
    if (root) args.push('--root', String(root));
    return this._invoke(args);
  }

  cachePrune(maxBytes, { root } = {}) {
    const args = ['cache', 'prune', '--max-bytes', String(maxBytes)];
    if (root) args.push('--root', String(root));
    return this._invoke(args);
  }

  abGallery(manifestPath, outputHtmlPath, { overwrite = false } = {}) {
    const args = ['ab-gallery', '--manifest', String(manifestPath), '-o', String(outputHtmlPath)];
    if (overwrite) args.push('--overwrite');
    return this._invoke(args);
  }

  pipeEncode(stdinBuffer, opts) {
    const args = this._pipeEncodeArgs(opts);
    return this._invoke(args, { stdinBuffer: Buffer.isBuffer(stdinBuffer) ? stdinBuffer : Buffer.from(stdinBuffer) });
  }

  _appendPrismPolicyArgs(args, { metalfx = false, scale, autoVerify = true, verifyEvery, minPq, minMsssim, maxDe00P95, thaiOcr = false, expectedThai, thaiShield = true, antilag = true } = {}) {
    if (metalfx) args.push('--metalfx');
    if (scale !== undefined) args.push('--scale', String(scale));
    if (!autoVerify) args.push('--no-auto-verify');
    if (verifyEvery !== undefined) args.push('--verify-every', String(verifyEvery));
    if (minPq !== undefined) args.push('--min-pq', String(minPq));
    if (minMsssim !== undefined) args.push('--min-msssim', String(minMsssim));
    if (maxDe00P95 !== undefined) args.push('--max-de00-p95', String(maxDe00P95));
    if (thaiOcr) args.push('--thai-ocr');
    if (expectedThai !== undefined) args.push('--expected-thai', String(expectedThai));
    if (!thaiShield) args.push('--no-thai-shield');
    if (!antilag) args.push('--no-antilag');
  }

  prismCapabilities() {
    return this._invoke(['prism', 'capabilities']);
  }

  prismSyncIr(blendPath, glbPath, irPath, { frame = 1, engine = 'eevee', width, height, exportAnimations = true, overwrite = false } = {}) {
    const args = ['prism', 'sync-ir', String(blendPath), '--glb', String(glbPath), '--ir', String(irPath), '--frame', String(frame), '--engine', engine];
    if (width !== undefined) args.push('--width', String(width));
    if (height !== undefined) args.push('--height', String(height));
    if (!exportAnimations) args.push('--no-animations');
    if (overwrite) args.push('--overwrite');
    return this._invoke(args);
  }

  prismPreviewStills(inputPath, { outputPath, stillDir, contactSheet, tier = 'auto', width = 1080, height = 1920, angles, frames, cols, rows, tileWidth = 360, padding = 8, bg = '#0F172A', stillFormat = 'png', engine = 'eevee', samples = 16, shmMethod = 'bmp_mmap', allowLoopbackHttp = false, overwrite = false } = {}) {
    const args = [
      'prism', 'preview-stills', String(inputPath),
      '--tier', tier, '--width', String(width), '--height', String(height),
      '--tile-width', String(tileWidth), '--padding', String(padding), '--bg', bg,
      '--format', stillFormat, '--engine', engine, '--samples', String(samples), '--shm-method', shmMethod,
    ];
    if (outputPath) args.push('-o', String(outputPath));
    if (stillDir) args.push('--still-dir', String(stillDir));
    if (contactSheet) args.push('--contact-sheet', String(contactSheet));
    if (angles?.length) args.push('--angles', angles.join(','));
    if (frames?.length) args.push('--frames', frames.join(','));
    if (cols !== undefined) args.push('--cols', String(cols));
    if (rows !== undefined) args.push('--rows', String(rows));
    if (allowLoopbackHttp) args.push('--allow-loopback-http');
    if (overwrite) args.push('--overwrite');
    return this._invoke(args);
  }

  prismRenderWeb(htmlPath, outputPath, opts = {}) {
    const {
      width = 1080, height = 1920, fps = 30, frames = 30, start = 0,
      codec = 'h264', bitrate = 12000000, quality, transparent = false,
      overlayHtml, audio, subtitles, lang = 'tha', secondary, secondaryCodec,
      allowLoopbackHttp = false,
      overwrite = false,
    } = opts;
    const args = [
      'prism', 'render-web', String(htmlPath), '-o', String(outputPath),
      '--width', String(width), '--height', String(height),
      '--fps', String(fps), '--frames', String(frames), '--start', String(start),
      '--codec', codec, '--bitrate', String(bitrate),
    ];
    if (quality !== undefined) args.push('--quality', String(quality));
    if (transparent) args.push('--transparent');
    if (overlayHtml) args.push('--overlay-html', String(overlayHtml));
    if (audio) args.push('--audio', String(audio));
    if (subtitles) args.push('--subtitles', String(subtitles), '--lang', lang);
    if (secondary) args.push('--secondary', String(secondary));
    if (secondaryCodec) args.push('--secondary-codec', secondaryCodec);
    this._appendPrismPolicyArgs(args, opts);
    if (allowLoopbackHttp) args.push('--allow-loopback-http');
    if (overwrite) args.push('--overwrite');
    return this._invoke(args);
  }

  prismRenderBlender(blendPath, outputPath, opts = {}) {
    const {
      ir, engine = 'eevee', shmMethod = 'bmp_mmap', samples = 16,
      width = 1080, height = 1920, fps = 30, startFrame = 1, frames = 30,
      transparent = false, codec = 'h264', bitrate = 12000000, quality,
      overlayHtml, audio, subtitles, lang = 'tha', secondary, secondaryCodec,
      overwrite = false,
    } = opts;
    const args = [
      'prism', 'render-blender', String(blendPath), '-o', String(outputPath),
      '--engine', engine, '--shm-method', shmMethod, '--samples', String(samples),
      '--width', String(width), '--height', String(height),
      '--fps', String(fps), '--start-frame', String(startFrame), '--frames', String(frames),
      '--codec', codec, '--bitrate', String(bitrate),
    ];
    if (ir) args.push('--ir', String(ir));
    if (quality !== undefined) args.push('--quality', String(quality));
    if (transparent) args.push('--transparent');
    if (overlayHtml) args.push('--overlay-html', String(overlayHtml));
    if (audio) args.push('--audio', String(audio));
    if (subtitles) args.push('--subtitles', String(subtitles), '--lang', lang);
    if (secondary) args.push('--secondary', String(secondary));
    if (secondaryCodec) args.push('--secondary-codec', secondaryCodec);
    this._appendPrismPolicyArgs(args, opts);
    if (overwrite) args.push('--overwrite');
    return this._invoke(args);
  }

  prismComposite(blendPath, outputPath, opts = {}) {
    const {
      bgHtml, bgGlb, overlayHtml, secondaryMov,
      primaryCodec = 'h264', secondaryCodec = 'prores4444',
      width = 1080, height = 1920, fps = 30, startFrame = 1, frames = 15,
      engine = 'eevee', samples = 16, shmMethod = 'bmp_mmap', bitrate = 12000000, quality,
      audio, subtitles, lang = 'tha', overwrite = false,
    } = opts;
    const args = [
      'prism', 'composite', String(blendPath), '-o', String(outputPath),
      '--primary-codec', primaryCodec, '--secondary-codec', secondaryCodec,
      '--width', String(width), '--height', String(height),
      '--fps', String(fps), '--start-frame', String(startFrame), '--frames', String(frames),
      '--engine', engine, '--samples', String(samples), '--shm-method', shmMethod,
      '--bitrate', String(bitrate),
    ];
    if (bgHtml) args.push('--bg-html', String(bgHtml));
    if (bgGlb) args.push('--bg-glb', String(bgGlb));
    if (overlayHtml) args.push('--overlay-html', String(overlayHtml));
    if (secondaryMov) args.push('--secondary-mov', String(secondaryMov));
    if (quality !== undefined) args.push('--quality', String(quality));
    if (audio) args.push('--audio', String(audio));
    if (subtitles) args.push('--subtitles', String(subtitles), '--lang', lang);
    this._appendPrismPolicyArgs(args, opts);
    if (overwrite) args.push('--overwrite');
    return this._invoke(args);
  }
}

const _default = new SafariumForge();
export const capabilities = () => _default.capabilities();
export const runRecipe = (recipe, opts) => _default.runRecipe(recipe, opts);
export const validateRecipe = (recipe) => _default.validateRecipe(recipe);
export const remux = (i, o, opts) => _default.remux(i, o, opts);
export const inspect = (p, opts) => _default.inspect(p, opts);
export const image = (i, o, opts) => _default.image(i, o, opts);
export const audioProcess = (i, o, opts) => _default.audioProcess(i, o, opts);
export const crossfade = (a, b, o, opts) => _default.crossfade(a, b, o, opts);
export const silenceTrim = (i, o, opts) => _default.silenceTrim(i, o, opts);
export const waveform = (i, opts) => _default.waveform(i, opts);
export const synth = (o, opts) => _default.synth(o, opts);
export const splitMp3 = (i, d, opts) => _default.splitMp3(i, d, opts);
export const sheet = (i, o, opts) => _default.sheet(i, o, opts);
export const compare = (r, c, o, opts) => _default.compare(r, c, o, opts);
export const pq = (r, c, opts) => _default.pq(r, c, opts);
export const qa = (i, opts) => _default.qa(i, opts);
export const reframe = (i, o, opts) => _default.reframe(i, o, opts);
export const matte = (i, o, opts) => _default.matte(i, o, opts);
export const pipeEncode = (buf, opts) => _default.pipeEncode(buf, opts);
export const openPipeEncode = (opts) => _default.openPipeEncode(opts);
export const openRingEncode = (opts) => _default.openRingEncode(opts);
export const openWarmSession = (opts) => _default.openWarmSession(opts);
export const cacheHash = (opts) => _default.cacheHash(opts);
export const cacheStore = (i, opts) => _default.cacheStore(i, opts);
export const cacheLookup = (k, d, opts) => _default.cacheLookup(k, d, opts);
export const cacheStats = (opts) => _default.cacheStats(opts);
export const cachePrune = (m, opts) => _default.cachePrune(m, opts);
export const abGallery = (m, o, opts) => _default.abGallery(m, o, opts);
export const prismCapabilities = () => _default.prismCapabilities();
export const prismSyncIr = (b, g, ir, opts) => _default.prismSyncIr(b, g, ir, opts);
export const prismPreviewStills = (i, opts) => _default.prismPreviewStills(i, opts);
export const prismRenderWeb = (h, o, opts) => _default.prismRenderWeb(h, o, opts);
export const prismRenderBlender = (b, o, opts) => _default.prismRenderBlender(b, o, opts);
export const prismComposite = (b, o, opts) => _default.prismComposite(b, o, opts);

if (process.argv.includes('--self-check')) {
  const esds39 = new Uint8Array([
    0x03, 0x80, 0x80, 0x80, 0x22, 0x00, 0x00, 0x00,
    0x04, 0x80, 0x80, 0x80, 0x14, 0x40, 0x14, 0x00, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x05, 0x80, 0x80, 0x80, 0x02, 0x11, 0x90,
    0x06, 0x80, 0x80, 0x80, 0x01, 0x02,
  ]);
  const res = unwrapWebCodecsESDS(esds39);
  if (!res.wasBug302253 || res.audioSpecificConfigHex !== '1190') {
    throw new Error('ESDS self-check failed');
  }
  const pipe = htmlOverlayRecipe({ htmlPath: '/tmp/hud.html', outputPath: '/tmp/out.mp4', width: 1080, height: 1920, frames: 30 }).toJSON();
  if (pipe.$schema !== 'safarium-forge/graph-v1') throw new Error('Pipeline schema check failed');
  for (const fn of [prismCapabilities, prismSyncIr, prismPreviewStills, prismRenderWeb, prismRenderBlender, prismComposite, openRingEncode, openWarmSession, cacheHash, cacheStore, cacheLookup, cacheStats, cachePrune, abGallery]) {
    if (typeof fn !== 'function') throw new Error('Missing Wave 5/Prism export');
  }
  console.log(JSON.stringify({ selfCheck: 'ok', esdsAscHex: res.audioSpecificConfigHex, prismHelpers: 6, wave5Helpers: 8, renderBin: defaultRenderBin() }));
}
