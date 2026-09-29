// Deterministic deadline clock; drains microtasks between every timer callback.
function clock() {
  let now = 100000, id = 0;
  const timers = new Map();
  class DateClock extends Date { static now() { return now; } }
  const flush = async () => { for (let i=0;i<80;i++) await Promise.resolve(); };
  const setTimeout = (fn, ms=0) => { const key=++id; timers.set(key,{fn,ms,at:now+Math.max(0,ms)}); return key; };
  const clearTimeout = key => timers.delete(key);
  async function tick(ms) {
    await flush(); const end=now+ms;
    for (let n=0;n<1000;n++) {
      const next=[...timers].filter(([,t])=>t.at<=end).sort((a,b)=>a[1].at-b[1].at)[0];
      if (!next) { now=end; await flush(); return; }
      timers.delete(next[0]); now=next[1].at; next[1].fn(); await flush();
    }
    throw Error('timer loop exceeded bound');
  }
  async function settle(promise) {
    let done=false, value, error;
    Promise.resolve(promise).then(v=>{value=v;done=true;},e=>{error=e;done=true;});
    for(let i=0;i<100&&!done;i++) {
      await flush(); if(done)break;
      const next=[...timers.values()].sort((a,b)=>a.at-b.at)[0];
      if(next)await tick(Math.max(0,next.at-now)); else await new Promise(r=>global.setImmediate(r));
    }
    if(!done)throw Error('promise did not settle within finite timer budget');
    if(error)throw error; return value;
  }
  return {Date:DateClock,timers,setTimeout,clearTimeout,flush,tick,settle,now:()=>now};
}
module.exports={clock};
