/* Test-only DOM tool follows the existing webpage tests; no app dependency. */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), os = require('node:os'), vm = require('node:vm');
const { parseHTML } = require(path.join(os.tmpdir(), 'genie-opportunities-qa/node_modules/linkedom'));
const source = fs.readFileSync(path.join(__dirname, '../web_pages/pending-work.html'), 'utf8');
const script = source.match(/<script>([\s\S]*?)<\/script>/)[1];
const user = 'staff@example.test';
const sales = {available_sections:['opportunities','overdue_followups','overdue_closing','draft_delivery_plans'],opportunities:{count:1},overdue_followups:{count:0},overdue_closing:{count:0},draft_delivery_plans:{count:0},stock:{count:99}};
const rows = [{name:'OPP-1',customer_name:'Test',opportunity_id:'OPP-1',created_by:user}];
function setup(handler, native=false) {
  const {document} = parseHTML(source.replace(/<script>[\s\S]*?<\/script>/, ''));
  const events = new Map(), calls=[], messages=[], locations=[];
  const window = {
    location:{origin:'https://erp.example.test',assign:value=>locations.push(value)},history:{length:1,back(){}},
    addEventListener:(name,fn)=>events.set(name,fn),
    ...(native?{GeniePendingWork:{postMessage:value=>messages.push(JSON.parse(value))}}:{}),
  };
  const context = vm.createContext({document,window,URL,URLSearchParams,AbortController,setTimeout,clearTimeout,console,
    fetch:async(url,init)=>{
      const request={url:new URL(url),...init};calls.push(request);
      const result=await handler(request);
      return {ok:(result.status||200)<400,status:result.status||200,json:async()=>({message:result.message})};
    },
  });
  const exposed=script.replace('  if(native)content.append', '  globalThis.api={state,refresh,back,openSection,openItem,openSvr,available,sections,summary,sectionView,refreshDetail};\n  if(native)content.append');
  vm.runInContext(exposed,context);
  return {api:context.api,document,window,calls,messages,locations,event:(name,detail)=>events.get(name)?.({detail})};
}
const tick=()=>new Promise(resolve=>setImmediate(resolve));
async function settle(env) {for(let i=0;i<25;i++){await tick();if(!env.api.state.busy)return;}throw Error('Did not settle');}
function handler(request) {
  if(request.url.pathname.endsWith('get_logged_user'))return {message:user};
  assert.equal(request.url.pathname,'/api/method/get_pending_work');
  return {message:request.url.searchParams.get('action')==='dashboard'?sales:{items:rows}};
}

test('combined page is self contained and uses existing read APIs only',()=>{
  new vm.Script(script);
  assert.ok(!/<script\s+src=|<link\s|api_secret|api_key|\{[{%#]/i.test(source));
  assert.match(source, /data:font\/ttf;base64/);
  assert.match(source, /Embedded font\/icon licenses/);
  assert.ok(source.includes('handshake_outlined'));
});
test('role list controls zero-count cards, team grouping, total, and SVR',async()=>{
  const env=setup(handler);await settle(env);
  const text=env.document.getElementById('pw-content').textContent;
  assert.match(text,/Sales Team/);assert.match(text,/SVR/);
  assert.ok(!text.includes('Production Team'));assert.ok(!text.includes('Pending Transferred MTM'));
  assert.equal(env.document.querySelector('.pw-total').textContent,'1');
  assert.equal(env.document.querySelectorAll('.pw-category').length,5);
  assert.ok(env.calls.every(call=>call.credentials==='same-origin'&&call.cache==='no-store'&&call.redirect==='error'));
});
test('older dashboard map fallback and explicit empty access both retain visibility policy',async()=>{
  const env=setup(handler);await settle(env);
  assert.deepEqual(Array.from(env.api.available({stock:{count:0},opportunities:{count:0}}),row=>row[0]),['stock','opportunities']);
  assert.equal(env.api.available({...sales,available_sections:[]}).length,0);
});
test('category retains summary, search, index mapping and selected Opportunity route',async()=>{
  const env=setup(handler);await settle(env);
  env.api.openSection(env.api.sections.find(row=>row[0]==='opportunities'));await settle(env);
  assert.equal(env.document.getElementById('pw-title').textContent,'Open Opportunities');
  assert.equal(env.document.querySelector('.pw-total').textContent,'1');
  assert.match(env.document.querySelector('.pw-item').textContent,/Test/);
  assert.ok(!env.document.querySelector('.pw-item').textContent.includes(user));
  const input=env.document.getElementById('pw-query');input.value='missing';input.dispatchEvent(new env.document.defaultView.Event('input'));
  assert.match(env.document.getElementById('pw-items').textContent,/No matching items/);
  input.value='opp-1';input.dispatchEvent(new env.document.defaultView.Event('input'));
  assert.equal(env.document.querySelectorAll('.pw-item').length,1);
  await env.api.openItem(0);
  const url=new URL(env.locations[0]);assert.equal(url.pathname,'/genie-opportunities');assert.equal(new URLSearchParams(url.hash.slice(1)).get('opportunity'),'OPP-1');
});
test('data containing markup renders as text without executable DOM',async()=>{
  const env=setup(req=>req.url.pathname.endsWith('get_logged_user')?{message:user}:req.url.searchParams.get('action')==='dashboard'?{message:sales}:{message:{items:[{name:'X',subject:'<img src=x onerror=alert(1)>'}]}});
  await settle(env);env.api.openSection(env.api.sections[4]);await settle(env);
  assert.equal(env.document.querySelectorAll('.pw-item img').length,0);
  assert.match(env.document.querySelector('.pw-item').textContent,/<img/);
});
test('network failure shows retry and session change clears visible data',async()=>{
  let fail=true;
  const env=setup(req=>{if(req.url.pathname.endsWith('get_logged_user'))return {message:user};if(fail)throw Error('Offline');return handler(req);});
  await settle(env);assert.match(env.document.getElementById('pw-content').textContent,/Offline/);
  assert.ok(env.document.querySelector('.pw-retry'));fail=false;await env.api.refresh();
  assert.ok(env.document.querySelector('.pw-total'));
  env.api.state.user='another@example.test';await env.api.refresh();
  assert.equal(env.api.state.stopped,true);assert.equal(env.document.querySelector('.pw-total'),null);
});
test('native mode waits for session and uses the existing Flutter API bridge',async()=>{
  const env=setup(()=>{throw Error('Browser fetch must not run in native mode');},true);
  assert.equal(env.messages.length,0);
  env.event('genie-pending-session',{user});await tick();
  const request=env.messages[0];assert.equal(request.action,'dashboard');
  env.event('genie-pending-result',{id:request.id,value:sales});await settle(env);
  env.api.openSection(env.api.sections[4]);await tick();
  const section=env.messages[1];assert.equal(section.action,'section');assert.equal(section.section,'opportunities');
  env.event('genie-pending-result',{id:section.id,value:{items:rows,names:{[user]:'Staff'}}});await settle(env);
  assert.match(env.document.querySelector('.pw-item').textContent,/Staff/);
  const opened=env.api.openItem(0);await tick();
  const open=env.messages[2];assert.equal(open.index,0);assert.equal(open.action,'open');assert.ok(!('item' in open));
  env.event('genie-pending-result',{id:open.id,value:null});await tick();
  const reload=env.messages[3];env.event('genie-pending-result',{id:reload.id,value:{items:rows}});await opened;await settle(env);
});
test('back during a load drops its stale result and refreshes the overview',async()=>{
  let release;
  const env=setup(req=>req.url.searchParams.get('action')==='opportunities'?new Promise(resolve=>release=()=>resolve({message:{items:rows}})):handler(req));
  await settle(env);env.api.openSection(env.api.sections[4]);await tick();
  env.api.back();release();await settle(env);await tick();await settle(env);
  assert.equal(env.api.state.section,null);assert.equal(env.document.getElementById('pw-title').textContent,'Pending Work');
  assert.equal(env.document.querySelector('.pw-item'),null);
});
test('overdue summaries preserve dates, days overdue and customer titles',async()=>{
  const env=setup(handler);await settle(env);
  for(const [key,date,label] of [['overdue_followups','next_followup_date','Due'],['overdue_closing','expected_closing_date','Closing date']]){
    env.api.state.section=env.api.sections.find(row=>row[0]===key);
    const info=env.api.summary({customer:'Customer',opportunity:'OPP-2',status:'Open',[date]:'2026-10-01',overdue_days:4});
    assert.equal(info.title,'Customer');assert.ok(info.subtitle.includes(label+' 2026-10-01'));assert.match(info.subtitle,/4 days overdue/);
  }
});
