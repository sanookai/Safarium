import WebKit

/// A detached WKWebView need not start its HTMLMediaElement loader, even for preload=metadata.
/// For scoped renderer WAV clips, expose a duration measured by the offline Web Audio decoder
/// (small clips) or by validated PCM sample extent (large clips), only for that element/source.
/// This does not play audio, synthesize media events or change readyState / networkState.
@MainActor enum WindowlessAudioMetadata {
    static func measure(in view: WKWebView, document: URL) {
        guard view.window == nil else { return }
        view.callAsyncJavaScript(measureScript, arguments: ["expected": document.absoluteString],
                                 in: nil, in: .page)
    }

    private static let measureScript = #"""
    if (!document.hidden || location.href.split('#')[0] !== expected.split('#')[0] ||
        document.querySelector('meta[http-equiv="content-security-policy" i]')) return;
    const nativeDuration = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'duration')?.get;
    if (!nativeDuration) return;
    const page = new URL(expected), clips = new Map();
    const capture = page.protocol === 'http:' && ['127.0.0.1','localhost','[::1]'].includes(page.hostname) &&
      !!document.querySelector('meta[name="hyperframes-studio-preview"][content="capture"]');
    function durationOf(el) { try { return nativeDuration.call(el); } catch { return NaN; } }
    function source(el) {
      try {
        if (el.srcObject || el.error) return;
        let raw = el.getAttribute('src');
        if (!raw) {
          const sources = el.querySelectorAll(':scope > source[src]');
          if (sources.length !== 1) return;  // do not guess between alternate tracks
          raw = sources[0].getAttribute('src');
        }
        if (!raw) return;
        const u = new URL(raw, document.baseURI);
        if (el.currentSrc && el.currentSrc !== u.href) return;
        if (!['http:', 'file:', 'safarium-asset:'].includes(u.protocol) ||
            u.protocol !== page.protocol || u.host !== page.host || u.username || u.password ||
            !/\.wave?$/i.test(u.pathname) || u.hash) return;
        if (u.protocol === 'file:' && !u.pathname.startsWith(new URL('.', page).pathname)) return;
        return u.href;
      } catch { return; } // One malformed source is not a failure of the document's other clips.
    }
    function staticCaptureAsset(el, url) {
      try {
        const raw = el.getAttribute('src')?.replace(/^\.\//, '');
        return capture && !!el.closest('[data-composition-id]') && raw?.startsWith('assets/') &&
          !/[%\\?#]/.test(raw) && raw.split('/').every(s => s && s !== '.' && s !== '..') &&
          new URL(raw, page).href === url;
      } catch { return false; }
    }
    function track(el, url) {
      let changed = false;
      const stop = () => {
        changed = true; observer.disconnect();
        el.removeEventListener('emptied', emptied); el.removeEventListener('loadstart', stop);
        window.removeEventListener('pagehide', stop);
      };
      const emptied = () => {
        try {
          // HF resets the detached, already-empty player during startup. No native resource
          // was selected in that case. A changed declaration, or an actual loadstart, still
          // invalidates even this static asset (including a same-turn change away and back).
          if (!observer.takeRecords().length && !el.currentSrc && el.readyState === 0 &&
              staticCaptureAsset(el, url) && source(el) === url) return;
        } catch {}
        stop();
      };
      const observer = new MutationObserver(stop);
      observer.observe(el, {subtree:true, childList:true, attributes:true, attributeFilter:['src','type','media']});
      el.addEventListener('emptied', emptied); el.addEventListener('loadstart', stop);
      window.addEventListener('pagehide', stop, {once:true});
      return {el, stop, installed:false, current() {
        try {
          // takeRecords also detects changing src away and back in the same JS turn.
          if (!changed && !observer.takeRecords().length && el.isConnected && source(el) === url) return true;
        } catch {}
        if (!changed) stop();
        return false;
      }};
    }
    for (const el of document.querySelectorAll('audio[data-duration]')) {
      try {
        if (!(el instanceof HTMLAudioElement) || !Number.isNaN(durationOf(el)) || Object.hasOwn(el, 'duration')) continue;
        const u = source(el); if (!u) continue;
        if (!clips.has(u)) {
          if (clips.size >= 8) continue;
          clips.set(u, []);
        }
        clips.get(u).push(track(el, u));
      } catch {
        // A changing or unobservable element retains its own native getter.
      }
    }
    if (!clips.size) return;

    // Small clips: bound encoded and decoded data; use the decoder's duration, at the source rate.
    function sampleRate(bytes) {
      if (bytes.byteLength < 44) return;
      const d = new DataView(bytes), tag = i => d.getUint32(i), u32 = i => d.getUint32(i, true);
      if (tag(0) !== 0x52494646 || tag(8) !== 0x57415645 || u32(4) + 8 !== bytes.byteLength) return;
      let rate = 0, align = 0, channels = 0, dataBytes = 0;
      for (let p = 12; p + 8 <= bytes.byteLength;) {
        const k = tag(p), size = u32(p + 4), start = p + 8;
        if (size > bytes.byteLength - start) return;
        if (k === 0x666d7420) {
          if (rate || size < 16 || ![1, 3].includes(d.getUint16(start, true))) return;
          channels = d.getUint16(start + 2, true); rate = u32(start + 4);
          align = d.getUint16(start + 12, true); const bits = d.getUint16(start + 14, true);
          if (channels < 1 || channels > 8 || rate < 8000 || rate > 192000 ||
              ![8, 16, 24, 32].includes(bits) || align !== channels * bits / 8 || u32(start + 8) !== rate * align) return;
        } else if (k === 0x64617461) dataBytes += size;
        p = start + size + size % 2;
      }
      if (align && dataBytes > 0 && !(dataBytes % align) && dataBytes / align * channels * 4 <= 16 * 1024 * 1024) return rate;
    }
    // A large clip needs exactly one terminal data chunk after an ordinary PCM fmt. Conservatively
    // decline wavl/RF64/compression, metadata beyond the prefix, or anything following the samples.
    function pcmExtent(prefix, total) {
      if (prefix.byteLength < 44) return;
      const d = new DataView(prefix), tag = p => d.getUint32(p), u16 = p => d.getUint16(p, true), u32 = p => d.getUint32(p, true);
      if (tag(0) !== 0x52494646 || tag(8) !== 0x57415645 || u32(4) + 8 !== total) return;
      let rate = 0, align = 0;
      for (let p = 12, count = 0; p + 8 <= prefix.byteLength && count++ < 64;) {
        const id = tag(p), n = u32(p + 4), a = p + 8, pad = n % 2, next = a + n + pad;
        if (next > total) return;
        if (id === 0x64617461) { // data
          if (!rate || !n || n % align || next !== total) return;
          return {frames: n / align, rate, tailBytes: align + pad, pad};
        }
        if (next > prefix.byteLength) return;
        if (id === 0x666d7420) { // fmt
          if (rate || n < 16) return;
          const format = u16(a), channels = u16(a + 2), bits = u16(a + 14);
          rate = u32(a + 4); align = u16(a + 12);
          if (channels < 1 || channels > 8 || rate < 8000 || rate > 192000 || ![8,16,24,32].includes(bits) ||
              align !== channels * bits / 8 || u32(a + 8) !== rate * align) return;
          if (format === 1) {
            if (!(n === 16 || (n === 18 && u16(a + 16) === 0))) return;
          } else if (format === 0xfffe) {
            // WAVEFORMATEXTENSIBLE: verify the entire KSDATAFORMAT_SUBTYPE_PCM GUID, not just wFormatTag.
            if (n !== 40 || u16(a + 16) !== 22 || !u16(a + 18) || u16(a + 18) > bits ||
                u32(a + 24) !== 1 || tag(a + 28) !== 0x00001000 || tag(a + 32) !== 0x800000aa ||
                tag(a + 36) !== 0x00389b71) return;
            const mask = u32(a + 20);
            if (mask && (mask > 0x3ffff || mask.toString(2).replace(/0/g, '').length !== channels)) return;
          } else return;
        } else if (id === 0x4c495354) { // LIST/INFO only (LIST/wavl could itself contain samples)
          if (n < 4 || tag(a) !== 0x494e464f) return;
        } else if (![0x4a554e4b, 0x50414420, 0x62657874].includes(id)) return; // JUNK, PAD , bext
        p = next;
      }
    }
    const controller = new AbortController(), abort = () => controller.abort();
    // The browser's deadline remains independent of renderer-owned JS animation timers.
    const timeout = AbortSignal.timeout(2500), perClip = 4 * 1024 * 1024, prefixSize = 4096;
    timeout.addEventListener('abort', abort, {once:true});
    let remaining = 8 * 1024 * 1024;
    window.addEventListener('pagehide', abort, { once: true });
    const discard = async r => { if (r.body) await r.body.cancel(); };
    const integer = s => s !== null && /^\d+$/.test(s) && Number.isSafeInteger(+s) ? +s : undefined;
    async function readExactly(r, length) {
      if (!r.body || length > remaining) { await discard(r); return; }
      const reader = r.body.getReader(), bytes = new Uint8Array(length); let offset = 0;
      for (;;) {
        const {value, done} = await reader.read(); if (done) break;
        remaining -= value.byteLength;
        if (value.byteLength > length - offset) { await reader.cancel(); return; }
        bytes.set(value, offset); offset += value.byteLength;
      }
      if (offset === length) return bytes.buffer;
    }
    async function measure(url, allowsStatic) {
      // Probe with a bounded GET. In particular, do not issue an un-ranged HEAD for large
      // assets: some static servers implement HEAD by reading the whole file and dropping the body.
      let validators;
      const strong = () => validators.etag !== null && /^"[\x21\x23-\x7e\x80-\xff]*"$/.test(validators.etag);
      const request = async (method, headers = {}) => {
        const r = await fetch(url, {method, headers, mode:'same-origin', credentials:'omit', redirect:'error',
          cache:'no-store', referrerPolicy:'no-referrer', signal:controller.signal});
        const encoding = r.headers.get('Content-Encoding'), e = r.headers.get('ETag'), m = r.headers.get('Last-Modified');
        if (r.redirected || r.url !== url || (encoding && encoding.toLowerCase() !== 'identity') ||
            (validators && (validators.etag !== e || validators.modified !== m))) { await discard(r); return; }
        validators ??= {etag:e, modified:m}; return r;
      };
      let total;
      const readRange = async (r, start, end) => {
        if (!r) return;
        const cr = /^bytes (\d+)-(\d+)\/(\d+)$/i.exec(r.headers.get('Content-Range') ?? '');
        const size = integer(r.headers.get('Content-Length')), t = cr && integer(cr[3]);
        if (r.status !== 206 || !cr || t === undefined || t < 44 || t > 0xffffffff + 8 ||
            (total !== undefined && t !== total) || integer(cr[1]) !== start || start >= t ||
            integer(cr[2]) !== Math.min(end, t - 1) || size !== Math.min(end, t - 1) - start + 1) {
          await discard(r); return;
        }
        total = t; return await readExactly(r, size);
      };
      const nextRange = async (start, end) => {
        if (!strong()) return;
        const headers = {Range: `bytes=${start}-${end}`, 'If-Range': validators.etag};
        return await readRange(await request('GET', headers), start, end);
      };
      const smallBody = async n => {
        const r = await request('GET'); if (!r) return;
        if (r.status !== 200 || integer(r.headers.get('Content-Length')) !== n) { await discard(r); return; }
        return await readExactly(r, n);
      };
      const first = await request('GET', {Range:`bytes=0-${prefixSize-1}`}); if (!first) return;
      let bytes;
      if (first.status === 200) {
        // Ignored range: discard it. Preserve the legacy small decoder only if an independent
        // HEAD confirms a complete, small representation. We cancel an ignored range; the
        // 206 payload bound is not a bound on bytes such a server may already have put on the wire.
        const n = integer(first.headers.get('Content-Length')); await discard(first);
        if (!window.OfflineAudioContext || n === undefined || n < 44 || n > Math.min(perClip, remaining)) return;
        const h = await request('HEAD'); if (!h || h.status !== 200 || integer(h.headers.get('Content-Length')) !== n) return;
        bytes = await smallBody(n);
      } else {
        const prefix = await readRange(first, 0, prefixSize - 1); if (!prefix) return;
        if (total > perClip) {
          const pcm = pcmExtent(prefix, total); if (!pcm) return;
          if (!strong()) {
            // HF's local static capture server supplies no validators. Only for its declared
            // literal assets/ clip, derive from ONE verified 206 representation: its Content-Range
            // total, RIFF size, fmt and unique, unpadded terminal data extent agree. This is
            // header metadata, not playback or a tail probe. No weak/date-based stitching.
            if (allowsStatic && validators.etag === null && validators.modified === null && pcm.pad === 0)
              return {seconds: pcm.frames / pcm.rate, staticOnly:true};
            return;
          }
          // Only an unchanged strong HTTP entity tag binds this second 206 to the first.
          const tail = await nextRange(total - pcm.tailBytes, total - 1);
          if (tail && (!pcm.pad || new Uint8Array(tail)[tail.byteLength - 1] === 0)) return {seconds: pcm.frames / pcm.rate};
          return;
        }
        if (!window.OfflineAudioContext || total - prefix.byteLength > remaining) return;
        if (prefix.byteLength === total) bytes = prefix;
        else if (!strong()) {
          // Decode ONE complete small body rather than combining unversioned ranges.
          if (total > remaining) return;
          bytes = await smallBody(total);
        }
        else {
          const rest = await nextRange(prefix.byteLength, total - 1); if (!rest) return;
          const all = new Uint8Array(total); all.set(new Uint8Array(prefix)); all.set(new Uint8Array(rest), prefix.byteLength);
          bytes = all.buffer;
        }
      }
      const rate = bytes && sampleRate(bytes); if (!rate || controller.signal.aborted) return;
      return {seconds: (await new OfflineAudioContext(1, 1, rate).decodeAudioData(bytes)).duration};
    }
    try {
      for (const [url, elements] of clips) {
        if (controller.signal.aborted || remaining <= 0) break;
        try {
          const result = await measure(url, elements.some(item => staticCaptureAsset(item.el, url)));
          const duration = result?.seconds;
          if (controller.signal.aborted || !Number.isFinite(duration) || duration <= 0) continue;
          for (const item of elements) {
            const {el} = item;
            try {
              if (!item.current() || (result.staticOnly && !staticCaptureAsset(el, url)) ||
                  !Number.isNaN(durationOf(el)) || Object.hasOwn(el, 'duration')) continue;
              Object.defineProperty(el, 'duration', {configurable: true, get() {
                const native = durationOf(this);
                return Number.isNaN(native) && this === el && item.current() &&
                  (!result.staticOnly || staticCaptureAsset(el, url)) ? duration : native;
              }});
              item.installed = true;
            } catch { /* Do not let an element changed by page JS suppress its siblings. */ }
          }
        } catch (_) { /* Unreadable/unsupported sources keep the browser's real duration. */ }
      }
    } finally {
      for (const items of clips.values()) for (const item of items) if (!item.installed) item.stop();
      timeout.removeEventListener('abort', abort); window.removeEventListener('pagehide', abort);
    }
    """#
}
