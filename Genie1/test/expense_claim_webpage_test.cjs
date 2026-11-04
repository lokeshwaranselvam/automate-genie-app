const {test,before,after}=require('node:test');
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {chromium}=require('playwright');
let browser;
before(async()=>{browser=await chromium.launch({headless:true,executablePath:'C:/Program Files/Google/Chrome/Application/chrome.exe'});});
after(async()=>{await browser?.close();});
async function setup(){
 const page=await browser.newPage({viewport:{width:390,height:844}}),posts=[];
 const options={employee:'EMP-1',expense_approver:'approver@example.test',currency:'INR',csrf_token:'csrf',supports_multiple_expenses:true,employee_options:[{value:'EMP-1',label:'Staff'}],expense_approver_options:[{value:'approver@example.test',label:'Approver'}],expense_types:[{value:'Travel',label:'Travel'},{value:'Meals',label:'Meals'}]};
 await page.route('https://erp.example.test/**',route=>{
  const request=route.request(),url=new URL(request.url());
  if(url.pathname==='/genie-expense-claim')return route.fulfill({contentType:'text/html',body:'<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head><body>'+fs.readFileSync(path.join(__dirname,'../web_pages/expense-claim.html'),'utf8')+'</body></html>'});
  if(url.pathname.endsWith('get_logged_user'))return route.fulfill({json:{message:'staff@example.test'}});
  if(url.pathname==='/app')return route.fulfill({contentType:'text/html',body:'<script>frappe.csrf_token="csrf";</script>'});
  assert.equal(url.pathname,'/api/method/create_expense_claim_from_mobile');
  if(request.method()==='POST')posts.push(request.postData());
  return route.fulfill({json:{message:options}});
 });
 await page.goto('https://erp.example.test/genie-expense-claim');
 await page.locator('#ec-amount-1').waitFor();
 return {page,posts};
}
test('expense page preserves row values, recalculates total, and fits a narrow browser',async()=>{
 const {page}=await setup();
 try{
  await page.locator('#ec-amount-1').fill('12.50');
  await page.locator('#ec-description-1').fill('Taxi');
  await page.getByRole('button',{name:'+ Add Expense',exact:true}).click();
  await page.locator('#ec-amount-2').fill('20');
  assert.match(await page.locator('#ec-total').textContent(),/32.50/);
  await page.getByRole('button',{name:'Remove expense 2',exact:true}).click();
  assert.equal(await page.locator('#ec-amount-1').inputValue(),'12.50');
  assert.equal(await page.locator('#ec-description-1').inputValue(),'Taxi');
  await page.setViewportSize({width:320,height:740});
  assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1));
  await page.screenshot({path:path.join(__dirname,'../build/expense-pwa-preview.png'),fullPage:true});
 }finally{await page.close();}
});
test('expense calendar permits previous months',async()=>{
 const {page}=await setup();try{
  await page.locator('#ec-date-1').click();
  assert.equal(await page.getByRole('button',{name:'Previous month',exact:true}).isEnabled(),true);
 }finally{await page.close();}
});
test('expense submission without a bill stays local and preserves the draft',async()=>{
 const {page,posts}=await setup();try{
  await page.locator('#ec-type-1').click();
  await page.getByRole('option',{name:'Travel',exact:true}).click();
  await page.locator('#ec-amount-1').fill('12.50');
  await page.locator('#ec-description-1').fill('Taxi');
  await page.locator('#ec-submit').click();
  await page.locator('#ec-dialog[open]').waitFor();
  assert.match(await page.locator('#ec-dialog').textContent(),/Attach a bill/);
  assert.equal(posts.length,0);assert.equal(await page.locator('#ec-amount-1').inputValue(),'12.50');
 }finally{await page.close();}
});
