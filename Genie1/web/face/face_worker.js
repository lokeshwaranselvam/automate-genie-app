// Classic worker: MediaPipe's WASM loader requires importScripts.
// Both vision and SFace inference stay off the Flutter UI thread.
let detector, detectorMode, session, ort, continuity;
let queue = Promise.resolve();
const base = new URL('./', self.location.href);
async function stage(name, action) {
  const started = performance.now();
  const report = status => self.postMessage({diagnostic: {
    stage: name, status, elapsedMs: Math.round(performance.now() - started),
  }});
  report('started');
  try {
    const result = await action();
    report('passed');
    return result;
  } catch (error) {
    report('failed');
    throw Error(`[${name}] ${error?.message || 'Initialization failed.'}`);
  }
}
async function loadRuntime() {
  if (ort) return;
  // Importing JavaScript does not initialize WASM. Session creation below does.
  ort = await stage('ONNX JavaScript import', () =>
    import(new URL('vendor/ort/dist/ort.wasm.min.mjs', base)));
  ort.env.wasm.numThreads = 1; // No cross-origin isolation headers required.
  ort.env.wasm.wasmPaths = new URL('vendor/ort/dist/', base).href;
}
async function loadDetector() {
  if (detector) return;
  const {FaceLandmarker, FilesetResolver} = await stage('MediaPipe JavaScript import', () =>
    import(new URL('vendor/mediapipe/vision_bundle.mjs', base)));
  const metrics = await import(new URL('face_metrics.mjs', base));
  if (typeof OffscreenCanvas !== 'function') {
    throw Error('This browser does not support face verification in a worker. Update your browser and retry.');
  }
  detector = await stage('MediaPipe WASM and model initialization', async () => FaceLandmarker.createFromOptions(
    await FilesetResolver.forVisionTasks(new URL('vendor/mediapipe/wasm/', base).href), {
      // MediaPipe 0.10.21 misclassifies CriOS UAs as older Safari and otherwise
      // falls back to document.createElement(), which cannot run in a worker.
      // Use its supported canvas option; do not spoof the UA or create a DOM shim.
      canvas: new OffscreenCanvas(1, 1),
      baseOptions: {modelAssetPath: new URL('vendor/face_landmarker.task', base).href, delegate: 'CPU'},
      runningMode: 'IMAGE', numFaces: 2, minFaceDetectionConfidence: .6,
      minFacePresenceConfidence: .6, minTrackingConfidence: .6,
      outputFaceBlendshapes: true, outputFacialTransformationMatrixes: true,
    }));
  detectorMode = 'IMAGE';
  continuity = new metrics.FaceContinuity();
}
async function loadSession(options = {}) {
  await loadRuntime();
  session = await stage('SFace session creation (includes ONNX WASM initialization)', () =>
    ort.InferenceSession.create(new URL('../assets/assets/face_recognition/sface_2021dec.onnx', base).href,
      {executionProviders:['wasm'], graphOptimizationLevel:'all', ...options}));
  if (!session.inputNames.includes('data') || !session.outputNames.includes('fc1')) {
    throw Error('The installed face model is incompatible.');
  }
}
async function cleanup() {
  try { detector?.close(); }
  finally {
    detector = null;
    try { if (session) await session.release(); }
    finally { session = null; }
  }
}
async function initialize() {
  if (session && detector) return;
  try {
    await loadRuntime();
    await loadDetector();
    await loadSession();
  } catch (error) {
    try { await cleanup(); } catch (_) { /* Preserve the initialization error. */ }
    throw error;
  }
}
async function diagnose(message) {
  if (!['onnx', 'sface', 'mediapipe', 'combined'].includes(message.mode)) {
    throw Error('Unknown diagnostic mode.');
  }
  if (!['all', 'basic', 'disabled'].includes(message.optimization)) {
    throw Error('Unknown diagnostic optimization level.');
  }
  const options = {graphOptimizationLevel: message.optimization};
  if (message.noArena === true) options.enableCpuMemArena = false;
  if (message.noPattern === true) options.enableMemPattern = false;
  try {
    if (message.mode === 'combined') await loadRuntime();
    if (message.mode === 'mediapipe' || message.mode === 'combined') await loadDetector();
    if (message.mode === 'onnx') {
      await loadRuntime();
      // ONNX IR 8, opset 13: one float [1] Identity node. No face model involved.
      const model = Uint8Array.from(atob('CAgSEWdlbmllLWRpYWdub3N0aWNzOkAKEAoBeBIBeSIISWRlbnRpdHkSCndhc20tcHJvYmVaDwoBeBIKCggIARIECgIIAWIPCgF5EgoKCAgBEgQKAggBQgIQDQ=='), c => c.charCodeAt(0));
      session = await stage('ONNX WASM initialization with tiny Identity model', () =>
        ort.InferenceSession.create(model, {executionProviders:['wasm'], ...options}));
      const input = new ort.Tensor('float32', new Float32Array([1]), [1]);
      let output;
      try {
        output = await stage('Identity inference', () => session.run({x: input}));
        if (output.y.data[0] !== 1) throw Error('Identity output mismatch.');
      } finally {
        input.dispose();
        if (output) for (const value of Object.values(output)) value.dispose();
      }
    } else if (message.mode !== 'mediapipe') {
      await loadSession(options);
      const values = await stage('SFace synthetic inference', () =>
        execute({operation:'embed', tensor:new Float32Array(3 * 112 * 112)}, true));
      if (values.length !== 128) throw Error('Unexpected SFace output.');
    }
    return true;
  } finally { await cleanup(); }
}
async function execute(message, initialized = false) {
  if (message.operation === 'diagnose') return diagnose(message);
  if (!initialized) await initialize();
  if (message.operation === 'warmup') return true;
  if (message.operation === 'embed') {
    const tensor = new ort.Tensor('float32', message.tensor, [1,3,112,112]);
    let output;
    try {
      output = await session.run({data:tensor});
      const values = Array.from(output.fc1.data);
      if (values.length !== 128 || values.some(v => !Number.isFinite(v))) throw Error('Invalid face model output.');
      return values;
    } finally {
      tensor.dispose();
      if (output) for (const value of Object.values(output)) value.dispose();
    }
  }
  const bitmap = message.bitmap;
  try {
    const mode = message.operation === 'live' ? 'VIDEO' : 'IMAGE';
    if (mode !== detectorMode) { await detector.setOptions({runningMode:mode}); detectorMode = mode; }
    const result = mode === 'VIDEO' ? detector.detectForVideo(bitmap, message.timestamp) : detector.detect(bitmap);
    const {faceMetrics} = await import(new URL('face_metrics.mjs', base));
    const face = faceMetrics(result,bitmap.width,bitmap.height);
    if (mode === 'VIDEO') face.trackingId = continuity.observe(face);
    return face;
  } finally { bitmap.close(); }
}
self.onmessage = ({data}) => {
  queue = queue.then(async () => {
    try { self.postMessage({id:data.id, value:await execute(data)}); }
    catch (error) {
      data.bitmap?.close();
      self.postMessage({id:data.id, error:error?.message || 'Browser face verification failed.'});
    }
  });
};
