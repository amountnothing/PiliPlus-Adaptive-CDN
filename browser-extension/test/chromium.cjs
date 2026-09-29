// Real Chromium transport regression. Run separately from dependency-free unit tests.
const {chromium} = require(process.env.PLAYWRIGHT_MODULE || '../../dist/.qa/node_modules/playwright');
const fs=require('node:fs');const assert=require('node:assert/strict');const path=require('node:path');
(async()=>{
 const browser=await chromium.launch({headless:true});let count=0;
 const flush=()=>new Promise(r=>setTimeout(r,150));
 // Deterministic settle: assertions that expect a count to be REACHED wait a
 // bounded real-time window (route fulfillment / request dispatch can land
 // after the flush under load); assertions that expect NO change keep the
 // plain flush so an early switch still fails fast.
 const settle=async(page,check)=>{for(let i=0;i<20&&!check();i++)await page.waitForTimeout(100);await flush();};
 // install() starts the injected clock in real-time-sync mode (Playwright 1.63
 // injects it resumed: a <=100ms embedder timer advances fake time with wall
 // time). pauseAt() to the install instant therefore races a "Cannot
 // fast-forward to the past" error whenever the CDP round trip stalls >100ms.
 // Pausing at install + 1h is drift-immune; the fixture page has no pending
 // timers, so the fast-forward itself is a no-op. All later budgets are
 // runFor()/Date.now() deltas and unaffected by the absolute offset.
 const pauseClock=async page=>{
  await page.clock.install({time:new Date('2026-01-01T00:00:00Z')});
  await page.clock.pauseAt(new Date('2026-01-01T01:00:00Z'));
 };
 try {
  for(const transport of ['fetch','xhr'])for(const failure of [403,404,500,503,'reject','timeout','exhaust']){
   const page=await browser.newPage(); const calls=[];const errors=[];page.on('pageerror',e=>errors.push(e.message));
   await page.route('https://www.bilibili.com/**',r=>r.fulfill({body:'<!doctype html><title>CDN transport fixture</title>'}));
   await page.route('https://*.bilivideo.com/**',async r=>{
    calls.push({url:r.request().url(),range:r.request().headers().range});
    if(calls.length===1&&failure==='reject')return r.abort('failed');
    if(calls.length===1&&failure==='timeout')return; // Native XHR timeout / fetch header deadline.
    return r.fulfill({status:failure==='exhaust'?403:calls.length===1&&typeof failure==='number'?failure:206,body:'1234567890',headers:{'access-control-allow-origin':'*','content-type':'application/octet-stream'}});
   });
   await page.goto('https://www.bilibili.com/video/BVfixture');
   // Accelerate Date and script deadlines together, not just the timeout callback.
   // Ratio 10 keeps real network latency (a few ms) well under the compressed
   // 5s pre-first-byte deadline (500ms real); 100 raced real fetch latency.
   await page.evaluate(()=>{const timer=window.setTimeout, dateNow=Date.now, start=dateNow();Date.now=()=>start+(dateNow()-start)*10;window.setTimeout=(fn,ms,...args)=>timer(fn,ms/10,...args);});
   for(const file of (process.env.USERSCRIPT_FILE ? [path.resolve(process.env.USERSCRIPT_FILE)] : ['core.js','page.js'].map(f=>path.join(__dirname,'..',f))))await page.addScriptTag({content:fs.readFileSync(file,'utf8')});
   const result=await page.evaluate(async({transport,failure})=>{
    const urls=['a','b','c'].map(h=>`https://${h}.bilivideo.com/v.m4s`);
    window.__playinfo__={data:{dash:{video:[{baseUrl:urls[0],backupUrl:urls.slice(1),mimeType:'video/mp4'}]}}};
    if(transport==='fetch'){const r=await fetch(urls[0],{headers:{Range:'bytes=10-19'}});return {status:r.status,body:await r.text()};}
    return new Promise(resolve=>{const xhr=new XMLHttpRequest();const done=[];xhr.open('GET',urls[0]);xhr.responseType='arraybuffer';xhr.timeout=failure==='timeout'?50:5000;xhr.setRequestHeader('Range','bytes=10-19');xhr.onreadystatechange=()=>{if(xhr.readyState===4)done.push(xhr.status);};xhr.onloadend=()=>resolve({status:xhr.status,done,body:new TextDecoder().decode(xhr.response||new ArrayBuffer(0))});xhr.send();});
   },{transport,failure});
   assert.equal(result.status,failure==='exhaust'?403:206,`${transport} ${failure}`);
   assert.equal(calls.length,failure==='exhaust'?3:2,`${transport} ${failure} count`);
   assert.deepEqual(calls.map(c=>c.range),calls.map(()=>'bytes=10-19'));
   if(transport==='xhr')assert.deepEqual(result.done,[result.status]);
   assert.deepEqual(errors,[]);console.log(`PASS Chromium ${transport} ${failure}`);count++;await page.close();
  }
  for(const transport of ['fetch','xhr'])for(const action of ['manual','reset','fatal']){
   const page=await browser.newPage();const calls=[];const errors=[];page.on('pageerror',e=>errors.push(e.message));
   await page.route('https://www.bilibili.com/**',r=>r.fulfill({body:'<!doctype html><video></video>'}));
   await page.route('https://*.bilivideo.com/**',r=>{
    calls.push(r.request().url());if(calls.length===1)return;
    return r.fulfill({status:206,body:'ok',headers:{'access-control-allow-origin':'*'}});
   });
   await page.goto('https://www.bilibili.com/video/BVfixture');
   for(const file of (process.env.USERSCRIPT_FILE ? [path.resolve(process.env.USERSCRIPT_FILE)] : ['core.js','page.js'].map(f=>path.join(__dirname,'..',f))))await page.addScriptTag({content:fs.readFileSync(file,'utf8')});
   await page.evaluate(({transport})=>{
    const a='https://a.bilivideo.com/v.m4s',b='https://b.bilivideo.com/v.m4s';
    window.info={dash:{video:[{baseUrl:a,backupUrl:[b],mimeType:'video/mp4'}]}};window.__playinfo__=window.info;
    window.result=transport==='fetch'?fetch(a).then(r=>r.status,()=>0):new Promise(resolve=>{
     const xhr=new XMLHttpRequest();xhr.open('GET',a);xhr.onloadend=()=>resolve(xhr.status);xhr.send();
    });
   },{transport});
   await page.waitForTimeout(100);assert.equal(calls.length,1);
   await page.evaluate(async({action})=>{
    if(action==='manual')window.postMessage({source:'pili-adaptive-cdn-bridge',type:'manual-switch'},'*');
    if(action==='reset'){history.pushState({},'', '/video/BVnew');window.__playinfo__=structuredClone(window.info);}
    if(action==='fatal'){
     const v=document.querySelector('video');v.currentTime=73.5;
     // Native Chromium MediaError, not a fabricated error object. Invalid media
     // exercises terminal handling; this does NOT prove poisoned MSE recovery.
     await new Promise(resolve=>{v.addEventListener('error',resolve,{once:true});v.src='data:video/mp4;base64,AAAA';v.load();});
     window.fatalPosition=v.currentTime;v.dispatchEvent(new Event('error'));v.dispatchEvent(new Event('error'));
    }
   },{action});
   const status=await page.evaluate(()=>window.result);assert.equal(status,action==='reset'?0:206);
   assert.equal(calls.length,action==='reset'?1:2);
   if(action!=='reset')assert.ok(calls[1].includes('b.bilivideo.com'));
   if(action==='fatal'){
    await page.waitForTimeout(100);
    const state=await page.evaluate(()=>({paused:document.querySelector('video').paused,position:document.querySelector('video').currentTime,checkpoint:window.fatalPosition,error:!!document.querySelector('video').error,text:document.getElementById('pili-adaptive-cdn-toast-host')?.textContent}));
    assert.equal(state.paused,true);assert.equal(state.position,state.checkpoint);assert.equal(state.error,true);assert.match(state.text,/手动重载/);
   }
   assert.deepEqual(errors,[]);console.log(`PASS Chromium ${transport} ${action}`);count++;await page.close();
  }
  // Native routed failures with the script clock paused at exact deadlines.
  for(const transport of ['fetch','xhr','mixed'])for(const action of ['403','timeout','pause','reset']){
   const page=await browser.newPage(),calls=[],errors=[];page.on('pageerror',e=>errors.push(e.message));
   await page.route('https://www.bilibili.com/**',r=>r.fulfill({body:'<!doctype html><video></video>'}));
   await page.route('https://*.bilivideo.com/**',r=>{calls.push({url:r.request().url(),range:r.request().headers().range});if(action==='timeout')return;return r.fulfill({status:403,body:'denied',headers:{'access-control-allow-origin':'*'}});});
   await page.goto('https://www.bilibili.com/video/BVclock');await pauseClock(page);
   for(const file of (process.env.USERSCRIPT_FILE?[path.resolve(process.env.USERSCRIPT_FILE)]:['core.js','page.js'].map(f=>path.join(__dirname,'..',f))))await page.addScriptTag({content:fs.readFileSync(file,'utf8')});
   await page.evaluate(({transport,action})=>{
    const urls=['a','b','c'].map(h=>`https://${h}.bilivideo.com/v.m4s`);window.info={dash:{video:[{baseUrl:urls[0],backupUrl:urls.slice(1),mimeType:'video/mp4'}]}};window.__playinfo__=window.info;
    window.done=0;window.pending=Promise.all(Array.from({length:4},(_,i)=>{
     if(transport==='fetch'||transport==='mixed'&&i%2===0)return fetch(urls[0],{headers:{Range:`bytes=${i*10}-${i*10+9}`}}).then(r=>r.status,()=>0).then(v=>{window.done++;return v;});
     // xhr.timeout counts REAL time (not faked by page.clock), so a 50ms
     // value races the 403 fulfillment under load and turns a definitive
     // http-error into a 15s silence window. 50ms is only wanted by the
     // 'timeout' action, whose route never fulfills.
     return new Promise(resolve=>{const x=new XMLHttpRequest();x.open('GET',urls[0]);x.timeout=action==='timeout'?50:5000;x.setRequestHeader('Range',`bytes=${i*10}-${i*10+9}`);x.onloadend=()=>{window.done++;resolve(x.status);};x.send();});
    }));
   },{transport,action});
   await settle(page,()=>calls.length>=4);assert.equal(calls.length,4);
   if(action==='reset'){
    await page.clock.runFor(1000);await page.evaluate(()=>{history.pushState({},'', '/video/BVnext');window.__playinfo__=structuredClone(window.info);});
    await settle(page,async()=>(await page.evaluate(()=>window.done))>=4);assert.equal(await page.evaluate(()=>window.done),4);await page.clock.runFor(60000);await flush();assert.equal(calls.length,4);
   }else if(action==='pause'){
    // A player-initiated pause no longer aborts the pending recovery: the
    // definitive 403 cooldown still fires and the retry re-requests B.
    await page.clock.runFor(1000);await page.evaluate(()=>document.querySelector('video').dispatchEvent(new Event('pause')));await flush();
    await page.clock.runFor(800);await flush();assert.equal(calls.length,4);
    await page.clock.runFor(200);await settle(page,()=>calls.length>=8);assert.equal(calls.length,8);assert.ok(calls.slice(4).every(c=>c.url.includes('b.bilivideo.com')));
    // Pause blocks NEW recovery waits only: the in-flight retry survived and
    // re-requested B at the 2s deadline; a failure of B itself while still
    // paused is not retried further (no new wait), so it stops at 8 calls.
    await page.clock.runFor(59000);await flush();assert.equal(calls.length,8);assert.equal(await page.evaluate(()=>window.done),4);
   }else if(action==='403'){
    // Definitive failures wait only the 2s cooldown per candidate: 0/2/4s.
    // Transition budgets are anchored to the paused clock reading at the
    // previous transition (cooldown deadlines are anchor+2000±1 tick), so a
    // few ms of scheduling jitter cannot land a deadline on the wrong side
    // of an exact runFor() budget.
    await page.clock.runFor(1999);await flush();assert.equal(calls.length,4);
    await page.clock.runFor(2);await settle(page,()=>calls.length>=8);assert.equal(calls.length,8);assert.ok(calls.slice(4).every(c=>c.url.includes('b.bilivideo.com')));
    const anchorB=await page.evaluate(()=>Date.now());
    await page.clock.runFor(1997);await flush();assert.equal(calls.length,8);
    await page.clock.runFor(5);await settle(page,()=>calls.length>=12);assert.equal(calls.length,12);
    assert.equal(await page.evaluate(()=>window.done),0);await page.clock.runFor(4000);await settle(page,async()=>(await page.evaluate(()=>window.done))>=4);assert.equal(await page.evaluate(()=>window.done),4);
    await page.clock.runFor(60000);await flush();assert.equal(calls.length,12);
   }else{
    // Silence still waits the full 15s observation window per candidate: 0/15/30s.
    await page.clock.runFor(10000);await flush();assert.equal(calls.length,4);await page.clock.runFor(4999);assert.equal(calls.length,4);
    await page.clock.runFor(2);await settle(page,()=>calls.length>=8);assert.equal(calls.length,8);assert.ok(calls.slice(4).every(c=>c.url.includes('b.bilivideo.com')));
    const anchorB=await page.evaluate(()=>Date.now());
    await page.clock.runFor(14997);await flush();assert.equal(calls.length,8);
    await page.clock.runFor(5);await settle(page,()=>calls.length>=12);assert.equal(calls.length,12);
    assert.equal(await page.evaluate(()=>window.done),0);await page.clock.runFor(15001);await settle(page,async()=>(await page.evaluate(()=>window.done))>=4);await page.clock.runFor(2);await flush();assert.equal(await page.evaluate(()=>window.done),4);
    await page.clock.runFor(60000);await flush();assert.equal(calls.length,12);
   }
   if(action==='403'||action==='timeout')for(const offset of [4,8])assert.deepEqual(calls.slice(0,4).map(c=>c.range).sort(),calls.slice(offset,offset+4).map(c=>c.range).sort());
   assert.deepEqual(errors,[]);console.log(`PASS Chromium clock ${transport} ${action}`);count++;await page.close();
  }
  // Player auto pause→play: the in-flight retry survives the pause and play
  // re-sends the last failed Range on the next candidate within 300ms.
  for(const transport of ['fetch','xhr']){
   const page=await browser.newPage(),calls=[],errors=[];page.on('pageerror',e=>errors.push(e.message));
   await page.route('https://www.bilibili.com/**',r=>r.fulfill({body:'<!doctype html><video></video>'}));
   await page.route('https://*.bilivideo.com/**',r=>{calls.push(r.request().url());return r.fulfill({status:calls.length===1?403:206,body:'ok',headers:{'access-control-allow-origin':'*'}});});
   await page.goto('https://www.bilibili.com/video/BVpauseplay');await pauseClock(page);
   for(const file of (process.env.USERSCRIPT_FILE?[path.resolve(process.env.USERSCRIPT_FILE)]:['core.js','page.js'].map(f=>path.join(__dirname,'..',f))))await page.addScriptTag({content:fs.readFileSync(file,'utf8')});
   await page.evaluate(({transport})=>{
    const a='https://a.bilivideo.com/v.m4s',b='https://b.bilivideo.com/v.m4s';
    window.__playinfo__={dash:{video:[{baseUrl:a,backupUrl:[b],mimeType:'video/mp4'}]}};
    window.result=transport==='fetch'?fetch(a).then(r=>r.status,()=>0):new Promise(resolve=>{const x=new XMLHttpRequest();x.open('GET',a);x.onloadend=()=>resolve(x.status);x.send();});
   },{transport});
   await settle(page,()=>calls.length>=1);assert.equal(calls.length,1);
   await page.clock.runFor(1000);await page.evaluate(()=>document.querySelector('video').dispatchEvent(new Event('pause')));await flush();
   await page.clock.runFor(400);await flush();assert.equal(calls.length,1); // pause kept the retry alive, no abort
   await page.evaluate(()=>document.querySelector('video').dispatchEvent(new Event('play')));await flush();
   await page.clock.runFor(300);await settle(page,()=>calls.length>=2);assert.equal(await page.evaluate(()=>window.result),206);
   assert.equal(calls.length,2);assert.ok(calls[1].includes('b.bilivideo.com'));
   assert.deepEqual(errors,[]);console.log(`PASS Chromium pause-play ${transport}`);count++;await page.close();
  }
  console.log(`Chromium transport scenarios passed: ${count}`);
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
