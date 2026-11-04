const {test}=require('node:test');
const assert=require('node:assert/strict');
const vm=require('node:vm'),fs=require('node:fs'),path=require('node:path');
const script=fs.readFileSync(path.join(__dirname,'../web/erp_page_bridge.js'),'utf8');
test('bundled pages get their channel before page scripts and pass no credentials',()=>{
  const messages=[];
  const parent={postMessage:(data,origin)=>messages.push({data,origin})};
  const window={parent,name:'genie-erp-test'};
  vm.runInNewContext(script,{window,parent,location:{origin:'https://erp.example.test'}});
  for(const name of ['GenieLead','GenieExpenseClaim','GenieLeaveApplication','GenieOpportunities','GeniePendingWork','GenieSalesSummary']) {
    assert.equal(typeof window[name].postMessage,'function');
    window[name].postMessage('{"action":"ready"}');
    const {data,origin}=messages.at(-1);
    assert.equal(data.channel,name);assert.equal(data.token,'genie-erp-test');
    assert.equal(origin,'https://erp.example.test');
    assert.deepEqual(Object.keys(data).sort(),['channel','message','token']);
  }
});
test('standalone pages and unrelated frames do not get a native bridge',()=>{
  for(const top of [true,false]) {
    const window={name:'unrelated'};window.parent=top?window:{};
    vm.runInNewContext(script,{window});assert.equal(window.GeniePendingWork,undefined);
  }
});

function touchPage({interactive=false,scrolled=false,busy=false}={}) {
 const listeners={},messages=[];
 const doc={readyState:'complete',scrollingElement:{scrollTop:0},querySelector:()=>busy?{}:null,addEventListener:(name,fn)=>listeners[name]=fn};
 const parent={postMessage:data=>messages.push(data)};
 const window={parent,name:'genie-erp-test',document:doc,scrollY:0,getComputedStyle:()=>({overflowY:'auto'})};
 const node={closest:()=>interactive?{}:null,scrollHeight:100,clientHeight:50,scrollTop:scrolled?10:0,parentElement:null};
 vm.runInNewContext(script,{window,parent,location:{origin:'https://erp.example.test'}});
 function pull(count=1) {
  listeners.touchstart({target:node,touches:[{clientX:50,clientY:50}]});
  listeners.touchmove({touches:Array.from({length:count},()=>({clientX:52,clientY:160})),preventDefault(){}});
  listeners.touchend();
 }
 return {messages,pull};
}
test('downward pull at the top emits one iframe refresh request',()=>{
 const page=touchPage();page.pull();
 assert.equal(page.messages.length,1);assert.equal(page.messages[0].channel,'__refresh');
});
test('iframe refresh ignores controls, nested scrolling, busy forms and multitouch',()=>{
 for(const options of [{interactive:true},{scrolled:true},{busy:true}]) {
  const page=touchPage(options);page.pull();assert.equal(page.messages.length,0);
 }
 const page=touchPage();page.pull(2);assert.equal(page.messages.length,0);
});
