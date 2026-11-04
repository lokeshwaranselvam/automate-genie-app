const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),vm=require('node:vm');
const {parseHTML}=require(path.join(os.tmpdir(),'genie-opportunities-qa/node_modules/linkedom'));
const source=fs.readFileSync(path.join(__dirname,'../web_pages/sales-summary.html'),'utf8');
const script=source.match(/<script>([\s\S]*?)<\/script>/)[1];
const user='sales@example.test';
const summary={user,scope:'own_opportunities',prospect_count:3,pipeline_count:2,total_count:5,as_of:'2026-11-02 13:00:00'};
function setup(handler, native=false){
  const {document}=parseHTML(source.replace(/<script>[\s\S]*?<\/script>/,''));
  const events={},requests=[],messages=[];
  const window={location:{origin:'https://erp.example.test'},addEventListener:(name,fn)=>events[name]=fn,
    ...(native?{GenieSalesSummary:{postMessage:value=>{
      messages.push(value);
      if(value==='verify_session')Promise.resolve().then(()=>events['genie-sales-summary-verified']?.({detail:{valid:true,user:context.api.state.expectedUser}}));
    }}}:{})};
  const context=vm.createContext({document,window,URL,AbortController,setTimeout,clearTimeout,console,
    fetch:async(url,init)=>{
      const request={url:new URL(url),...init};requests.push(request);
      const result=await handler(request);
      return {ok:(result.status||200)<400,status:result.status||200,json:async()=>({message:result.message})};
    }});
  vm.runInContext(script.replace("  if(native)status('Opening", "  globalThis.api={state,load};\n  if(native)status('Opening"),context);
  return {document,api:context.api,requests,messages,event:(name,detail)=>events[name]?.({detail})};
}
const tick=()=>new Promise(resolve=>setImmediate(resolve));
async function settle(env){for(let i=0;i<25;i++){await tick();if(!env.api.state.busy)return;}throw Error('Did not settle');}
const standard=req=>({message:req.url.pathname.endsWith('get_logged_user')?user:summary});

test('combined page contains no external dependencies, credentials or Jinja openers',()=>{
  new vm.Script(script);
  assert.ok(!/<script\s+src=|<link\s|api_key|api_secret|\{[{%#]/i.test(source));
});
test('live counts use the session API without any username in the URL',async()=>{
  const env=setup(standard);await settle(env);
  assert.equal(env.document.getElementById('ss-prospect').textContent,'3');
  assert.equal(env.document.getElementById('ss-pipeline').textContent,'2');
  assert.equal(env.document.getElementById('ss-total').textContent,'5');
  assert.equal(env.document.getElementById('ss-counts').hidden,false);
  assert.equal(env.requests.filter(req=>req.url.pathname.endsWith('mobile_sales_summary')).length,1);
  for(const req of env.requests){assert.equal(req.url.search,'');assert.equal(req.credentials,'same-origin');assert.equal(req.cache,'no-store');assert.equal(req.redirect,'error');}
});
test('authorized zero counts display as zero',async()=>{
  const env=setup(req=>req.url.pathname.endsWith('get_logged_user')?{message:user}:{message:{...summary,prospect_count:0,pipeline_count:0,total_count:0}});
  await settle(env);assert.equal(env.document.getElementById('ss-total').textContent,'0');assert.equal(env.document.getElementById('ss-counts').hidden,false);
});
test('403 and offline errors hide old counts and allow retry',async()=>{
  let fail=false;
  const env=setup(req=>fail&&!req.url.pathname.endsWith('get_logged_user')?{status:403}:standard(req));
  await settle(env);fail=true;await env.api.load();
  assert.equal(env.document.getElementById('ss-counts').hidden,true);assert.match(env.document.getElementById('ss-status').textContent,/permission/);
  fail=false;await env.api.load();assert.equal(env.document.getElementById('ss-counts').hidden,false);
});
test('account changes during the request do not display the previous user counts',async()=>{
  let checks=0;
  const env=setup(req=>({message:req.url.pathname.endsWith('get_logged_user')?(++checks===1?user:'other@example.test'):summary}));
  await settle(env);assert.equal(env.api.state.stopped,true);assert.equal(env.document.getElementById('ss-counts').hidden,true);
});
test('mismatched owner, scope, negative or inconsistent counts fail closed',async()=>{
  for(const change of [{user:'another@example.test'},{scope:'team'},{prospect_count:-1},{total_count:88},{pipeline_count:'2'}]){
    const env=setup(req=>req.url.pathname.endsWith('get_logged_user')?{message:user}:{message:{...summary,...change}});
    await settle(env);assert.equal(env.document.getElementById('ss-counts').hidden,true);
  }
});
test('native page waits for app identity and rejects a different cookie user',async()=>{
  const env=setup(standard,true);await tick();assert.equal(env.requests.length,0);
  env.event('genie-sales-summary-session',{user:'other@example.test'});await settle(env);
  assert.equal(env.api.state.stopped,true);assert.ok(env.messages.includes('session_expired'));
});
test('native page with matching user displays the summary and repeated handshake does not refetch',async()=>{
  const env=setup(standard,true);env.event('genie-sales-summary-session',{user});await settle(env);
  assert.equal(env.document.getElementById('ss-total').textContent,'5');
  const count=env.requests.length;env.event('genie-sales-summary-session',{user});await settle(env);assert.equal(env.requests.length,count);
});
test('overlapping refresh requests are coalesced and rendered content is text',async()=>{
  let release;
  const env=setup(req=>req.url.pathname.endsWith('get_logged_user')?{message:user}:new Promise(resolve=>release=()=>resolve({message:{...summary,as_of:'<img src=x onerror=alert(1)>'}})));
  await tick();await env.api.load();assert.equal(env.requests.filter(req=>req.url.pathname.endsWith('mobile_sales_summary')).length,1);
  release();await settle(env);assert.equal(env.document.querySelectorAll('img').length,0);assert.match(env.document.getElementById('ss-asof').textContent,/<img/);
});
