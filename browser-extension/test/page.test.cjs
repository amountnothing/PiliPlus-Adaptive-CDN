const test=require('node:test');const assert=require('node:assert/strict');
const fs=require('node:fs');const vm=require('node:vm');const {clock}=require('./clock.cjs');
const A='https://a.bilivideo.com/video.m4s?token=a',B='https://b.bilivideo.com/video.m4s?token=b',C='https://c.bilivideo.com/video.m4s?token=c';
function harness(fetchImpl) {
 const c=clock(), intervals=[],messages=[];
 class Xhr extends EventTarget {open(){}send(){}abort(){}setRequestHeader(){}}
 const document=new EventTarget();Object.assign(document,{hidden:false,scripts:[],documentElement:null,querySelector:()=>null});
 const window=new EventTarget();Object.assign(window,{fetch:fetchImpl,postMessage:m=>messages.push(m)});
 const ctx=vm.createContext({window,document,location:{pathname:'/video/BV1',search:''},XMLHttpRequest:Xhr,URL,URLSearchParams,Request,Response,Headers,AbortController,DOMException,Event,console,Date:c.Date,setTimeout:c.setTimeout,clearTimeout:c.clearTimeout,setInterval:fn=>intervals.push(fn)});
 vm.runInContext(fs.readFileSync(require.resolve('../core.js'),'utf8'),ctx);window.PiliPlusAdaptiveCdnCore=ctx.PiliPlusAdaptiveCdnCore;
 vm.runInContext(fs.readFileSync(require.resolve('../page.js'),'utf8'),ctx);
 const register=(urls=[A,B,C],kind='video')=>{window.__playinfo__={dash:{[kind]:[{baseUrl:urls[0],backupUrl:urls.slice(1),mimeType:kind+'/mp4'}]}};};
 const message=(type,payload)=>{const e=new Event('message');Object.assign(e,{source:window,data:{source:'pili-adaptive-cdn-bridge',type,payload}});window.dispatchEvent(e);};
 const event=(type,video)=>{const e=new Event(type);Object.defineProperty(e,'target',{value:video});document.dispatchEvent(e);};
 return {...c,window,document,ctx,register,intervals,messages,event,manual:()=>message('manual-switch'),config:settings=>message('config',{settings})};
}
for(const status of [403,404,500,502,503])test(`fetch HTTP ${status} switches after the 2s definitive-failure cooldown`,async()=>{
 const calls=[];const h=harness(async(u,i)=>{calls.push([String(u),new Headers(i.headers).get('Range'),h.now()]);return new Response(null,{status:calls.length===1?status:206});});h.register();
 const p=h.window.fetch(A,{headers:{Range:'bytes=12-24'}});await h.tick(1999);assert.equal(calls.length,1);await h.tick(1);
 assert.equal((await p).status,206);assert.deepEqual(calls,[[A,'bytes=12-24',100000],[B,'bytes=12-24',102000]]);
});
test('fetch TypeError rejection switches after the short cooldown',async()=>{
 let calls=0;const h=harness(async()=>{if(++calls===1)throw new TypeError('network');return new Response(null,{status:206});});h.register();
 assert.equal((await h.settle(h.window.fetch(A))).status,206);assert.equal(calls,2);assert.equal(h.now(),102000);
});
test('concurrent 403 ranges switch at 0/2/4s and share one generation',async()=>{
 let pending=[];const calls=[];const h=harness((u,i)=>{const range=new Headers(i.headers).get('Range');calls.push({url:String(u),range,at:h.now()});pending=pending.filter(x=>x!==i);return Promise.resolve(new Response(null,{status:403}));});
 h.register();
 const p=Promise.allSettled(Array.from({length:4},(_,i)=>h.window.fetch(A,{headers:{Range:`bytes=${i*10}-${i*10+9}`}})));
 await h.tick(1999);assert.equal(calls.length,4);
 await h.tick(1);assert.equal(calls.length,8);assert.deepEqual(calls.slice(4).map(x=>x.url),[B,B,B,B]);
 await h.tick(1999);assert.equal(calls.length,8);await h.tick(1);assert.equal(calls.length,12);
 await h.tick(3000);
 const results=await p;assert.equal(results.length,4);
 assert.deepEqual(calls.map(x=>x.at),[...Array(4).fill(100000),...Array(4).fill(102000),...Array(4).fill(104000)]);
 for(let i=0;i<4;i++)assert.equal(calls[i].range,calls[i+4].range);
 await h.tick(60000);assert.equal(calls.length,12);
 const status=h.messages.filter(m=>m.type==='status').at(-1).payload;assert.equal(status.switches,2);assert.equal(status.failedHosts.length,3);
});
test('silent pre-first-byte candidates switch on the 5s attempt deadline (0/5/10)',async()=>{
 const calls=[];const h=harness((u,i)=>{calls.push({url:String(u),at:h.now()});return new Promise((r,j)=>i.signal.addEventListener('abort',()=>j(i.signal.reason),{once:true}));});h.register();
 const p=Promise.allSettled(Array.from({length:4},(_,i)=>h.window.fetch(A,{headers:{Range:`bytes=${i*10}-${i*10+9}`}})));
 await h.tick(4999);assert.equal(calls.length,4);await h.tick(1);assert.equal(calls.length,8);
 await h.tick(4999);assert.equal(calls.length,8);await h.tick(1);assert.equal(calls.length,12);
 assert.deepEqual(calls.map(x=>x.at),[...Array(4).fill(100000),...Array(4).fill(105000),...Array(4).fill(110000)]);
 const results=await h.settle(p);assert.equal(results.length,4);
 await h.tick(60000);assert.equal(calls.length,12);
 const status=h.messages.filter(m=>m.type==='status').at(-1).payload;assert.equal(status.switches,2);
});
test('watchdog retires a byte-less candidate whose requests were all page-cancelled',async()=>{
 const h=harness(()=>new Promise(()=>{}));h.register();
 const x1=new h.ctx.XMLHttpRequest(),x2=new h.ctx.XMLHttpRequest();
 x1.open('GET',A);x1.send();x1.abort(); // player cancels before any terminal event can arm recovery
 x2.open('GET',A);x2.send();            // still in flight with zero bytes delivered
 await h.tick(4999);h.intervals[2]();await h.tick(0);
 assert.equal(x2.__piliAdaptiveResource.switchCount,0);
 await h.tick(1);h.intervals[2]();await h.tick(0);
 assert.equal(x2.__piliAdaptiveResource.switchCount,1);
 await h.tick(80); // status emission is debounced by 80ms
 const status=h.messages.filter(m=>m.type==='status').at(-1).payload;
 assert.equal(status.switches,1);assert.equal(status.currentHosts.join(','),'b.bilivideo.com'); // join avoids cross-realm deepEqual
});
test('watchdog stays quiet for idle candidates and after the first byte',async()=>{
 const h=harness(()=>new Promise(()=>{}));h.register();
 const x=new h.ctx.XMLHttpRequest();x.open('GET',A);x.send();x.abort();
 await h.tick(6000);h.intervals[2]();
 assert.equal(x.__piliAdaptiveResource.switchCount,0);
 const y=new h.ctx.XMLHttpRequest();y.open('GET',A);y.send();
 y.readyState=4;y.status=206;y.dispatchEvent(new Event('readystatechange'));
 await h.tick(6000);h.intervals[2]();
 assert.equal(y.__piliAdaptiveResource.switchCount,0);
});
test('late old-generation response cannot trigger extra candidate advances',async()=>{
 let late;const calls=[];const h=harness(u=>{calls.push(String(u));if(calls.length===1)return new Promise(r=>late=r);return Promise.resolve(new Response(null,{status:403}));});h.register();
 const old=h.window.fetch(A),other=h.window.fetch(A);
 await h.tick(2000);assert.deepEqual(calls,[A,A,B]);
 await h.tick(2000);assert.deepEqual(calls,[A,A,B,C]);
 late(new Response(null,{status:403}));await h.flush();assert.deepEqual(calls,[A,A,B,C,C]);
 await h.settle(Promise.allSettled([old,other]));assert.deepEqual(calls,[A,A,B,C,C]);
 const status=h.messages.filter(m=>m.type==='status').at(-1).payload;assert.equal(status.switches,2);
});
test('a late definitive failure switches immediately once its cooldown has passed',async()=>{
 let fail;const calls=[];const h=harness(u=>{calls.push(String(u));return calls.length===1?new Promise(r=>fail=r):Promise.resolve(new Response(null,{status:206}));});h.register();
 const p=h.window.fetch(A);await h.tick(9000);fail(new Response(null,{status:403}));await h.tick(0);assert.equal(calls.length,2);assert.equal((await p).status,206);
});
test('video exhaustion cannot exclude audio hosts or spend its budget',async()=>{
 const calls=[];const h=harness(async u=>{calls.push(String(u));return new Response(null,{status:403});});h.config({traverseAllCdns:false,maxSwitches:2});h.register();
 const audio=[A,B,C].map(u=>u.replace('video.m4s','audio.m4s'));h.register(audio,'audio');
 await h.settle(h.window.fetch(A));assert.deepEqual(calls,[A,B,C]);
 h.register(audio,'audio'); // refreshed playurl must not bypass candidate ownership via global cooldown
 await h.settle(h.window.fetch(audio[0]));assert.deepEqual(calls.slice(0,3),[A,B,C]);assert.equal(calls[3],audio[0]);assert.deepEqual(calls.slice(3).sort(),audio.sort());
});
test('caller abort cancels waiting fetch immediately without a late candidate switch',async()=>{
 let calls=0;const h=harness(async()=>{calls++;return new Response(null,{status:403});});h.register();const controller=new AbortController();
 const p=h.window.fetch(A,{signal:controller.signal});const check=assert.rejects(p,{name:'AbortError'});await h.tick(1000);controller.abort();await check;
 await h.tick(60000);assert.equal(calls,1);const status=h.messages.filter(m=>m.type==='status').at(-1).payload;assert.equal(status.switches,0);
});
test('auto pause does not abort an in-flight retry and play resends within 300ms',async()=>{
 const calls=[];const h=harness(async u=>{calls.push(String(u));return new Response(null,{status:calls.length===1?403:206});});h.register();
 const video={currentTime:73.5,paused:false};h.document.querySelector=()=>video;
 const p=h.window.fetch(A);await h.tick(1000);
 video.paused=true;h.event('pause',video);await h.flush();
 assert.equal(calls.length,1); // pause must not abort the pending recovery
 video.paused=false;h.event('play',video);await h.flush();
 assert.ok(h.now()<=101300,`resend happened ${h.now()-101000}ms after play`);
 assert.deepEqual(calls,[A,B]);assert.equal((await p).status,206);assert.equal(video.currentTime,73.5);
});
test('pause no longer cancels a pending recovery; its wait continues to the deadline',async()=>{
 const calls=[];const h=harness(async u=>{calls.push(String(u));return new Response(null,{status:calls.length===1?403:206});});h.register();
 const video={paused:false};h.document.querySelector=()=>video;
 const p=h.window.fetch(A);await h.tick(1000);video.paused=true;h.event('pause',video);
 await h.tick(1000);assert.deepEqual(calls,[A,B]);assert.equal((await p).status,206);
});
for(const action of ['reset'])test(`${action} cancels candidate wait immediately and leaves position unchanged`,async()=>{
 const calls=[];const h=harness(async u=>{calls.push(String(u));return new Response(null,{status:403});});h.register();
 const video={currentTime:73.5,paused:false};h.document.querySelector=()=>video;
 const p=h.window.fetch(A);const check=assert.rejects(p,{name:'AbortError'});await h.tick(1000);
 h.ctx.location.pathname='/video/BV2';h.register([A,B]);
 await check;await h.tick(60000);assert.deepEqual(calls,[A]);assert.equal(video.currentTime,73.5);
});
test('pause/play around a bounded whole-network guard wait keeps waits alive and finishes finitely',async()=>{
 const h=harness(async()=>{throw new TypeError('offline');});h.register();h.register([A,B,C].map(u=>u.replace('video.m4s','audio.m4s')),'audio');
 const video={paused:false};h.document.querySelector=()=>video;
 const p=Promise.allSettled([h.window.fetch(A),h.window.fetch(A.replace('video.m4s','audio.m4s'))]);await h.tick(1000);
 video.paused=true;h.event('pause',video);await h.tick(999);assert.ok(![...h.timers.values()].some(t=>t.at>130000&&t.at<121000));
 video.paused=false;h.event('play',video);await h.tick(2000);
 assert.ok([...h.timers.values()].some(t=>t.ms===20000));
 const results=await h.settle(p);assert.equal(results.length,2);assert.ok(results.every(r=>r.status==='rejected'));
 assert.ok(h.now()<=200000);
});
test('adaptive manual handoff restarts pending fetch without waiting or exposing AbortError',async()=>{
 const calls=[];const h=harness((u,i)=>{calls.push(String(u));return calls.length===1?new Promise((r,j)=>i.signal.addEventListener('abort',()=>j(i.signal.reason))):Promise.resolve(new Response(null,{status:206}));});h.register();
 const p=h.window.fetch(A);await h.tick(100);h.manual();assert.equal((await h.settle(p)).status,206);assert.deepEqual(calls,[A,B]);assert.ok(h.now()<115000);
});
test('fatal duplicates and HTTP failure share the candidate deadline and preserve position/pause',async()=>{
 const calls=[];const h=harness(async u=>{calls.push(String(u));return new Response(null,{status:calls.length===1?403:206});});h.register();
 const video={error:{code:3},currentTime:73.5,paused:true};h.document.querySelector=()=>video;
 const p=h.window.fetch(A);await h.tick(1000);for(let i=0;i<3;i++)h.event('error',video);
 await h.tick(999);assert.deepEqual(calls,[A]);await h.tick(1);assert.equal((await p).status,206);assert.deepEqual(calls,[A,B]);await h.tick(100);
 assert.match(h.messages.filter(m=>m.type==='status').at(-1).payload.reason,/手动重载/);assert.equal(video.currentTime,73.5);assert.equal(video.paused,true);
});
test('health and transport failures cannot spend two switches on one generation',async()=>{
 const calls=[];const h=harness(async u=>{calls.push(String(u));return new Response(null,{status:403});});h.register();
 const video=new EventTarget();Object.assign(video,{error:null,currentTime:1,paused:false,seeking:false,duration:200,buffered:{length:0}});h.document.querySelector=()=>video;
 const p=h.window.fetch(A);await h.tick(2000);assert.deepEqual(calls,[A,B]);
 h.intervals[1]();await h.tick(1000);h.intervals[1]();await h.tick(500);assert.deepEqual(calls,[A,B]);
 await h.tick(500);assert.deepEqual(calls,[A,B,C]);await h.settle(p.catch(()=>{}));assert.deepEqual(calls,[A,B,C]);
});
test('late playurl on old route and older same-route response cannot replace newer candidates',async()=>{
 const pending=[],calls=[];const h=harness(u=>String(u).includes('playurl')?new Promise(r=>pending.push(r)):(calls.push(String(u)),Promise.resolve(new Response(null,{status:206}))));
 const one=h.window.fetch('https://api.bilibili.com/x/player/playurl?cid=1');h.ctx.location.pathname='/video/BV2';
 const two=h.window.fetch('https://api.bilibili.com/x/player/playurl?cid=2');const info=urls=>new Response(JSON.stringify({dash:{video:[{baseUrl:urls[0],backupUrl:urls.slice(1)}]}}));
 pending[1](info([B,C]));await two;pending[0](info([A,B]));await one;await h.window.fetch(B);assert.deepEqual(calls,[B]);
});
test('retired fetch late response cannot penalize new video',async()=>{
 let finish;let first=true;const calls=[];const h=harness(u=>{if(first){first=false;return new Promise(r=>finish=r);}calls.push(String(u));return Promise.resolve(new Response(null,{status:206}));});h.register();
 const p=h.window.fetch(A);const check=assert.rejects(p);h.ctx.location.pathname='/video/BV2';h.register([A,B]);finish(new Response(null,{status:403}));await check;await h.window.fetch(A);assert.deepEqual(calls,[A]);
});
test('mixed camel/snake fields retain every API candidate',()=>{assert.deepEqual(require('../core.js').streamUrls({baseUrl:A,base_url:B,backupUrl:[],backup_url:[C]}),[A,B,C]);});
test('two-track network guard finishes finitely without repeated observations per Range',async()=>{
 const calls=[];const h=harness(async u=>{calls.push(String(u));throw new TypeError('offline');});h.register();const audio=[A,B,C].map(u=>u.replace('video.m4s','audio.m4s'));h.register(audio,'audio');
 const results=await h.settle(Promise.allSettled([h.window.fetch(A),h.window.fetch(audio[0])]));assert.ok(results.every(r=>r.status==='rejected'));assert.equal(calls.length,6);assert.ok(h.now()<=180000);await h.tick(60000);assert.equal(calls.length,6);
});
test('same-route older playurl cannot overwrite a newer response',async()=>{
 const requests=[],calls=[];const h=harness(u=>String(u).includes('playurl')?new Promise(r=>requests.push(r)):(calls.push(String(u)),Promise.resolve(new Response(null,{status:206}))));
 const one=h.window.fetch('https://api.bilibili.com/x/player/playurl?cid=1'),two=h.window.fetch('https://api.bilibili.com/x/player/playurl?cid=2');
 const info=urls=>new Response(JSON.stringify({dash:{video:[{baseUrl:urls[0],backupUrl:urls.slice(1)}]}}));requests[1](info([B,C]));await two;requests[0](info([A,B]));await one;await h.window.fetch(B);assert.deepEqual(calls,[B]);
});
test('disabling extension cancels an already pending recovery immediately',async()=>{
 const h=harness(async()=>new Response(null,{status:403}));h.register();const p=h.window.fetch(A),check=assert.rejects(p,{name:'AbortError'});await h.tick(1000);h.config({enabled:false});await check;await h.tick(60000);
 assert.equal(h.messages.filter(m=>m.type==='status').at(-1).payload.switches,0);
});
test('request attempt timeout is 5s before first byte',async()=>{
 const abortedAt=[];const calls=[];
 const h=harness((u,i)=>{calls.push(String(u));return new Promise((r,j)=>{const slot=[String(u),null];abortedAt.push(slot);i.signal.addEventListener('abort',()=>{slot[1]=h.now();j(i.signal.reason);},{once:true});});});
 h.register();
 const p=h.window.fetch(A);p.catch(()=>{});
 await h.tick(4999);assert.equal(abortedAt[0][1],null);assert.equal(calls.length,1);await h.tick(1);assert.equal(abortedAt[0][1],105000);
 await h.tick(1);assert.equal(calls[1],B); // 0.2.20: a silent pre-first-byte candidate switches at the 5s attempt deadline, not t0+15s
 assert.ok(h.now()<=105100);
});
test('request attempt timeout extends to 15s after first byte',async()=>{
 const abortedAt=[];const calls=[];
 const h=harness((u,i)=>{calls.push(String(u));if(calls.length===1)return Promise.resolve(new Response(null,{status:206}));return new Promise((r,j)=>{const slot=[String(u),null];abortedAt.push(slot);i.signal.addEventListener('abort',()=>{slot[1]=h.now();j(i.signal.reason);},{once:true});});});
 h.register();
 await h.settle(h.window.fetch(A)); // first byte delivered at t=0
 await h.tick(10000);
 const p=h.window.fetch(A);p.catch(()=>{});
 await h.tick(14999);assert.equal(abortedAt[0][1],null);await h.tick(1);assert.equal(abortedAt[0][1],125000);
 await h.tick(0);
 assert.equal(calls[calls.length-1],B); // switch fired once the post-first-byte attempt timed out
 assert.equal(h.now(),125000);
});
module.exports={harness,A,B,C};
