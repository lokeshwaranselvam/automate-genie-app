// Actual Chromium/WASM smoke test; no camera, login, or employee fixtures.
import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import {spawn} from 'node:child_process';
import assert from 'node:assert/strict';

const root = path.resolve(import.meta.dirname, '..');
const server = http.createServer(async (req, res) => {
  try {
    const name = new URL(req.url, 'http://localhost').pathname;
    const relative = name.replace(/^\/genie\//, '');
    const directory = relative.startsWith('assets/assets/') ? root : path.join(root, 'web');
    const target = path.resolve(directory, relative.replace(/^assets\/assets\//, 'assets/'));
    if (!name.startsWith('/genie/') || !target.startsWith(directory + path.sep)) throw Error('Invalid path');
    const mime = {'.html':'text/html', '.js':'text/javascript', '.mjs':'text/javascript', '.wasm':'application/wasm'};
    res.setHeader('Content-Type', mime[path.extname(target)] || 'application/octet-stream');
    res.end(await fs.readFile(target));
  } catch (_) { res.statusCode = 404; res.end('Missing test asset'); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const profile = path.join(root, 'build', 'face-diagnostics-profile-' + Date.now());
await fs.mkdir(profile, {recursive:true});
const browser = spawn(process.env.CHROME_EXECUTABLE || 'C:/Program Files/Google/Chrome/Application/chrome.exe', [
  '--headless=new', '--no-first-run', '--no-default-browser-check', '--remote-debugging-port=0',
  ...(process.argv.includes('--ios-user-agent') ? [
    '--user-agent=Mozilla/5.0 (iPhone; CPU iPhone OS 26_5_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/156.0.8078.54 Mobile/15E148 Safari/604.1',
  ] : []),
  '--user-data-dir=' + profile, 'about:blank',
], {windowsHide:true, stdio:'ignore'});
let socket;
try {
  let port;
  for (let attempt = 0; attempt < 100; attempt++) {
    try { port = Number((await fs.readFile(path.join(profile, 'DevToolsActivePort'), 'utf8')).split('\n')[0]); break; }
    catch (_) { await new Promise(resolve => setTimeout(resolve, 100)); }
  }
  assert(port, 'Chrome did not start');
  const pages = await (await fetch(`http://localhost:${port}/json/list`)).json();
  socket = new WebSocket(pages.find(page => page.type === 'page').webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
  let sequence = 0;
  const pending = new Map();
  socket.onmessage = ({data}) => {
    const result = JSON.parse(data);
    if (!result.id) return;
    const entry = pending.get(result.id); pending.delete(result.id);
    result.error ? entry.reject(Error(JSON.stringify(result.error))) : entry.resolve(result.result);
  };
  const cdp = (method, params = {}) => new Promise((resolve, reject) => {
    const id = ++sequence; pending.set(id, {resolve, reject});
    socket.send(JSON.stringify({id, method, params}));
  });
  async function evaluate(expression) {
    const result = await cdp('Runtime.evaluate', {expression, awaitPromise:true, returnByValue:true});
    if (result.exceptionDetails) throw Error(JSON.stringify(result.exceptionDetails));
    return result.result.value;
  }
  await cdp('Page.navigate', {url:`http://localhost:${server.address().port}/genie/face/diagnostics.html`});
  for (let attempt = 0; attempt < 100; attempt++) {
    if (await evaluate('!!document.getElementById("run")?.onclick')) break;
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  await cdp('Emulation.setDeviceMetricsOverride', {width:390, height:844, deviceScaleFactor:1, mobile:true});
  const screenshot = await cdp('Page.captureScreenshot', {format:'png', captureBeyondViewport:true});
  await fs.writeFile(path.join(root, 'build', 'face-diagnostics.png'), Buffer.from(screenshot.data, 'base64'));
  // Verify each isolated mode with the current app settings, then alternative settings.
  for (const config of [
    {mode:'onnx'}, {mode:'sface'}, {mode:'mediapipe'}, {mode:'combined'},
    {mode:'sface', optimization:'basic', noArena:true, noPattern:true},
  ]) {
    const report = await evaluate(`(async () => {
      const config = ${JSON.stringify(config)};
      document.getElementById('mode').value = config.mode;
      document.getElementById('optimization').value = config.optimization || 'all';
      document.getElementById('noArena').checked = !!config.noArena;
      document.getElementById('noPattern').checked = !!config.noPattern;
      document.getElementById('run').click();
      while (document.getElementById('run').disabled) await new Promise(r => setTimeout(r, 100));
      return JSON.parse(document.getElementById('log').textContent).at(-1);
    })()`);
    console.log(JSON.stringify(report));
    assert.equal(report.status, 'passed');
    assert(report.stages.some(stage => stage.status === 'passed'));
    if (config.mode === 'onnx') assert(!report.stages.some(stage => /SFace|MediaPipe/.test(stage.stage)));
    if (config.mode === 'sface') assert(!report.stages.some(stage => /MediaPipe/.test(stage.stage)));
    if (config.mode === 'mediapipe') assert(!report.stages.some(stage => /ONNX|SFace/.test(stage.stage)));
  }
  // Force an allocation error to verify visible failure evidence and worker teardown.
  const failure = await evaluate(`(async () => {
    self.Worker = class {
      postMessage() { queueMicrotask(() => {
        this.onmessage({data:{diagnostic:{stage:'Synthetic allocation failure',status:'started',elapsedMs:0}}});
        this.onmessage({data:{id:1,error:'RangeError: Out of memory'}});
      }); }
      terminate() { self.testWorkerTerminated = true; }
    };
    document.getElementById('run').click();
    await new Promise(r => setTimeout(r, 10));
    return {report:JSON.parse(document.getElementById('log').textContent).at(-1), terminated:self.testWorkerTerminated};
  })()`);
  assert.equal(failure.report.status, 'failed');
  assert.match(failure.report.error, /Out of memory/);
  assert.equal(failure.report.stages.at(-1).stage, 'Synthetic allocation failure');
  assert.equal(failure.terminated, true);
  console.log('Passed isolated real WASM modes, settings probe, failure reporting and worker teardown.');
} finally { socket?.close(); browser.kill(); server.close(); }
