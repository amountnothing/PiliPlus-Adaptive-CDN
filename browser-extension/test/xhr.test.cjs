const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const {clock}=require('./clock.cjs');
const A = 'https://a.bilivideo.com/v.m4s';
const B = 'https://b.bilivideo.com/v.m4s';
const C = 'https://c.bilivideo.com/v.m4s';
function harness(outcomes) {
  const c=clock();
  class Target {
    constructor(){this.listeners={};}
    addEventListener(type,fn,options){(this.listeners[type] ||= []).push({fn,capture:options===true||options?.capture,once:options?.once});}
    removeEventListener(type,fn){this.listeners[type]=(this.listeners[type]||[]).filter(x=>x.fn!==fn);}
    dispatchEvent(event){this.fire(event.type);}
    fire(type){const event={type,stopImmediatePropagation(){this.stopped=true;}};
      for(const x of [...(this.listeners[type]||[])].sort((a,b)=>Number(!!b.capture)-Number(!!a.capture))){x.fn.call(this,event); if(x.once)this.removeEventListener(type,x.fn); if(event.stopped)return;}
      this['on'+type]?.(event);
    }
  }
  const calls=[];
  class Xhr extends Target {
    open(method,url){this.method=method;this.url=url;this.readyState=1;this.status=0;this.headers={};this.fire('readystatechange');}
    setRequestHeader(k,v){this.headers[k]=v;}
    abort(){if(this.readyState!==4){this.fire('abort');this.fire('loadend');}this.readyState=0;}
    send(){calls.push({at:c.now(),url:this.url,headers:{...this.headers},type:this.responseType,credentials:this.withCredentials});
      const result=typeof outcomes==='function'?outcomes(this.url):outcomes.shift()??206;
      queueMicrotask(()=>{this.status=typeof result==='number'?result:0;this.readyState=4;this.fire('readystatechange');this.fire(typeof result==='string'?result:'load');this.fire('loadend');});
    }
  }
  const document=new Target();Object.assign(document,{scripts:[],documentElement:null,querySelector:()=>null});
  const window=new Target();Object.assign(window,{postMessage(){},fetch:async()=>new Response('')});
  const ctx=vm.createContext({window,document,XMLHttpRequest:Xhr,location:{pathname:'/video/BV1',search:''},URL,URLSearchParams,Request,Response,Headers,AbortController,DOMException,queueMicrotask,Event,Date:c.Date,setTimeout:c.setTimeout,clearTimeout:c.clearTimeout,setInterval(){}});
  vm.runInContext(fs.readFileSync(require.resolve('../core.js'),'utf8'),ctx);window.PiliPlusAdaptiveCdnCore=ctx.PiliPlusAdaptiveCdnCore;
  vm.runInContext(fs.readFileSync(require.resolve('../page.js'),'utf8'),ctx);
  window.__playinfo__={dash:{video:[{baseUrl:A,backupUrl:[B,C],mimeType:'video/mp4'}]}};
  return {Xhr,calls,ctx,window,document,...c};
}
for (const failure of [403,404,500,503,'error','timeout']) {
 test(`XHR ${failure}: retry before player fatal callback, retain headers and response options`,async()=>{
  const {Xhr,calls,settle}=harness([failure,206]); const xhr=new Xhr(); const seen=[];
  xhr.open('GET',A,true);xhr.setRequestHeader('Range','bytes=10-19');xhr.responseType='arraybuffer';xhr.withCredentials=true;
  xhr.addEventListener('readystatechange',()=>{if(xhr.readyState===4)seen.push(xhr.status);});
  await settle(new Promise(resolve=>{xhr.onloadend=resolve;xhr.send();}));
  assert.deepEqual(seen,[206]);assert.deepEqual(calls.map(x=>x.url),[A,B]);
  for(const call of calls){assert.equal(call.headers.Range,'bytes=10-19');assert.equal(call.type,'arraybuffer');assert.equal(call.credentials,true);}
 });
}
for(const failure of [403,'timeout'])test(`XHR concurrent ${failure} emits one final event per Range after bounded candidate windows`,async()=>{
 const long=failure==='timeout';
 const h=harness(()=>failure),xs=[],seen=[];
 for(let i=0;i<4;i++){const x=new h.Xhr();x.open('GET',A);x.setRequestHeader('Range',`bytes=${i*10}-${i*10+9}`);x.onloadend=()=>seen.push(x.status);x.send();xs.push(x);}
 const [w1,w2,w3,w4]=long?[4999,1,4999,1]:[1999,1,1999,1]; // 0.2.20: silent pre-first-byte candidates bound at 5s, not 15s
 await h.tick(w1);assert.equal(h.calls.length,4);await h.tick(w2);assert.equal(h.calls.length,8);
 await h.tick(w3);assert.equal(h.calls.length,8);await h.tick(w4);assert.equal(h.calls.length,12);assert.deepEqual(seen,[]);
 await h.tick(long?5000:2000); // exhaustion settle window
 assert.equal(seen.length,4);await h.tick(60000);assert.equal(h.calls.length,12);
 assert.deepEqual(h.calls.map(c=>c.at),long
  ?[...Array(4).fill(100000),...Array(4).fill(105000),...Array(4).fill(110000)]
  :[...Array(4).fill(100000),...Array(4).fill(102000),...Array(4).fill(104000)]);
 for(let i=0;i<4;i++)assert.equal(h.calls[i].headers.Range,h.calls[i+4].headers.Range);
 assert.equal(xs[0].__piliAdaptiveResource.switchCount,2);
});
for(const action of ['abort','reset'])test(`XHR ${action} cancels hidden DONE wait immediately`,async()=>{
 const h=harness(()=>403),x=new h.Xhr();x.open('GET',A);let done=0,aborted=0;x.onloadend=()=>done++;x.onabort=()=>aborted++;x.send();await h.tick(1000);
 if(action==='abort')x.abort();else{h.ctx.location.pathname='/video/BVnew';h.window.__playinfo__={dash:{video:[{baseUrl:A,backupUrl:[B,C]}]}};}
 assert.equal(done,1);assert.equal(aborted,1);await h.tick(60000);assert.equal(h.calls.length,1);assert.equal(done,1);
});
test('XHR one caller abort cannot cancel other owners of a shared recovery',async()=>{
 const h=harness(url=>url===A?403:206),a=new h.Xhr(),b=new h.Xhr();a.open('GET',A);b.open('GET',A);a.send();b.send();await h.tick(1000);a.abort();await h.tick(14000);
 assert.deepEqual(h.calls.map(c=>c.url),[A,A,B]);assert.equal(b.status,206);assert.equal(b.__piliAdaptiveResource.switchCount,1);
});
test('XHR exhaustion exposes one final failure and has no retry loop',async()=>{
 const {Xhr,calls,settle}=harness([403,404,503]);const xhr=new Xhr();xhr.open('GET',A,true);let done=0;
 await settle(new Promise(resolve=>{xhr.onloadend=()=>{done++;resolve();};xhr.send();}));
 assert.equal(xhr.status,503);assert.equal(done,1);assert.deepEqual(calls.map(x=>x.url),[A,B,C]);
});
