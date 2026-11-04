import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import {spawn,spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
const root=path.resolve(import.meta.dirname,'..');
const testDir=path.join(root,'build/face_browser_test');
await fs.mkdir(testDir,{recursive:true});
const fixtures=[{"name": "portrait.jpg", "url": "https://storage.googleapis.com/mediapipe-assets/portrait.jpg", "sha256": "a6f11efaa834706db23f275b6115058fa87fc7f14362681e6abe14e82749de3e"}, {"name": "lin-manuel-miranda.png", "url": "https://raw.githubusercontent.com/ageitgey/face_recognition/master/examples/lin-manuel-miranda.png", "sha256": "1f29c132951d7741431b32aaaf569d79a11bc690b04b843f12b7e306f080599a"}];
for(const fixture of fixtures) {
 const file=path.join(testDir,fixture.name);
 let bytes;try{bytes=await fs.readFile(file);}catch{}
 if(!bytes || createHash('sha256').update(bytes).digest('hex')!==fixture.sha256) {
  const response=await fetch(fixture.url);assert(response.ok);bytes=Buffer.from(await response.arrayBuffer());
  assert.equal(createHash('sha256').update(bytes).digest('hex'),fixture.sha256);await fs.writeFile(file,bytes);
 }
}
const dart=process.env.DART_EXECUTABLE || (process.platform==='win32'?'C:/flutter/bin/cache/dart-sdk/bin/dart.exe':'dart');
const compiled=spawnSync(dart,['compile','js','tool/browser_face_probe.dart','-o','build/face_browser_test/probe.dart.js'],{cwd:root,encoding:'utf8',windowsHide:true});
if(compiled.status!==0)throw Error(compiled.stderr||compiled.stdout);

const server=http.createServer(async(req,res)=>{
 try {
  const url=new URL(req.url,'http://localhost');
  if(url.pathname==='/genie/probe') {
   res.setHeader('Content-Type','text/html');res.end('<base href="/genie/"><video id="camera" muted autoplay playsinline></video><script src="face/face_bridge.js"></script><script src="test/probe.dart.js"></script>'); return;
  }
  const name=decodeURIComponent(url.pathname);
  if(name.startsWith('/genie/assets/assets/face_recognition/')) { res.end(await fs.readFile(path.join(root,'assets/face_recognition',path.basename(name))));return; }
  const base=name.startsWith('/genie/test/')?path.join(root,'build/face_browser_test'):name.startsWith('/genie/face/')?path.join(root,'web'):path.join(root,'build/web');
  const file=path.resolve(base,name.replace(/^\/genie\/(?:test\/)?/,''));
  if(!file.startsWith(base+path.sep)) throw Error('Invalid path');
  const mime={'.js':'text/javascript','.mjs':'text/javascript','.wasm':'application/wasm','.jpg':'image/jpeg'};
  res.setHeader('Content-Type',mime[path.extname(file)]||'application/octet-stream'); res.end(await fs.readFile(file));
 } catch(error) {res.statusCode=404;res.end('Missing test asset');}
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const port=server.address().port;
const profile=path.join(root,'build/face-browser-test-profile-'+Date.now());
const fakeVideo=path.join(testDir,'blank-camera.y4m');
const frame=Buffer.concat([Buffer.from('FRAME\n'),Buffer.alloc(640*480,127),Buffer.alloc(640*480/2,128)]);
await fs.writeFile(fakeVideo,Buffer.concat([Buffer.from('YUV4MPEG2 W640 H480 F20:1 Ip A1:1 C420\n'),...Array(40).fill(frame)]));
const browser=spawn(process.env.CHROME_EXECUTABLE||'C:/Program Files/Google/Chrome/Application/chrome.exe',[
 '--disable-background-timer-throttling','--disable-renderer-backgrounding','--disable-backgrounding-occluded-windows','--autoplay-policy=no-user-gesture-required',
 '--headless=new','--no-first-run','--no-default-browser-check','--remote-debugging-port=0',
 '--use-fake-device-for-media-stream','--use-file-for-fake-video-capture='+fakeVideo,'--use-fake-ui-for-media-stream','--user-data-dir='+profile,'about:blank'],{windowsHide:true,stdio:'ignore'});
let ws;
try {
 let debugPort;
 for(let i=0;i<100;i++) {try {debugPort=Number((await fs.readFile(path.join(profile,'DevToolsActivePort'),'utf8')).split('\n')[0]);break;}catch{}await new Promise(r=>setTimeout(r,100));}
 const pages=await(await fetch(`http://localhost:${debugPort}/json/list`)).json();
 ws=new WebSocket(pages.find(p=>p.type==='page').webSocketDebuggerUrl);
 await new Promise((r,j)=>{ws.onopen=r;ws.onerror=j;});
 let id=0;const pending=new Map();
 ws.onmessage=({data})=>{const m=JSON.parse(data);if(m.id){const p=pending.get(m.id);pending.delete(m.id);m.error?p.reject(Error(JSON.stringify(m.error))):p.resolve(m.result);}};
 function cdp(method,params={}) {return new Promise((resolve,reject)=>{const key=++id;pending.set(key,{resolve,reject});ws.send(JSON.stringify({id:key,method,params}));});}
 await cdp('Page.navigate',{url:`http://localhost:${port}/genie/probe`});
 async function evaluate(expression){const r=await cdp('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true});if(r.exceptionDetails)throw Error(JSON.stringify(r.exceptionDetails));return r.result.value;}
 for(let i=0;i<100;i++){if(await evaluate('!!self.genieFace'))break;await new Promise(r=>setTimeout(r,100));}
 console.log('Loading actual MediaPipe and SFace in Chrome...');
 assert.equal(await evaluate('genieFace.warmup()'),true);
 console.log('Browser worker initialized.');
 const camera=await evaluate(`(async()=>{const v=document.querySelector('video');try{await genieFace.start(v);}catch(error){throw Error(error.message+' '+JSON.stringify({ready:v.readyState,width:v.videoWidth,hidden:document.hidden,tracks:v.srcObject?.getVideoTracks().map(t=>({state:t.readyState,enabled:t.enabled,muted:t.muted,settings:t.getSettings()}))}));}if(v.readyState<2||document.hidden||!v.srcObject?.getVideoTracks().some(t=>t.readyState==='live'))throw Error('Camera state '+JSON.stringify({ready:v.readyState,width:v.videoWidth,hidden:document.hidden,tracks:v.srcObject?.getVideoTracks().map(t=>t.readyState)}));const sample=JSON.parse(await genieFace.sample(v));const tracks=v.srcObject.getTracks();const jpeg=genieFace.snapshot(v);genieFace.stop(v);return {sample,stopped:tracks.every(t=>t.readyState==='ended'),jpeg:jpeg.length>100};})()`);
 assert.equal(camera.sample.faceCount,0);assert(camera.stopped);assert(camera.jpeg);
 const lifecycle=await evaluate(`(async()=>{
   const v=document.querySelector('video'),media=navigator.mediaDevices;
   const original=media.getUserMedia.bind(media);
   try {
     let denied=false,stale=false,snapshotBlocked=false,resolve;
     media.getUserMedia=async()=>{throw new DOMException('Permission denied','NotAllowedError');};
     try{await genieFace.start(v);}catch{denied=true;}
     const stream=await original({video:true,audio:false});
     media.getUserMedia=()=>new Promise(r=>resolve=r);
     const pending=genieFace.start(v);genieFace.stop(v);resolve(stream);
     try{await pending;}catch{stale=true;}
     try{genieFace.snapshot(v);}catch{snapshotBlocked=true;}
     return {denied,stale,snapshotBlocked,stopped:stream.getTracks().every(t=>t.readyState==='ended')};
   } finally {media.getUserMedia=original;genieFace.stop(v);}
 })()`);
 assert.deepEqual(lifecycle,{denied:true,stale:true,snapshotBlocked:true,stopped:true});

 const require=createRequire(import.meta.url);
 const ort=require(path.join(root,'build/face_native_probe/node_modules/onnxruntime-node'));
 const native=await ort.InferenceSession.create(path.join(root,'assets/face_recognition/sface_2021dec.onnx'),{executionProviders:['cpu']});
 let maxDifference=0;
 const browserVectors=[],nativeVectors=[];
 for(let seed=0;seed<8;seed++) {
   const input=Float32Array.from({length:3*112*112},(_,i)=>seed<3?[0,127.5,255][seed]:seed===3?(i*255/(3*112*112-1)):((i*1103515245+seed*12345)>>>0)%256);
   const browserOutput=await evaluate(`genieFace.embed(Float32Array.from(${JSON.stringify(Array.from(input))}))`);
   const expected=(await native.run({data:new ort.Tensor('float32',input,[1,3,112,112])})).fc1.data;
   for(let i=0;i<128;i++) maxDifference=Math.max(maxDifference,Math.abs(expected[i]-browserOutput[i]));
   const normalize=v=>{const n=Math.hypot(...v);return Array.from(v,x=>x/n);};
   browserVectors.push(normalize(browserOutput));nativeVectors.push(normalize(expected));
 }
 for(let i=0;i<8;i++) for(let j=0;j<8;j++) {
   const dot=(a,b)=>a.reduce((sum,v,k)=>sum+v*b[k],0);
   assert.equal(dot(browserVectors[i],browserVectors[j])>=.5,dot(nativeVectors[i],nativeVectors[j])>=.5);
 }
 assert(maxDifference<.0001,`WASM/native inference drift: ${maxDifference}`);
 await native.release();
 console.log('Eight WASM/CPU tensors and all pairwise threshold decisions agree; max absolute error:',maxDifference);
 const output=await evaluate(`genieFace.embed(new Float32Array(3*112*112).fill(127.5))`);
 assert.equal(output.length,128);assert(output.every(Number.isFinite));
 await fs.mkdir(path.join(root,'build/face_browser_test'),{recursive:true});
 await fs.writeFile(path.join(root,'build/face_browser_test/embedding.json'),JSON.stringify(output));
 for(let i=0;i<100;i++){if(await evaluate('!!self.runDartFaceProbe'))break;await new Promise(r=>setTimeout(r,100));}
 const portrait=await fs.readFile(path.join(root,'build/face_browser_test/portrait.jpg'));
 const face=await evaluate(`genieFace.detect(Uint8Array.from(atob('${portrait.toString('base64')}'),c=>c.charCodeAt(0)))`);
 assert.equal(JSON.parse(face).faceCount,1);
 await evaluate('genieFace.release(); delete self.genieFace'); // Exercise Dart lazy script loading.
 const match=JSON.parse(await evaluate(`runDartFaceProbe('${portrait.toString('base64')}')`));
 assert.equal(match.dimensions,128);assert(match.score>=.5);console.log('Dart face pipeline recompression score:',match.score);
 const otherPhoto=await fs.readFile(path.join(root,'build/face_browser_test/lin-manuel-miranda.png'));
 const other=JSON.parse(await evaluate(`runDartFaceProbe('${otherPhoto.toString('base64')}')`));
 const differentScore=match.reference.reduce((sum,v,i)=>sum+v*other.reference[i],0);
 console.log('Different public sample similarity:',differentScore); assert(differentScore<.5);
 await evaluate('genieFace.release()');
 console.log('Passed actual WASM inference, blank-frame rejection, camera capture, denied access, cancelled permission requests and track cleanup.');
} finally {ws?.close();browser.kill();server.close();}
