---
tags: [safarium, cdp, puppeteer, hyperframes, reference]
note_type: reference
project: "Safarium"
created: 2026-11-21
updated: 2026-11-21
---

# safarium-cdp: the "fake Chrome" shim (task S2)

`safarium-cdp` is a Swift executable (target `safarium-cdp`, SwiftPM product of the same name) that speaks the Chrome DevTools Protocol subset used by puppeteer-core 25.x and HyperFrames 0.9.x over `--remote-debugging-pipe` (NUL-delimited JSON, fd 3 = client to shim, fd 4 = shim to client) and renders with SafariumCore (offscreen `WKWebView`, no window, `.prohibited` activation policy, never steals focus). Wire facts come from [cdp-trace](docs/cdp-trace.md).

## Use

```bash
swift build --product safarium-cdp --scratch-path <scratch>      # binary: <scratch>/debug/safarium-cdp
<exe> --version                      # "Safarium CDP shim 0.1.0 (WebKit)", exit 0
SAFARIUM_CDP=<absolute-path-to-exe> bin/safarium-hf check "$PROJECT" --json
SAFARIUM_CDP=<absolute-path-to-exe> bin/safarium-hf render "$PROJECT" -w 1 -o "$SCRATCH/clip.mp4"
puppeteer.launch({ executablePath: '<exe>', pipe: true })
```
`bin/safarium-hf` points both HyperFrames browser settings at the verified shim and invokes the installed HyperFrames launcher with npm in offline mode. Standalone installations default to CLI 0.9.72; managed plugins use their installed release. Set `SAFARIUM_HF_VERSION` to require an exact release, or `HYPERFRAMES_LAUNCHER` if `plugin-cli.mjs` lives elsewhere. Without `SAFARIUM_CDP` the wrapper builds the Release shim with SwiftPM. A completed render is not evidence it used the video request path: `Tests/hf/fetch-smoke.py` checks the transport, every frame's binary visual ID and 30-fps PTS, and the actual mixed 440-Hz soundtrack.
Only `--remote-debugging-pipe`, `--window-size=W,H` are read from argv (everything else, including all Chrome flags, is ignored). Without the pipe flag the shim exits 2. EOF on fd 3 exits 0.

## Architecture (`Sources/safarium-cdp/`)

| File | Role |
|---|---|
| `main.swift` | `--version`, argv, starts `NSApplication` (`.prohibited`) and the server |
| `Transport.swift` | fd 3 reader thread (messages are handled on the main actor, in order), serial fd 4 writer, `SAFARIUM_CDP_TRACE` |
| `Server.swift` | targets (`tab` + `page`, as Chrome 152 does), flat sessions, auto-attach, browser/target methods, unsupported-method log |
| `PageContent.swift` | one `SafariumCore.Page` per page target: navigation events, execution contexts, scripts, bindings, screenshots, emulation |
| `JSRuntime.swift` | JS run in the page for `Runtime.evaluate` / `callFunctionOn` (remote-object registry, serializer, exception mapping) and the document-start boot script (load events, console, errors) |
| `FetchDomain.swift`, `FetchAssets.swift`, `FetchRouting.swift` | Per-target resource handler, per-session pause lifecycle, document/project scope, bounded file/HTTP reads and URL translation for parser- and JS-created assets |
| `WindowlessAudioMetadata.swift` | Measures scoped PCM WAV duration when a detached WebKit page will not start its loader: Web Audio decode for small files, validated RIFF/PCM byte ranges for large files. Does not assert playback, synthesize readiness events, or replace existing native metadata. |

Each CDP message runs in its own main-actor task (started in arrival order), so a long `awaitPromise` never blocks other sessions. Events are sent before the response, as Chrome does for `setAutoAttach`, `createTarget`, `Runtime.enable`.

## Supported methods

| Domain | Methods |
|---|---|
| Browser | `getVersion` (`product: "Safarium/0.1.0"`), `close` |
| Target | `setDiscoverTargets`, `setAutoAttach` (browser + tab level), `createTarget`, `attachToTarget`, `detachFromTarget`, `closeTarget`, `getTargets`, `getTargetInfo`, `activateTarget` |
| Page | `enable`, `getFrameTree`, `setLifecycleEventsEnabled` (replays reached events), `navigate` (returns `errorText` like `net::ERR_FILE_NOT_FOUND` on failure), `reload`, `stopLoading`, `bringToFront` (no-op), `close`, `setDocumentContent`, `addScriptToEvaluateOnNewDocument` / `remove...` (WKUserScript at document start, all frames, `runImmediately`), `createIsolatedWorld`, `captureScreenshot` |
| Runtime | `enable`, `evaluate`, `callFunctionOn` (value / objectId / unserializable arguments), `releaseObject`, `releaseObjectGroup`, `addBinding` / `removeBinding`, `runIfWaitingForDebugger`, `discardConsoleEntries`; events `executionContextCreated/Cleared`, `consoleAPICalled`, `exceptionThrown`, `bindingCalled` |
| Emulation | `setDeviceMetricsOverride`, `clearDeviceMetricsOverride`, `setTouchEmulationEnabled`, `setFocusEmulationEnabled`, `setDefaultBackgroundColorOverride` (alpha 0 = transparent page, anything else = opaque), `setUserAgentOverride` |
| Network | `enable`, `disable`, `setCacheDisabled` (no-op), `setUserAgentOverride`; events for the main document and shim-managed asset requests, not an inventory of every native WebKit request |
| Fetch (scoped) | `enable`, `disable`, `continueRequest`, `fulfillRequest`, `failRequest`, `getResponseBody`, `continueResponse`; `requestPaused` carries an ID usable only by its owning session. Intercepted assets also emit Network events. |
| DOM | `describeNode`, `resolveNode` (enough for puppeteer ElementHandle: `$`, `$eval`, `waitForSelector`) |
| No-op `{}` | `Audits/Performance/Log/WebMCP.enable`, `*.disable` for the domains above |
| Other | `SystemInfo.getProcessInfo` |

Anything else answers `{error:{code:-32601, message:"'X' wasn't found"}}` and is logged once per process to stderr and to `$SAFARIUM_CDP_LOG`, default `~/Library/Logs/Safarium/cdp-unsupported.log`. HyperFrames does not forward its env vars to the browser, so the default file is where missing methods of a future HF version show up. Debug aid: `SAFARIUM_CDP_TRACE=<file>` writes every message in both directions.

## Behaviour notes and deliberate deviations

- Screenshots: `format` png/jpeg (`quality`), `clip` with `scale` (output = clip x scale x deviceScaleFactor), `captureBeyondViewport` (temporarily enlarges the view). The size is exact, which is what HF checks. webp is refused.
- The **pre-existing** transparent PNG path uses the `drawsBackground` KVC key; it produced alpha in the earlier ProRes fixture, but that key is not declared on the installed public `WKWebView` header. Do not count it as proof of a public-only transparent-capture path. A control with public `underPageBackgroundColor = .clear` still returned corner alpha 1.0, even for a nonopaque NSView subclass/layer. The new H.264 renderer/Fetch results here are for opaque SDR; `RetainedViewport` explicitly enforces that scope.
- Native `file:` navigation grants WebKit read access to the document's directory. For readable cross-resource fetch/canvas workflows, HF normally serves the project on its own HTTP origin.
- All named worlds (`__puppeteer_utility_world__...`) run in WebKit's page world. They get their own context ids/names, but real isolation is not possible: puppeteer passes main-world objects into the utility world and `WKContentWorld`s cannot share objects. Page scripts could see puppeteer's injected globals. A consequence: `backendNodeId` = 1000 x context id + n, resolved in the context that described it.
- `Page.setDocumentContent` is `document.open/write/close` and the shim announces `init`, `DOMContentLoaded`, `load` itself.
- First `file:` navigation after launch is slow (about 0.6 s here, more on the external `Main` drive): WebKit starts its network process lazily.
- `--version` prints no Chrome-style version number on purpose; HF only extracts the major for telemetry.

### Fetch for renderer assets

Apple's public [`WKURLSchemeHandler`](https://developer.apple.com/documentation/webkit/wkurlschemehandler) is for custom schemes; WebKit owns `http:`, `https:` and `file:`. The shim associates a `safarium-asset:` handler with **one** render target, translates matched resource URLs and emits the original URLs over the CDP pipe. It neither installs certificates nor changes machine network settings. Asset interception starts from a CDP-selected project file or loopback page. HyperFrames' narrow URL patterns can be enabled before navigation or after the page is already running. An unrestricted pattern on an already loaded native page is not a transparent catch-all.

- For a project file, eligible bytes are read under the selected page's directory; symlink traversal is not followed. A parser/dynamic script can consume fulfilled bytes. A native `file:` page may display an image while still being denied a canvas pixel read; `file:` page `fetch` is likewise subject to WebKit's origin policy. Use the project's HTTP origin when the page needs readable asset responses.
- On the local renderer origin, continue, fulfill (status, headers, base64 body), fail and response-stage replacement affect what the page actually receives. A bounded `GET`/`HEAD` can read the selected server; local file Range requests support `206`/`416`. Disabling a session or detaching releases its pending work; closing or navigating the target cancels obsolete jobs.
- Reusing an upstream body also preserves the upstream status/headers and policy. An intercepted page cannot grant itself a different loopback origin by navigating or reloading. Hot enable requires a validated main document without child frames; unknown initiators/foreign subdocuments are not an extension of the selected project. These are intentional renderer restrictions, not CDP browser parity.
- Explicitly named external resource origins can receive **synthetic** responses from the CDP client. Passing a request through to an arbitrary external host or a different loopback server is not supported. Only a restricted versioned jsDelivr GSAP script URL can continue externally; set `SAFARIUM_FETCH_OFFLINE=1` in the shim process to disable even that upstream fallback. This variable controls the shim-managed asset reader, not all native WebKit networking. Network reads use an ephemeral session with no credential/cookie storage and no redirects. WebKit still applies resource/CORS restrictions.
- Auth challenges, arbitrary uploads, transparent HTTPS capture, all browser resource APIs, and full Studio parity are not implemented. WebKit may block an untranslatable matching load rather than exposing it to a handler. A method acknowledgement is not sufficient proof of substitution.

## Known gaps (S3 and later)

| Gap | Effect |
|---|---|
| General network interception | Renderer-scoped Fetch is implemented (above). It does not implement machine-wide interception, arbitrary remote navigation with Fetch enabled, or all cross-origin workflows. |
| Media in a hidden page | Some detached `<audio>` elements never start their native metadata loader. The tested local PCM cases supply measured duration: the EP30 WAV is 664.02 s, equal to ffprobe. A strong ETag permits two `206` responses (4,099 body bytes); HF-declared static assets without validators use one representation (4,096 body bytes). Unsupported formats or ambiguous large files remain unknown; this does not implement native audio playback. HF mixes render audio with FFmpeg. |
| `Input.*`, `Page.printToPDF`, `Network.setExtraHTTPHeaders`, cookies, dialogs | not implemented (-32601, logged) |
| iframes | no execution contexts for child frames |
| HF 0.9.72 `render --start … --end …` | The distributed range renderer requires an actual SwiftShader GL backend. WebKit reports the real Apple GPU and the range job is refused. Ordinary whole-composition rendering and the native `safarium-bench --start … --frames …` path are separate. |
| `deviceScaleFactor` | screenshot size honours it, but `devicePixelRatio` in the page does not change |
| drawElementImage fast path | absent in WebKit, HF falls back to screenshot capture by itself (`unsupported_chrome`) |

## Tests

| Where | What |
|---|---|
| `tests/cdp/acceptance.test.mjs` | puppeteer-core 25.18.1 end to end: launch, newPage, setViewport, goto, evaluate, evaluateOnNewDocument, console relay, png/jpeg/clip+scale/omitBackground screenshots, -32601, two pages, close |
| `tests/cdp/protocol.test.mjs` | raw pipe client: unsupported-method log, bad session, evaluate/callFunctionOn/exceptions/objectId, navigate errors, `Browser.close`, EOF exit, puppeteer helpers (`$eval`, `waitForSelector`, `setContent`), reload |
| `Tests/SafariumCDPTests` | XCTest: `--version` exit 0, refuses to run without the pipe flag |
| `Tests/cdp/fetch.test.mjs` / `fetch-scopes.mjs` | Local CDP request-stage lifecycle and bounds; optional capability matrix for project files, two HTTP origins, response-stage replacement and an offline HTTPS script |
| `Tests/hf/fetch-smoke.py` / `check-bundled.py` | Real HF check/render, observable CDN fulfillment, correlated image replies, frame IDs, exact timestamps, audio duration and tone |

```bash
S=<scratch>; swift build --product safarium-cdp --scratch-path $S/build
npm install puppeteer-core@25.18.1 --prefix $S/pptr          # puppeteer lives in scratch, not the vault
SAFARIUM_CDP=$S/build/debug/safarium-cdp PPTR_DIR=$S/pptr SCRATCH_DIR=$S/out node --test tests/cdp/*.test.mjs
swift test --filter SafariumCDPTests --scratch-path $S/build
```

For the integrated release gate, use the existing Puppeteer/npm cache and a new scratch directory:

```sh
python3 Tests/verify-render-stack.py --scratch "$LAB" --puppeteer-root "$PPTR_DIR" \
  --gsap "$EP/gsap.min.js" --voice "$EP/assets/voice.wav"
```

The resulting `summary.json` identifies the exact Release binary and SHA-256, Swift and CDP tests, optional Swift probes, all 22 asset-scope observations, WAV checks, Thai OCR, both actual HF versions, and final MP4 packet/audio verification.

## HyperFrames result (0.9.65, 1280x720, 2 s, 30 fps, CSS keyframes + GSAP timeline + audio, default workers)

| Output | Shim | Chromium (headless shell 152) | Compare |
|---|---|---|---|
| mp4 render time | 5.4 to 9.9 s (machine load 30) | 7.1 s | none unsupported methods logged |
| mp4, frame at 1.0 s | | | PSNR 32.45 dB, SSIM 0.99498 (only glyph edges differ) |
| mp4, all 60 frames | | | PSNR 36.07 dB avg (Y 34.3), SSIM 0.99685 |
| mov ProRes 4444 alpha, frame at 1.0 s | | | PSNR 29.5 dB, SSIM 0.9941; corner alpha 0, box (255,136,0,255), both identical |

