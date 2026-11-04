// Classic worker: MediaPipe's WASM loader requires importScripts.
// Both vision and SFace inference stay off the Flutter UI thread.
let detector, detectorMode, session, ort, continuity;
let queue = Promise.resolve();
const base = new URL('./', self.location.href);
async function initialize() {
  if (session && detector) return;
  const [{FaceLandmarker, FilesetResolver}, runtime, metrics] = await Promise.all([
    import(new URL('vendor/mediapipe/vision_bundle.mjs', base)),
    import(new URL('vendor/ort/dist/ort.wasm.min.mjs', base)),
    import(new URL('face_metrics.mjs', base)),
  ]);
  ort = runtime;
  ort.env.wasm.numThreads = 1; // No cross-origin isolation headers required.
  ort.env.wasm.wasmPaths = new URL('vendor/ort/dist/', base).href;
  detector = await FaceLandmarker.createFromOptions(
    await FilesetResolver.forVisionTasks(new URL('vendor/mediapipe/wasm/', base).href), {
      baseOptions: {modelAssetPath: new URL('vendor/face_landmarker.task', base).href, delegate: 'CPU'},
      runningMode: 'IMAGE', numFaces: 2, minFaceDetectionConfidence: .6,
      minFacePresenceConfidence: .6, minTrackingConfidence: .6,
      outputFaceBlendshapes: true, outputFacialTransformationMatrixes: true,
    });
  detectorMode = 'IMAGE';
  continuity = new metrics.FaceContinuity();
  try {
    session = await ort.InferenceSession.create(new URL('../assets/assets/face_recognition/sface_2021dec.onnx', base).href,
      {executionProviders:['wasm'], graphOptimizationLevel:'all'});
    if (!session.inputNames.includes('data') || !session.outputNames.includes('fc1')) {
      throw Error('The installed face model is incompatible.');
    }
  } catch (error) {
    detector.close(); detector = null;
    if (session) await session.release();
    session = null; throw error;
  }
}
async function execute(message) {
  await initialize();
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
