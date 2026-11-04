import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import http from 'node:http';
import {createRequire} from 'node:module';
const require=createRequire(import.meta.url);
let chromium;
try { ({chromium}=require('playwright')); }
catch { ({chromium}=require(path.join(os.tmpdir(),'genie-lead-webview-qa/node_modules/playwright'))); }
const root=path.resolve(import.meta.dirname,'..');
const output=path.join(root,'build/erp_bridge_probe');
const server=http.createServer(async(req,res)=>{
 try {
  const pathname=decodeURIComponent(new URL(req.url,'http://localhost').pathname);
  if(pathname==='/pages/probe-frame.html') {
   res.setHeader('Content-Type','text/html');
   res.end('<!doctype html><html><head><script src="/erp_page_bridge.js"></script></head><body><script>document.body.dataset.early=String(!!window.GenieExpenseClaim);GenieExpenseClaim.postMessage("ready");</script>Browser bridge fixture</body></html>');return;
  }
  const file=path.resolve(output,'.'+(pathname==='/'?'/index.html':pathname));
  if(!file.startsWith(output+path.sep))throw Error('Invalid path');
  const mime={'.html':'text/html','.js':'application/javascript','.mjs':'application/javascript','.wasm':'application/wasm','.json':'application/json'};
  res.setHeader('Content-Type',mime[path.extname(file)]||'application/octet-stream');
  res.end(await fs.readFile(file));
 }catch{res.statusCode=404;res.end('Not found');}
});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const origin='http://localhost:'+server.address().port;
let browser;
try {
 browser=await chromium.launch({headless:true,executablePath:process.env.CHROME_EXECUTABLE||'C:/Program Files/Google/Chrome/Application/chrome.exe',args:['--no-proxy-server']});
 const page=await browser.newPage({viewport:{width:390,height:844}});
 const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.route('**/*',route=>new URL(route.request().url()).origin===origin?route.continue():route.abort());
 await page.goto(origin);
 await page.waitForFunction(()=>window.genieBridgeProbeState?.messages?.includes('echo'),{timeout:30000});
 const frame=page.frames().find(frame=>frame.url().includes('/pages/probe-frame.html'));
 await frame.evaluate(()=>{
   const target=document.body;
   function fire(type,y,touches=true) {
     const touch=new Touch({identifier:1,target,clientX:50,clientY:y});
     target.dispatchEvent(new TouchEvent(type,{bubbles:true,cancelable:true,touches:touches?[touch]:[],changedTouches:[touch]}));
   }
   fire('touchstart',50);fire('touchmove',160);fire('touchend',160,false);
 });
 await page.waitForFunction(()=>window.genieBridgeProbeState?.refreshes===1);
 const state=await page.evaluate(()=>window.genieBridgeProbeState);
 assert.equal(state.earlyBridge,true,'Channel must exist before the ERP page script');
 assert.equal(state.crossOriginBlocked,true);
 assert.equal(state.refreshes,1);
 assert.deepEqual(state.messages,['ready','echo']);
 assert.deepEqual(errors,[]);
 console.log('Real Chrome iframe bridge passed:',JSON.stringify(state));
} finally {await browser?.close();await new Promise(r=>server.close(r));}
