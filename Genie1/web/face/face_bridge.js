/* Loaded once, lazily. All assets and inference remain on this origin. */
(() => {
  const base = new URL('./', document.currentScript.src);
  let worker, sequence = 0;
  const cameraGenerations = new WeakMap();
  const pending = new Map();
  function release() {
    worker?.terminate(); worker = null;
    for (const entry of pending.values()) {
      clearTimeout(entry.timer); entry.reject(Error('Face verification stopped. Please retry.'));
    }
    pending.clear();
  }
  function request(operation, data = {}, transfers = []) {
    if (!worker) {
      worker = new Worker(new URL('face_worker.js',base));
      worker.onmessage = ({data}) => {
        if (data.diagnostic) {
          console.debug('[Genie face runtime]', data.diagnostic);
          return;
        }
        const entry = pending.get(data.id);
        if (!entry) return;
        pending.delete(data.id); clearTimeout(entry.timer);
        data.error ? entry.reject(Error(data.error)) : entry.resolve(data.value);
      };
      worker.onerror = release;
    }
    return new Promise((resolve,reject) => {
      const id = ++sequence;
      const timer = setTimeout(release,operation === 'live' ? 10000 : 120000);
      pending.set(id,{resolve,reject,timer});
      worker.postMessage({id,operation,...data},transfers);
    });
  }
  function warmup() {
    const operation = request('warmup');
    const requestedWorker = worker;
    return operation.catch(error => {
      // Failed WASM imports can remain rejected inside the runtime module.
      // Retry must start a fresh worker, not reuse that failed initialization.
      if (worker === requestedWorker) release();
      throw error;
    });
  }
  function stop(video) {
    cameraGenerations.set(video, (cameraGenerations.get(video) || 0) + 1);
    const stream = video.srcObject;
    if (stream) for (const track of stream.getTracks()) track.stop();
    video.pause(); video.srcObject = null;
  }
  function canvas(video) {
    if (!video.videoWidth || !video.videoHeight || video.readyState < 2 || document.hidden ||
        !video.srcObject?.getVideoTracks().some(track => track.readyState === 'live')) {
      throw Error('Camera is not ready. Please retry.');
    }
    const c = document.createElement('canvas');
    c.width = video.videoWidth; c.height = video.videoHeight;
    c.getContext('2d').drawImage(video,0,0); return c;
  }
  self.genieFace = {
    warmup, release, stop,
    async start(video) {
      if (!isSecureContext || !navigator.mediaDevices?.getUserMedia) {
        throw Error('Camera access requires HTTPS or localhost and a supported browser.');
      }
      const generation = (cameraGenerations.get(video) || 0) + 1;
      cameraGenerations.set(video,generation);
      const stream = await navigator.mediaDevices.getUserMedia({audio:false,
        video:{facingMode:'user',width:{ideal:1280},height:{ideal:960}}});
      try {
        if (!video.isConnected || document.hidden || cameraGenerations.get(video) !== generation) {
          throw Error('Camera page is no longer active.');
        }
        video.srcObject = stream; await video.play();
        // HAVE_CURRENT_DATA is sufficient for canvas capture. A paint callback
        // can remain suspended for a valid video in an occluded platform view.
        await new Promise((resolve,reject) => {
          const started = performance.now();
          const check = () => {
            if (cameraGenerations.get(video) !== generation || document.hidden) {
              reject(Error('Camera page is no longer active.'));
            } else if (video.readyState >= 2 && video.videoWidth && video.videoHeight) {
              resolve();
            } else if (performance.now() - started > 10000) {
              reject(Error('The camera did not provide a frame. Please retry.'));
            } else { setTimeout(check,50); }
          };
          check();
        });
        if (cameraGenerations.get(video) !== generation || document.hidden) {
          throw Error('Camera page is no longer active.');
        }
      } catch(error) { for (const track of stream.getTracks()) track.stop(); throw error; }
    },
    async sample(video) {
      const c = canvas(video), ctx = c.getContext('2d');
      const pixels = ctx.getImageData(c.width/4,c.height/4,Math.floor(c.width/2),Math.floor(c.height/2)).data;
      let brightness = 0;
      for(let i=0;i<pixels.length;i+=16) brightness += pixels[i]*.299+pixels[i+1]*.587+pixels[i+2]*.114;
      const bitmap = await createImageBitmap(c);
      const face = await request('live',{bitmap,timestamp:performance.now()},[bitmap]);
      face.brightness = brightness/Math.ceil(pixels.length/16);
      return JSON.stringify(face);
    },
    snapshot: video => canvas(video).toDataURL('image/jpeg',.95).split(',')[1],
    async detect(bytes) {
      const bitmap = await createImageBitmap(new Blob([bytes],{type:'image/jpeg'}));
      return JSON.stringify(await request('image',{bitmap},[bitmap]));
    },
    embed: tensor => request('embed',{tensor}),
  };
})();
