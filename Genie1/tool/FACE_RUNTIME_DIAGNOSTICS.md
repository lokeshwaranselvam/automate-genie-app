# Browser face runtime diagnosis

This support page isolates initialization failures before selecting memory optimizations.
It does not change the SFace model, alignment, matching threshold, or blink requirements.

## Build and deploy

From Genie1, rebuild the static PWA:

```powershell
python tool/build_pwa.py --base-href /genie/
```

Use the actual hosting path if it differs from `/genie/`. Deploy the contents of
`dist/automate-genie-pwa.zip` to that path using the existing PWA deployment process.
Source edits alone do not update a hosted Flutter PWA. The diagnostic page requires
the matching `face_worker.js`, `face/vendor/` assets, and bundled SFace model.

## Run on the affected phone

1. Close the attendance app and other browser tabs. Open
   `https://<your-ERP-host>/genie/face/diagnostics.html` in the affected browser.
2. Keep graph optimization at **All** and both memory checkboxes unchecked.
3. Run **ONNX WASM only**, **SFace only**, **MediaPipe only**, and
   **MediaPipe + SFace**, one at a time. Each test creates a new worker and
   terminates it on completion, failure, cancellation, or a 120-second timeout.
4. Tap **Download report**. The JSON records browser version, selected settings,
   stage timings, and errors. It contains no employee images or embeddings and
   is not uploaded automatically.
5. If the tab itself crashes, reopen it and run only the failing test. A browser
   process crash may prevent the report from being downloaded; note the last
   visible stage before the crash. Prior reports exist only in page memory.

For a realistic comparison, repeat after reopening the browser and repeat the
attendance flow separately. This standalone page omits Flutter and the camera,
so a pass here does not guarantee enough memory inside the full app.

## Interpret the results

| Result | Next investigation |
| --- | --- |
| Tiny ONNX model fails | ONNX WASM allocation, runtime/browser compatibility, or asset delivery; reducing SFace size alone will not address an ONNX startup failure. |
| Tiny model passes, SFace fails | SFace session creation or inference allocations. |
| MediaPipe alone fails | MediaPipe runtime/model initialization or asset delivery. |
| Each model passes alone, combined fails | Combined resident memory is a leading hypothesis; evaluate separate worker lifetimes. |
| All standalone tests pass, attendance fails | Inspect normal-app stage logs and memory pressure from Flutter, camera, and other tabs. |

Normal attendance initialization emits `[Genie face runtime]` debug messages in
the browser console. Importing ONNX JavaScript is not a WASM initialization test:
the tiny Identity session forces actual WASM initialization and executes inference.

## Compare settings before changing the application

On the failing SFace or combined test, change only one option at a time: graph
optimization **Basic**, graph optimization **Disabled**, CPU memory arena disabled,
or memory pattern disabled. Repeat under similar browser conditions. These test
options never change production session settings. Passing synthetic inference
does not prove recognition accuracy or compatibility with existing enrollments.

Stage durations are not peak memory measurements. JavaScript heap readings do not
reliably represent WASM or the browser process. Use the affected browser's developer
tools and available process measurements to corroborate allocation hypotheses.

If simultaneous model memory is responsible, evaluate terminating a dedicated
MediaPipe worker after blink validation/alignment and using a separate SFace worker
for embedding. Closing a model alone does not guarantee that a WASM heap shrinks.
This requires lifecycle changes and regression tests before adoption; it is not
implemented by this diagnostic change. Reduced camera-frame copies are a later,
separate optimization and cannot fix initialization that fails before camera start.

## Local verification

```powershell
node --test test/face_runtime_retry_test.cjs
node tool/test_face_diagnostics.mjs
node tool/test_face_diagnostics.mjs --ios-user-agent
```

The second command needs Chrome (override `CHROME_EXECUTABLE` if necessary) and
prepared browser assets. It tests real WASM modes, alternative session settings,
failure reporting, and worker teardown. It saves a mobile-width screenshot and
uses only synthetic inference. Actual phone, camera, enrollment, and ERP attendance
submission still require device verification.

The `--ios-user-agent` run exercises MediaPipe's browser detection using an
iPhone Chrome user agent in desktop Chromium. This reproduces the DOM-canvas
fallback regression without pretending to emulate iPhone WebKit or its memory
limits. The worker now passes an explicit OffscreenCanvas through MediaPipe's
supported `canvas` option; matching and blink policies remain unchanged.

Reference: https://onnxruntime.ai/docs/api/js/interfaces/InferenceSession.SessionOptions.html
