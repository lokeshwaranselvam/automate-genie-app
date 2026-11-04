// MediaPipe blendshapes are expression scores, not ML Kit probabilities.
// Keep this adapter explicit: recognition still uses the unchanged SFace model.
export function faceMetrics(result, width, height) {
  const faces = result.faceLandmarks || [];
  if (faces.length !== 1) return {faceCount: faces.length};
  const points = faces[0];
  if (points.length < 478) throw Error('Incomplete face landmarks. Please retry.');
  const matrix = result.facialTransformationMatrixes?.[0]?.data;
  if (!matrix || matrix.length !== 16) throw Error('Face pose is unavailable.');
  const scores = Object.fromEntries((result.faceBlendshapes?.[0]?.categories || [])
    .map(c => [c.categoryName, c.score]));
  const eye = name => Number.isFinite(scores[name]) ? 1 - scores[name] : null;
  const left = Math.min(...points.map(p => p.x)) * width;
  const right = Math.max(...points.map(p => p.x)) * width;
  const top = Math.min(...points.map(p => p.y)) * height;
  const bottom = Math.max(...points.map(p => p.y)) * height;
  const xy = index => [points[index].x * width, points[index].y * height];
  const eyes = [xy(468), xy(473)].sort((a,b) => a[0]-b[0]);
  const mouth = [xy(61), xy(291)].sort((a,b) => a[0]-b[0]);
  const degrees = 180 / Math.PI;
  const metrics = {
    faceCount: 1, left, right, top, bottom,
    leftEyeOpen: eye('eyeBlinkLeft'), rightEyeOpen: eye('eyeBlinkRight'),
    yaw: Math.atan2(-matrix[2], Math.hypot(matrix[0], matrix[1])) * degrees,
    pitch: Math.atan2(matrix[6], matrix[10]) * degrees,
    roll: Math.atan2(matrix[1], matrix[0]) * degrees,
    faceFraction: Math.min(right-left, bottom-top)/Math.min(width,height),
    centerOffset: Math.max(Math.abs((left+right)/2/width-.5), Math.abs((top+bottom)/2/height-.5)),
    landmarks: [eyes[0], eyes[1], xy(1), mouth[0], mouth[1]],
  };
  if ([left,right,top,bottom,metrics.yaw,metrics.pitch,metrics.roll,
    ...metrics.landmarks.flat()].some(v => !Number.isFinite(v))) {
    throw Error('Invalid face geometry. Please retry.');
  }
  return metrics;
}

export class FaceContinuity {
  constructor() { this.previous = null; this.id = 0; }
  observe(face) {
    if (face.faceCount !== 1) { this.previous = null; return null; }
    const center = [(face.left+face.right)/2, (face.top+face.bottom)/2];
    const size = Math.max(face.right-face.left, face.bottom-face.top);
    const old = this.previous;
    if (!old || Math.hypot(center[0]-old.center[0], center[1]-old.center[1]) > old.size*.35 ||
        size/old.size < .65 || size/old.size > 1.5) this.id++;
    this.previous = {center, size};
    return this.id;
  }
}
