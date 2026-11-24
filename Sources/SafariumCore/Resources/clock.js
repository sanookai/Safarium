// Safarium VirtualClock — injected as WKUserScript at document start.
// Replaces every time source with a deterministic virtual clock driven by window.__sfClock.seek(t).
(function () {
  'use strict';
  if (window.__sfClock) return;

  const RealDate = Date;
  const BASE = 1704067200000;            // 2024-01-01T00:00:00Z — fixed so runs are identical
  let vt = 0;                            // virtual time, ms
  let seqId = 0;

  // Real wall-clock timers captured before overriding (for harness timeouts).
  const realSetTimeout = window.setTimeout.bind(window);
  const realClearTimeout = window.clearTimeout.bind(window);
  const realRAF = window.requestAnimationFrame.bind(window);

  // ---- time sources -------------------------------------------------------
  function FakeDate(...a) {
    if (!new.target) return new RealDate(BASE + vt).toString();
    return a.length === 0 ? new RealDate(BASE + vt) : new RealDate(...a);
  }
  FakeDate.prototype = RealDate.prototype;
  FakeDate.now = () => BASE + vt;
  FakeDate.UTC = RealDate.UTC;
  FakeDate.parse = RealDate.parse;
  Object.defineProperty(FakeDate, 'name', { value: 'Date' });
  window.Date = FakeDate;
  try { Object.defineProperty(RealDate.prototype, 'constructor', { value: FakeDate, writable: true, configurable: true }); } catch (e) {}

  const perfNow = () => vt;
  try { Object.defineProperty(Performance.prototype, 'now', { value: perfNow, configurable: true, writable: true }); }
  catch (e) { performance.now = perfNow; }
  try { Object.defineProperty(document.timeline, 'currentTime', { get: () => vt, configurable: true }); } catch (e) {}

  // ---- timers -------------------------------------------------------------
  let timers = [];                       // {id, due, seq, fn, args, every}
  function addTimer(fn, delay, args, every) {
    if (typeof fn !== 'function') return 0;   // string handlers unsupported
    delay = Math.max(0, +delay || 0);
    const id = ++seqId;
    timers.push({ id, due: vt + delay, seq: id, fn, args, every: every ? Math.max(1, delay) : 0 });
    return id;
  }
  window.setTimeout = (fn, d, ...a) => addTimer(fn, d, a, false);
  window.setInterval = (fn, d, ...a) => addTimer(fn, d, a, true);
  window.clearTimeout = window.clearInterval = id => { timers = timers.filter(x => x.id !== id); };
  window.requestIdleCallback = fn => addTimer(() => fn({ didTimeout: false, timeRemaining: () => 50 }), 1, [], false);
  window.cancelIdleCallback = window.clearTimeout;

  // ---- rAF ----------------------------------------------------------------
  let rafQ = [];
  window.requestAnimationFrame = cb => { const id = ++seqId; rafQ.push([id, cb]); return id; };
  window.cancelAnimationFrame = id => { rafQ = rafQ.filter(x => x[0] !== id); };

  // ---- CSS / WAAPI animations --------------------------------------------
  const starts = new WeakMap();          // animation -> virtual start time
  function observeAnimations() {
    for (const a of document.getAnimations()) if (!starts.has(a)) starts.set(a, vt);
  }
  function seekAnimations() {
    for (const a of document.getAnimations()) {
      if (!starts.has(a)) starts.set(a, vt);
      const rate = a.playbackRate || 1;
      try { a.pause(); a.currentTime = (vt - starts.get(a)) * rate; } catch (e) {}
    }
  }

  // ---- <video> ---------------------------------------------------------------
  // takeSnapshot never contains the <video> layer, so every seek paints the frame into an overlay <canvas> placed over the video.
  //   mode 'element': video.currentTime = centre of the target frame, await 'seeked' (real-time deadline), drawImage(video)
  //   mode 'extract': native side decodes the frame (AVAssetImageGenerator) and replies with a PNG data URL
  // A page may still set window.__sfClock.videoSeekHook = async (video, tSec) => {} to take over completely.
  const videoMode = window.__sfVideoMode || 'none';
  const deadline = ms => new Promise(r => AbortSignal.timeout(ms).addEventListener('abort', () => r('timeout')));
  const once = (el, ev) => new Promise(r => el.addEventListener(ev, r, { once: true }));
  const bridge = () => window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.sfVideo;
  function videoSrc(v) {
    return v.currentSrc || v.src || (v.querySelector('source') && v.querySelector('source').src) || '';
  }
  function overlayFor(v) {
    let c = v.__sfCanvas;
    if (!c) { c = document.createElement('canvas'); c.setAttribute('data-sf-video-overlay', ''); v.after(c); v.__sfCanvas = c; }
    const cs = getComputedStyle(v);
    const fixed = cs.position === 'fixed';
    const r = v.getBoundingClientRect();
    c.style.position = fixed ? 'fixed' : 'absolute';
    c.style.left = (fixed ? r.left : v.offsetLeft) + 'px';
    c.style.top = (fixed ? r.top : v.offsetTop) + 'px';
    c.style.width = cs.width; c.style.height = cs.height; c.style.margin = '0';
    c.style.pointerEvents = 'none';
    c.style.display = cs.display === 'none' ? 'none' : 'block';
    for (const p of ['transform', 'transform-origin', 'opacity', 'filter', 'mix-blend-mode', 'clip-path', 'border-radius', 'object-fit', 'object-position', 'visibility', 'z-index'])
      c.style.setProperty(p, cs.getPropertyValue(p));
    return c;
  }
  function paint(v, source, w, h) {
    const c = overlayFor(v);
    if (c.width !== w || c.height !== h) { c.width = w; c.height = h; }
    c.getContext('2d').drawImage(source, 0, 0, w, h);
  }
  function waitForPresentedFrame(v, expectedPts, fps, maxWaitMs) {
    if (typeof v.requestVideoFrameCallback !== 'function') {
      return new Promise(r => realSetTimeout(r, 16));
    }
    const tol = 0.6 / fps;
    return new Promise(resolve => {
      let done = false;
      let handle = 0;
      const timer = realSetTimeout(() => {
        if (done) return;
        done = true;
        if (handle && typeof v.cancelVideoFrameCallback === 'function') v.cancelVideoFrameCallback(handle);
        resolve('timeout');
      }, maxWaitMs);
      const onFrame = (_now, meta) => {
        if (done) return;
        if (meta && typeof meta.mediaTime === 'number' && Math.abs(meta.mediaTime - expectedPts) <= tol) {
          done = true;
          realClearTimeout(timer);
          resolve('vfc');
          return;
        }
        handle = v.requestVideoFrameCallback(onFrame);
      };
      handle = v.requestVideoFrameCallback(onFrame);
    });
  }
  async function elementHook(v, tSec) {
    const src = videoSrc(v);
    if (!src) return;
    const b = bridge();
    if (!v.__sfFps) {
      const info = b ? await b.postMessage({ op: 'info', src, t: 0 }) : { fps: 30, t0: 0 };
      v.__sfFps = info.fps; v.__sfT0 = info.t0 || 0;
    }
    if (v.readyState < 2) {
      if (await Promise.race([once(v, 'loadeddata'), deadline(8000)]) === 'timeout')
        throw new Error('video load timeout (readyState ' + v.readyState + ', networkState ' + v.networkState + '): ' + src);
    }
    const fps = v.__sfFps;
    const maxK = isFinite(v.duration) ? Math.max(0, Math.round(v.duration * fps) - 1) : Infinity;
    const k = Math.min(maxK, Math.max(0, Math.floor(tSec * fps + 1e-3)));
    const expectedPts = (v.__sfT0 || 0) + k / fps;
    const target = expectedPts + 0.5 / fps;   // centre of frame k's display interval (t0 = pts of the first frame): immune to n/fps rounding below the pts
    if (v.__sfLastTarget === target && Math.abs(v.currentTime - target) < 1e-6 && v.readyState >= 2) {
      paint(v, v, v.videoWidth, v.videoHeight);
      return;
    }
    const framePresented = waitForPresentedFrame(v, expectedPts, fps, 500);
    const seeked = once(v, 'seeked');
    v.currentTime = target;
    if (await Promise.race([seeked.then(() => 'ok'), deadline(3000)]) === 'timeout') throw new Error('video seeked timeout at ' + target + ': ' + src);
    await framePresented;
    v.__sfLastTarget = target;
    paint(v, v, v.videoWidth, v.videoHeight);
  }
  async function extractHook(v, tSec) {
    const src = videoSrc(v);
    if (!src) return;
    const b = bridge();
    if (!b) throw new Error('video extract needs the native bridge (PageConfig.video = .extract)');
    const r = await b.postMessage({ op: 'frame', src, t: tSec });
    if (v.__sfK !== r.k || v.__sfSrc !== src) {
      const img = new Image(); img.src = r.url; await img.decode();
      paint(v, img, r.w || img.naturalWidth, r.h || img.naturalHeight);
      v.__sfK = r.k; v.__sfSrc = src;
    } else overlayFor(v);
  }
  async function seekVideos() {
    const hook = clock.videoSeekHook || (videoMode === 'element' ? elementHook : videoMode === 'extract' ? extractHook : null);
    if (!hook) return;
    for (const v of document.querySelectorAll('video')) await hook(v, vt / 1000);
  }

  // ---- stepping -----------------------------------------------------------
  const MAX_TIMER_RUNS = 100000;
  function runTimersUntil(target) {
    let runs = 0;
    for (;;) {
      let best = null;
      for (const t of timers) if (t.due <= target && (!best || t.due < best.due || (t.due === best.due && t.seq < best.seq))) best = t;
      if (!best) break;
      if (++runs > MAX_TIMER_RUNS) throw new Error('Safarium clock: >' + MAX_TIMER_RUNS + ' timers in one step (runaway setTimeout(0) loop?)');
      vt = Math.max(vt, best.due);
      if (best.every) { best.due += best.every; best.seq = ++seqId; }
      else timers = timers.filter(x => x !== best);
      observeAnimations();
      try { best.fn(...best.args); } catch (e) { reportError(e); }
    }
  }
  function reportError(e) { try { window.dispatchEvent(new ErrorEvent('error', { error: e, message: String(e && e.message || e) })); } catch (_) {} }

  async function flushMicrotasks() { for (let i = 0; i < 4; i++) await Promise.resolve(); }

  async function frame(target) {
    observeAnimations();
    runTimersUntil(target);
    vt = target;
    seekAnimations();
    const tSec = vt / 1000;
    if (typeof window.__seek === 'function') await window.__seek(tSec);
    if (window.__hf && typeof window.__hf.seek === 'function') await window.__hf.seek(tSec);
    // HyperFrames compositions expose their paused GSAP timelines here
    // (window.__timelines["main"]). Seeking them is the same operation as
    // window.__hf.seek without the HF runtime loaded.
    if (window.__timelines) {
      for (const key of Object.keys(window.__timelines)) {
        const tl = window.__timelines[key];
        if (!tl) continue;
        // GSAP's synchronous methods return the timeline itself; its .then()
        // means "playback finished", NOT "this seek finished". A separate
        // promise/thenable represents actual asynchronous work for this frame.
        if (typeof tl.pause === 'function') {
          const paused = tl.pause();
          if (paused !== tl && typeof paused?.then === 'function') await paused;
        }
        const drawn = typeof tl.seek === 'function' ? tl.seek(tSec, false)
                    : typeof tl.time === 'function' ? tl.time(tSec, false) : undefined;
        if (drawn !== tl && typeof drawn?.then === 'function') await drawn;
        // A thrown error or rejected completion rejects this seek, just like
        // __seek/__hf.seek. Page.evaluate owns the real-time deadline.
      }
    }
    const q = rafQ; rafQ = [];
    for (const [, cb] of q) { try { cb(vt); } catch (e) { reportError(e); } }
    await flushMicrotasks();
    seekAnimations();                    // animations created by timers / rAF callbacks
    await seekVideos();
  }

  // Timers due at virtual 0 (lottie loader, library bootstraps) run once the document has loaded, not at the first seek.
  function flushDue() { observeAnimations(); runTimersUntil(vt); }

  // First seek only: one rAF round at +5 ms virtual. Tickers such as GSAP's dispatch only once >= 1/240 s has elapsed,
  // so without this a seek(0) shows the un-rendered state. Virtual time returns to the requested target afterwards.
  const PREROLL_MS = 5;
  let prerolled = false;
  async function preroll() {
    prerolled = true;
    const q = rafQ; rafQ = [];
    if (!q.length) return;
    const back = vt;
    vt = back + PREROLL_MS;
    for (const [, cb] of q) { try { cb(vt); } catch (e) { reportError(e); } }
    await flushMicrotasks();
    vt = back;
  }

  const clock = {
    installed: true,
    flush() { flushDue(); },
    realSetTimeout,
    realClearTimeout,
    get now() { return vt; },
    /** Advance virtual time to tSec seconds; optional stepSec steps through intermediate frames (needed for libs with lag smoothing). */
    async seek(tSec, stepSec) {
      const target = tSec * 1000;
      if (!prerolled) await preroll();
      if (stepSec > 0) {
        const step = stepSec * 1000;
        while (vt + step < target - 1e-9) await frame(vt + step);
      }
      await frame(target);
      return vt / 1000;
    },
    async advance(dtSec, stepSec) { return clock.seek(vt / 1000 + dtSec, stepSec); },
    videoSeekHook: null,
  };
  Object.defineProperty(window, '__sfClock', { value: clock, enumerable: false });
})();
