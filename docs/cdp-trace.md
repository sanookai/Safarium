---
tags: [safarium, cdp, puppeteer, hyperframes, trace, reference]
note_type: reference
created: 2026-11-21
updated: 2026-11-21
---

# CDP trace: puppeteer-core 25.18.1 and HyperFrames 0.9.65 (task S1)

Real Chrome traffic captured by a transparent pipe proxy ("fake chrome"). Goal: the exact list of CDP the Safarium shim (`webkit-cdp`, WKWebView) must answer. Raw logs: `Projects/Safarium/fixtures/cdp-trace/*.jsonl`.

## 0. Summary (read this first)

- The env override works: `HYPERFRAMES_BROWSER_PATH=<exe>` is honoured by `render`, `check` and `validate`. Every launch (3-4 per `render`) went through the proxy. `lint` never starts a browser.
- HF launches Chrome with `pipe: true`, so the shim must speak `--remote-debugging-pipe` (NUL-terminated JSON, fd 3 = client to browser, fd 4 = browser to client). Confirmed in all logs.
- **macOS never runs the beginFrame probe.** The beginFrame mode is chosen only when `process.platform === "linux"` (`chunk-ERYYOWWF.js:1736`). On macOS the HF capture modes are `drawelement` (fast) or `screenshot`. The probe was captured by a synthetic run (section 7).
- **Default macOS mode = `drawelement`** when Chrome has `canvas.drawElementImage` (Chrome 152 headless shell does). HF feature-detects it with one `Runtime.callFunctionOn` (`typeof ctx.drawElementImage === "function"`, `chunk-ERYYOWWF.js:8050`). WKWebView does not have it, so HF falls back to screenshot by itself (`deGateReason: unsupported_chrome`). Env `PRODUCER_FORCE_SCREENSHOT=true` or `PRODUCER_EXPERIMENTAL_FAST_CAPTURE=false` also avoids it. Compositions with CSS animation fall back to screenshot even on real Chrome.
- Minimal shim for screenshot mode (section 5) = about 25 methods. 3 of them may fail without breaking puppeteer (`WebMCP.enable`, `Network.enable`, `Page.createIsolatedWorld`); every other one must return `{}` or a real result (tested by fault injection, section 6).
- Fetch is needed only for: `<video>` in a render (frame transport) and `hyperframes check` (bundled GSAP served from disk). A plain render of a page with no `<video>` never uses Fetch.

## 1. Method and environment

| Item | Value |
|---|---|
| Real browser | `~/.cache/hyperframes/chrome/chrome-headless-shell/mac_arm-152.0.7977.30/...` (Chrome for Testing 152.0.7977.30, `HeadlessChrome/152.0.7977.30`). Pick's Google Chrome and Safari were not touched; headless only. |
| puppeteer-core | 25.18.1 (npx cache of hyperframes 0.9.65) |
| HyperFrames | 0.9.65 (`~/.npm/_npx/702923228c2ce1e6`) |
| Proxy | Node script, spawns the real shell with the same argv, relays fd 3/fd 4 byte-for-byte, logs each message. Scratch: `<scratch>` (scratch may be cleared). Also supports fault injection (reply `-32601` to chosen methods). |
| Log record | `t` ms since launch, `launch` pid, `dir` c2b (client to browser) / b2c, `kind` request/response/event, `id`, `sessionId`, `method`, trimmed `params`/`result` (strings over 200 chars become `<str len=N head=...>`), `rttMs`. First line of each launch = `kind:"launch"` with the full argv. |
| Composition | 1280x720, 2 s, 30 fps, one `<audio>` (sine wav), one GSAP tween (GSAP 3.15 from jsdelivr, inlined by HF), one CSS `@keyframes` animation. Variants: `nocss` (no keyframes), `video` (adds a `<video>` mp4). |
| Gotchas hit | (1) HF takes a per-user render lock; another AI's render was running, so runs used `HYPERFRAMES_RENDER_LOCK_DIR=<private dir>`. (2) HF runs `<exe> --version` first; the proxy must pass non-pipe invocations straight through. (3) `PRODUCER_FORCE_SCREENSHOT` must be the string `true` (the code compares to `"false"`/envBool). |

### Run list (fixtures)

| File | What |
|---|---|
| `01-puppeteer-plain` | puppeteer-core 25.18.1 `launch({pipe:true})` newPage, goto data: URL, evaluate, screenshot png, close |
| `02-hf-default-mp4` | HF render mp4, default mode, composition WITH css animation (falls back to screenshot capture) |
| `03-hf-default-nocss-mp4` | same, no css animation: `drawelement` capture mode actually used |
| `04-hf-force-screenshot-mp4` | `PRODUCER_FORCE_SCREENSHOT=true` |
| `05-hf-alpha-webm`, `06-hf-alpha-mov` | transparent render (`--format webm` / `--format mov`, ProRes 4444 verified yuva444p12le) |
| `07-hf-check` | `hyperframes check` |
| `09-hf-validate` | `hyperframes validate` (no file `08`: `hyperframes lint` launches no browser, 0 errors) |
| `10-hf-video-fetch-mp4` | composition with `<video>` (default mode = drawelement): Fetch frame transport |
| `11-beginframe-probe-replica-macos` | replica of HF beginFrame probe against real macOS shell (crashes the browser) |
| `12-hf-fake-linux-beginframe-attempt` | whole render with `process.platform` forced to `linux` (beginframe mode attempted, real shell dies, HF falls back) |
| `13`, `14-...probe-fail-at-enable / at-beginframe` | same Linux-forced run, but the proxy answers `-32601` to `HeadlessExperimental.enable` / `.beginFrame` |

Runs 12-14 are synthetic (platform faked in Node, the real macOS shell does not support BeginFrameControl). They show what HF does, not what Linux Chrome sends on success.

## 2. Launch sequence and args

`hyperframes render` starts the browser executable 3 times (`--version`, GPU probe, capture); run 02 (css-animation fallback) has a 4th launch, and the Linux-forced run 12 has a 4th (the beginFrame probe launch). Each is a separate process, so the shim binary must be cheap to start.

| # | Purpose | argv notes | CDP |
|---|---|---|---|
| 1 | `<exe> --version` | no `--remote-debugging-pipe`. Must exit 0 and print a string with a version (real: `Google Chrome for Testing 152.0.7977.30`). HF extracts the major number. | none |
| 2 | GPU probe (`browserGpuMode` auto) | puppeteer defaults + `--enable-webgl --ignore-gpu-blocklist --use-gl=angle --use-angle=metal --enable-gpu-rasterization --hyperframes-owned-browser --remote-debugging-pipe --user-data-dir=<tmp>` | newPage + one `Runtime.callFunctionOn` that creates a canvas and reads the WebGL renderer, then `Browser.close`. Log line: `browserGpuMode probe -> hardware (...)` |
| 3 | render capture | 68 args (below) | full session (sections 3-4) |
| 4 | run 02 only: second 68-arg launch after the capture (1 s, 10 `callFunctionOn`, 7 `evaluate`, no screenshots), purpose inferred (a verification page, `createStaticVerificationPage`), not confirmed | same | newPage + navigate + a few evals |

Render launch (run 04, abbreviated; full argv in the `kind:"launch"` line): puppeteer defaults (`--allow-pre-commit-input --disable-background-networking ... --enable-automation ... --headless=new --hide-scrollbars --mute-audio --disable-extensions about:blank`) plus `--disable-features=...,AudioServiceOutOfProcess,IsolateOrigins,site-per-process,BackForwardCache,IntensiveWakeUpThrottling`, `--enable-features=PdfOopif,CanvasDrawElement`, `--enable-webgl --ignore-gpu-blocklist --use-gl=angle --use-angle=metal --enable-gpu-rasterization`, `--font-render-hinting=none --disable-lcd-text --force-color-profile=srgb --force-device-scale-factor=1 --window-size=1280,720`, `--disable-background-media-suspend --disable-component-update --disable-domain-reliability --disable-print-preview --no-pings --force-gpu-mem-available-mb=8192 --disk-cache-size=268435456`, `--autoplay-policy=no-user-gesture-required --enable-unsafe-webgpu --disable-partial-raster --hyperframes-owned-browser --remote-debugging-pipe --user-data-dir=<tmp>/puppeteer_dev_chrome_profile-XXXX`. No `--no-sandbox` on macOS. Env keys named HYPERFRAMES/PRODUCER/HF_ are NOT forwarded to Chrome (hfEnvKeys empty); do not rely on env inside the shim, use a file or argv.

Plain puppeteer (run 01): 35 args, same base set + `--remote-debugging-pipe --user-data-dir=`. The shim should ignore all Chrome flags except `--remote-debugging-pipe`, `--user-data-dir`, `--window-size`, `--headless` and the URL `about:blank`.

When HF would use beginFrame (Linux only) it adds `--deterministic-mode --enable-begin-frame-control --disable-new-content-rendering-timeout --run-all-compositor-stages-before-draw --disable-threaded-animation --disable-threaded-scrolling --disable-checker-imaging --disable-image-animation-resync --enable-surface-synchronization`; on fallback it strips those and adds `--disable-partial-raster` (`chunk-ERYYOWWF.js:1429-1442`, `1995-2010`).

## 3. Handshake (identical for puppeteer-core alone and HF; ids restart at 1 per launch)

Order observed (runs 01 and 04; `S0` = browser session, no sessionId; `Sx` = flat sessions):

1. `Target.setDiscoverTargets {discover:true, filter:[{}]}` -> `{}`. Events right after: `Target.targetCreated` for each existing target: the initial page (`type:"page"`, url about:blank), a `type:"tab"` target, and two `type:"browser"` targets. Puppeteer 25 expects the `tab` type to exist.
2. `Target.setAutoAttach {waitForDebuggerOnStart:true, flatten:true, autoAttach:true, filter:[{type:"page",exclude:true},{}]}` -> `{}`. Events: `Target.targetInfoChanged`, `Target.attachedToTarget {sessionId, targetInfo{targetId,type:"tab",attached:true,...}, waitingForDebugger}`.
3. On the tab session: `Target.setAutoAttach` (same params, filter `[{}]`) + `Runtime.runIfWaitingForDebugger` -> then the page target is auto-attached (`Target.attachedToTarget` with `type:"page"`), same two calls repeat on the page session. Every auto-attached target waits for `runIfWaitingForDebugger`.
4. `Browser.getVersion` -> `{protocolVersion:"1.3", product:"HeadlessChrome/152.0.7977.30", revision, userAgent, jsVersion}` (HF logs `product`; puppeteer `browser.version()` returns `product`).
5. `Target.createTarget {url:"about:blank"}` -> `{targetId}`; before the response, events `targetCreated(tab)`, `attachedToTarget(tab session)`, `targetCreated(page)`, `targetInfoChanged`, then `attachedToTarget(page session)`. The same 2 setup calls run on each new session (`setAutoAttach`, `runIfWaitingForDebugger`).
6. Page-session init burst (puppeteer 25.18.1), sent without waiting for each answer: `Network.enable`, `Page.enable`, `Page.getFrameTree`, `Page.setLifecycleEventsEnabled {enabled:true}`, `Runtime.enable`, `Audits.enable`, `Performance.enable`, `Log.enable`, `WebMCP.enable` (new in this Chrome/puppeteer, may fail).
7. Events puppeteer waits for during init: `Page.lifecycleEvent` (name `init`/`commit`/`DOMContentLoaded`/`load`/`networkAlmostIdle`/`networkIdle`; frame id + loaderId + timestamp), `Runtime.executionContextCreated` for the default context (`auxData.isDefault:true`, `type:"default"`, `frameId`), `Page.frameStoppedLoading`.
8. `Page.addScriptToEvaluateOnNewDocument {source:"//# sourceURL=pptr:internal", worldName:"__puppeteer_utility_world__25.18.1"}` -> `{identifier}`; `Page.createIsolatedWorld {frameId, worldName, grantUniveralAccess:true}` (sic, typo in protocol) -> `{executionContextId}` plus an `executionContextCreated` event with `auxData.type:"isolated"` and that world name.
9. `Network.enable {maxTotalBufferSize, maxResourceBufferSize}`, then 0-N `Page.addScriptToEvaluateOnNewDocument` (HF adds 6-7: `__name` shim, media helpers, canvas preserveDrawingBuffer patch, accelerated-canvas trackers, root props). Each -> `{identifier:"N"}`.
10. `Emulation.setDeviceMetricsOverride {mobile:false,width,height,deviceScaleFactor,screenOrientation{angle,type}}`, `Emulation.setTouchEmulationEnabled {enabled:false}` -> `{}`. (HF passes `defaultViewport:null` but sets its own viewport = 1280x720 DSF 1.)
11. HF only: `Target.attachToTarget {targetId, flatten:true}` -> `{sessionId}` (second session on the same page, used for `Page.captureScreenshot`; 3 times per capture launch (run 02: count per launch not re-verified)). The new session gets its own `Runtime.enable` and replays `executionContextCreated` for existing contexts (ids 2, 1 in that order).
12. `Page.navigate {url, frameId}` -> `{frameId, loaderId, isDownload:false}`. Event order after it: `Page.frameStartedNavigating`, `Page.frameStartedLoading`, `Network.requestWillBeSent` (Document), `Network.requestWillBeSentExtraInfo`, `Network.responseReceivedExtraInfo`, `Network.responseReceived`, [response to navigate], `Runtime.executionContextsCleared`, `Page.lifecycleEvent init`, `Page.frameNavigated {frame{id,loaderId,url,securityOrigin,mimeType,...}}`, `Target.targetInfoChanged` (title/url), `Runtime.executionContextCreated` x2 (default ctx new id + utility world), `Network.dataReceived`/`loadingFinished`, `Page.domContentEventFired` + `lifecycleEvent DOMContentLoaded`, `Page.loadEventFired` + `lifecycleEvent load`, `Page.frameStoppedLoading`, then paint lifecycle events (`firstPaint`, `firstContentfulPaint`, ...).
    - HF loads the page from a local HTTP server (`http://localhost:<port>/index.html`, ~1 MB because runtime + fonts are inlined; audio fetched with `Range: bytes=0-`). The shim's WebView must load real http.
    - puppeteer `goto` waits for the `load` (or `DOMContentLoaded`) lifecycle event of the new loaderId; `evaluate` needs the default `executionContextId` from `executionContextCreated` (HF passes `contextId:3`, so context ids must be stable per navigation and announced before first use).
13. Close: `Browser.close` -> `{}`, then `Target.targetInfoChanged`, `Target.detachedFromTarget {sessionId,targetId}`, `Target.targetDestroyed`; the process must exit (puppeteer waits for the child `exit`; HF force-kills with SIGKILL if close hangs). HF also calls `Target.closeTarget {targetId}` -> `{success:true}`, `Target.detachFromTarget {sessionId}`, `SystemInfo.getProcessInfo` -> `{processInfo:[{type,id,cpuTime}...]}` (used for leak/CPU accounting; any array ok, unverified whether empty is accepted).

## 4. Per-mode request tables

Counts are for the render launch only (the capture Chrome), 60 frames at 30 fps. `cFn` = `Runtime.callFunctionOn`, `eval` = `Runtime.evaluate`.

| Method | 01 plain | 04 force screenshot | 02 default + css anim | 03 default drawelement | 05/06 alpha | 10 + `<video>` | 07 check | 09 validate |
|---|---|---|---|---|---|---|---|---|
| Handshake methods (section 3) | 1x | 1x | 1x | 1x | 1x | 1x | 1x | 1x |
| `Runtime.callFunctionOn` | 1 | 256 | 259 | 126 | 260 | 586 | 200 | 60 |
| `Runtime.evaluate` | 0 | 7 | 7 | 15 | 7 | 15 | 3 | 1 |
| `Page.captureScreenshot` | 1 | 60 | 60 | 9 (not frames) | 60 | 9 | 0 | 5 |
| `Emulation.setDefaultBackgroundColorOverride` | 0 | 0 | 0 | 0 | 1 | 0 | 0 | 10 |
| `Runtime.addBinding` / `Runtime.bindingCalled` events | 0 | 0 | 0 | 1 / 60 | 0 | 1 / 60 | 2 / 0 | 2 / 0 |
| `Fetch.enable` / `fulfillRequest` | 0 | 0 | 0 | 0 | 0 | 2 / 64 | 1 / 1 | 0 |
| `Target.attachToTarget` | 0 | 3 | 3 | 3 | 3 | 5 | 1 | 0 |
| `Page.navigate` | 1 | 1 | 1 | 2 | 1 | 2 | 1 | 1 |
| Capture time (ms in launch) | 440 | ~3200 | ~5100 | ~2500 | ~3300 | ~2400 | 940 | 4800 |

Other methods seen: `DOM.describeNode`, `DOM.resolveNode`, `Runtime.releaseObject` (only `check`/`validate`: puppeteer ElementHandle ops; shapes in section 6), `Target.attachToTarget`. Counts for the whole run (all 4 launches) are in the jsonl.

### 4.1 Screenshot mode (what the shim must support; run 04)

Steps after the handshake:
1. `eval` x7 + `cFn` x~15: page readiness probes (`window.__hfFlushSync?.()`, `window.__hfStartupError ...` polling until `true`, `document.fonts?.ready`, `__tailwindReady`, image/video pending checks, composition root queries, reference-background sampling). All are plain JS with `returnByValue:true, awaitPromise:true, userGesture:true`; response `{result:{type,value[,description]}}`. Page-side promises must be awaited.
2. Per frame (60x), strictly serial, ~0.4 ms each except the screenshot:
   - `cFn` seek `(t, opts) => window.__hf.seek(...)` -> boolean
   - `cFn` async media-decode wait (arg `15000`) -> `[]`
   - `cFn` async `__hfWaitForSeekCompletion` -> undefined
   - `cFn` async colour-grading hook -> undefined
   - `Page.captureScreenshot` on the SECOND session (`attachToTarget`), params exactly: `{format:"jpeg", quality:100, fromSurface:true, captureBeyondViewport:false, optimizeForSpeed:true, clip:{x:0,y:0,width:1280,height:720,scale:1}}` -> `{data:<base64 jpeg>}`. Round trip 27-42 ms on real Chrome.
   - mp4 uses jpeg; alpha uses png (below).
3. After the last frame: `cFn` (motion-blur report), `SystemInfo.getProcessInfo`, `Target.detachFromTarget`, `Target.closeTarget`, `Browser.close`.
4. Required from a response: the `data` field must decode to the exact `clip` size. HF checks nothing else about the image except size/decodability (unverified for size mismatch).

Argument shapes: `Runtime.callFunctionOn {functionDeclaration, executionContextId, arguments:[{value}...], returnByValue:true, awaitPromise:true, userGesture:true}` (no `objectId`, no `unserializableValue` seen in render). `Runtime.evaluate {expression, contextId, returnByValue, awaitPromise, userGesture}`. No `exceptionDetails` was ever returned in these runs; the shim still has to map JS exceptions to `exceptionDetails` (puppeteer throws on it; untested here).

### 4.2 Alpha mode (runs 05, 06, 09)

Same as 4.1 plus, once before the first frame on the capture session: `Emulation.setDefaultBackgroundColorOverride {color:{r:0,g:0,b:0,a:0}}` -> `{}`; screenshots become `{format:"png", fromSurface:true, captureBeyondViewport:false, optimizeForSpeed:false, clip:{...scale:1}}` (no quality). The page also gets a `cFn` that hides the composition background (CSS in page, not CDP). The PNG must carry alpha. `validate` toggles the override on/off repeatedly (`{}` params clears it) and screenshots with `{format:"png", optimizeForSpeed:false, fromSurface:true, captureBeyondViewport:false}` (no clip).

### 4.3 drawelement mode (default on macOS with CSS-free compositions; run 03 and 10)

Chrome 152 reports `drawElementImage`. HF then renders frames in-page into a canvas, encodes in a worker and sends each frame to Node via a puppeteer binding: `Runtime.addBinding {name:"puppeteer___hfFrameReady"}` (+ the standard `addPageBinding` `Runtime.evaluate`), 60 `Runtime.bindingCalled {name, payload, executionContextId}` events, and 15 batch `cFn` calls (`async ({frames,w,h,q}) => ...`). `Page.captureScreenshot` is only used for 9 clip-boundary frames. **For WKWebView:** `typeof canvas.getContext("2d").drawElementImage !== "function"`, so HF logs `fast capture falls back to screenshot capture ... unsupported_chrome` and runs section 4.1. If the shim wants to be explicit, also launch with `--enable-features=` lacking `CanvasDrawElement` (HF launches with it anyway; it is ignored). Not needed.

### 4.4 Fetch usage (what triggers it)

| Trigger | Params | Behaviour |
|---|---|---|
| Render with a `<video>` (HF `videoFrameTransport`, `chunk-ERYYOWWF.js:3883`) | `Fetch.enable {patterns:[{urlPattern:"http://localhost:<port>/__hyperframes_video_frames__/<uuid>/*", requestStage:"Request"}]}` on its own CDP session (one per page) | 1 `Fetch.requestPaused {requestId:"interception-job-N.0", request{url,method,headers}, ...}` per video frame (64 for 2 s, 30 fps + extras). HF answers `Fetch.fulfillRequest {requestId, responseCode:200, responseHeaders:[{name:"Content-Type",value:"image/jpeg"},{name:"Cache-Control",value:"no-store"},{name:"Access-Control-Allow-Origin",value:"*"}], body:<base64 jpeg>}` (`failRequest {requestId, errorReason:"Failed"}` on error). The page sets `<img>` src to that URL and the frame must be served before decode. **If `Fetch.enable` fails, the render throws** (no fallback). |
| `hyperframes check` / `capture` page load (`serveBundledGsap`, `chunk-BBAEXPIU.js:131`) | `Fetch.enable {patterns:[{urlPattern:"https://cdn.jsdelivr.net/npm/gsap@3.15.0/dist/*", requestStage:"Request"}]}` | `requestPaused` -> `fulfillRequest {responseCode:200, responseHeaders:[Content-Type, Access-Control-Allow-Origin], body:<base64 gsap>}` or `Fetch.continueRequest {requestId}` for non-bundled URLs. Also `gotoWhenSent` listens to `Network.requestWillBeSentExtraInfo` / `Network.responseReceived` / `loadingFinished` to detect request sent. |
| Plain `render` without video | none | `Fetch` never used (the page is served from HF's own local server with gsap inlined). |

Shim options for video: implement Fetch for the `__hyperframes_video_frames__` prefix on the WebView with a `WKURLSchemeHandler`/local route that returns `body` for `requestId` (needs `Fetch.enable`, `Fetch.requestPaused`, `Fetch.fulfillRequest`, `Fetch.failRequest`); or intercept at the HTTP server level. Decision belongs to S-phase (not made here).

## 5. Minimal subset for screenshot mode (`PRODUCER_FORCE_SCREENSHOT=true`, mp4, no video, no check)

Must answer (response shape in parentheses):

| Domain.method | Response / required fields |
|---|---|
| `Browser.getVersion` | `{protocolVersion, product:"HeadlessChrome/<ver>", revision, userAgent, jsVersion}` |
| `Browser.close` | `{}` then exit process |
| `Target.setDiscoverTargets` | `{}` + `Target.targetCreated` events (page, tab, browser) |
| `Target.setAutoAttach` (flatten) | `{}` + `Target.attachedToTarget {sessionId, targetInfo, waitingForDebugger}` for tab then page |
| `Target.createTarget {url}` | `{targetId}` + created/attached events |
| `Target.attachToTarget {targetId, flatten:true}` | `{sessionId}` + `Target.attachedToTarget` |
| `Target.detachFromTarget`, `Target.closeTarget` | `{}` / `{success:true}` + `Target.detachedFromTarget`, `Target.targetDestroyed` |
| `Runtime.runIfWaitingForDebugger` | `{}` (per auto-attached session) |
| `Page.enable`, `Page.setLifecycleEventsEnabled`, `Runtime.enable`, `Audits.enable`, `Performance.enable`, `Log.enable` | `{}`; `Runtime.enable` must emit `executionContextCreated` for existing contexts |
| `Page.getFrameTree` | `{frameTree:{frame:{id, loaderId, url, securityOrigin, mimeType,...}}}` (frame.id equals targetId for the main frame) |
| `Page.addScriptToEvaluateOnNewDocument {source, worldName?}` | `{identifier}`; scripts must run before page scripts on every navigation (HF relies on 6-7 of them) |
| `Emulation.setDeviceMetricsOverride`, `Emulation.setTouchEmulationEnabled` | `{}`; viewport must really become width x height, DSF 1 |
| `Page.navigate {url, frameId}` | `{frameId, loaderId, isDownload}` + lifecycle/executionContext events (section 3 step 12) |
| `Runtime.evaluate`, `Runtime.callFunctionOn` | `{result:{type,value[,description,subtype,objectId]}}`, `awaitPromise`, `returnByValue`, `contextId`/`executionContextId` |
| `Page.captureScreenshot` | `{data:<base64>}` honouring `format`, `quality`, `clip` with `scale`, `fromSurface`, `captureBeyondViewport:false` |
| `SystemInfo.getProcessInfo` | `{processInfo:[...]}` |
| Events | `Target.*`, `Page.lifecycleEvent`, `Page.frameNavigated`, `Page.frameStartedLoading/StoppedLoading`, `Page.domContentEventFired`, `Page.loadEventFired`, `Runtime.executionContextCreated/Cleared`, `Runtime.consoleAPICalled` (HF relays page console; shape `{type, args:[{type,value}], executionContextId, timestamp, stackTrace}`) |

Extra for alpha: `Emulation.setDefaultBackgroundColorOverride`. Extra for `check`/`validate`: `Runtime.addBinding`, `Runtime.bindingCalled`, `Runtime.releaseObject`, `DOM.describeNode {objectId}` -> `{node:{nodeId:0, backendNodeId, nodeType, nodeName, localName, nodeValue, childNodeCount, attributes[]}}`, `DOM.resolveNode {backendNodeId, executionContextId}` -> `{object:{type:"object", subtype:"node", className, description, objectId}}`, `Fetch.*` (section 4.4).

Network.* events (`requestWillBeSent`, `responseReceived`, `loadingFinished`, `dataReceived`) are emitted by real Chrome in every navigation; HF render registers `page.on("requestfailed")`. Only `check` waits on them. A shim can emit none for plain render (unverified: not tested, test in S2).

## 6. Fault injection: which errors puppeteer-core 25.18.1 tolerates

The proxy answered `{error:{code:-32601, message:"'X' wasn't found"}}` to one method at a time during the plain run (01 flow). Tolerated (flow completed): `WebMCP.enable`, `Network.enable`, `Page.createIsolatedWorld`. Fatal (launch/newPage/goto failed): `Audits.enable`, `Performance.enable`, `Log.enable`, `Emulation.setTouchEmulationEnabled`, `Emulation.setDeviceMetricsOverride`, `Page.setLifecycleEventsEnabled`, `Page.addScriptToEvaluateOnNewDocument`, `Runtime.enable`, `Page.getFrameTree`, `Target.setDiscoverTargets`, `Browser.getVersion`, `Target.setAutoAttach`. So even domains with no meaning for WebKit (Audits, Performance, Log) must return `{}`. Error response shape: `{id, sessionId?, error:{code, message}}`.

## 7. The beginFrame probe

When it runs: only when HF picks `beginframe` = Linux + chrome-headless-shell + `--enable-begin-frame-control` in args + not `forceScreenshot` (`chunk-ERYYOWWF.js:1736`). On darwin the probe never runs (confirmed in runs 02-10: no `HeadlessExperimental.*` traffic).

What it sends (`probeBeginFrameSupport`, `chunk-ERYYOWWF.js:1501`), reproduced in runs 11-14:

1. `newPage` -> `page.goto("data:text/html,<style>html,body{margin:0;background:%23173}</style><div>hf-beginframe-probe</div>", {waitUntil:"domcontentloaded"})`.
2. `page.createCDPSession()` -> `Target.attachToTarget {targetId, flatten:true}`.
3. `HeadlessExperimental.enable` (no params) -> expects `{}`.
4. `HeadlessExperimental.beginFrame {frameTimeTicks:0, interval:33, noDisplayUpdates:true}` (warm-up; result ignored).
5. Loop until a PNG: `HeadlessExperimental.beginFrame {frameTimeTicks:1000+n*33, interval:33, screenshot:{format:"png"}}`; success needs `screenshotData` base64 whose first 4 bytes are `89 50 4E 47`, retries every 10 ms until the deadline. Empty data until deadline -> timeout (HF retries once with a longer budget and relaunches); non-empty non-PNG -> hard failure.

Observed on macOS (run 11): `enable` returns `{}` and then the warm-up `beginFrame` kills the real browser (`Target closed`, 112 ms). In run 12 (Linux forced) HF logged `probe failed after 116ms: ... Target closed ...; falling back to screenshot mode`, closed the browser, then **relaunched** a new Chrome (68 args, `--enable-begin-frame-control` and the other beginFrame-only flags stripped, `--disable-partial-raster` added) and rendered 60 frames with `Page.captureScreenshot` (section 4.1). Total 4 launches: version, gpu-probe, probe-launch (76 args), render.

**How to fail it cleanly** (runs 13 and 14, both rendered correctly): answer `HeadlessExperimental.enable` OR `HeadlessExperimental.beginFrame` with `{error:{code:-32601,message:"'HeadlessExperimental.enable' wasn't found"}}`. HF logged `probe failed after 76/86ms: Protocol error (...): '...' wasn't found; falling back to screenshot mode.` This is only reachable when platform is linux; on macOS the shim does not need it, but a Linux-hosted build would. Never answer `beginFrame` with an empty/garbage `screenshotData`: that makes HF loop until its timeout.

## 8. Findings that change the plan (for PLAN-webkit-render.md section 3)

1. The brief's "screenshot fallback when beginFrame probe fails" is not the macOS path. macOS default is `drawelement` -> auto fallback to `screenshot` via a plain feature test; the beginFrame probe is Linux only. Update the plan wording: the shim does not need to fail a probe on macOS; it needs to make `ctx.drawElementImage` undefined (WKWebView already does) or the user sets `PRODUCER_FORCE_SCREENSHOT=true`.
2. A render = 3-4 separate Chrome processes (version, gpu probe, capture, sometimes a second capture). `--version` must exit 0 quickly and print a version string; the GPU-probe launch only needs WebGL reads via `Runtime.callFunctionOn` (WKWebView WebGL renderer string will say Apple/Metal).
3. HF uses a second CDP session on the same page for screenshots, so the shim needs multi-session routing (flat mode, `sessionId` on every message).
4. HF injects ~7 `addScriptToEvaluateOnNewDocument` scripts that patch `HTMLCanvasElement.prototype.getContext` (preserveDrawingBuffer) and track accelerated canvases; they must run in every frame/navigation before page scripts (WKUserScript at document start).
5. `<video>` compositions need `Fetch.enable/requestPaused/fulfillRequest` (hard requirement); `check` needs Fetch for bundled GSAP. `lint` needs nothing.
6. The env override survives only as an executable path; HF does not pass its own env vars to the browser process, so shim settings must come from files/argv.
7. HF holds a per-user render lock under `~/.cache/hyperframes/locks`; concurrent AI renders queue behind each other (`--wait` default). Set `HYPERFRAMES_RENDER_LOCK_DIR` to a private folder for tests.

## 9. Open items (not verified)

- Whether HF 0.9.65 rejects a browser major version below some floor (only `--version` major parsing was seen).
- Behaviour when `Network.*` events are absent in plain render.
- JS exception mapping (`exceptionDetails`) and `Runtime.callFunctionOn` with `objectId` (not used in render; used by puppeteer ElementHandle in `check`/`validate`, shapes captured in `07`/`09`).
- Linux beginFrame success path (screenshotData PNG) was not captured: macOS shell does not support it.
- Run 02's 4th launch (post-capture, 68 args): purpose inferred, not confirmed from source.

