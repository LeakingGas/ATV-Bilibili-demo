// Generate expectations by executing the pinned ORIGINAL BTR functions, not a JS rewrite.
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const root = path.resolve(__dirname, '../..');
const core = fs.readFileSync(path.join(root, 'ThirdParty/BTR/src/range-core.js'), 'utf8');
const source = fs.readFileSync(path.join(root, 'ThirdParty/BTR/src/idm-downloader.js'), 'utf8');
vm.runInThisContext(core);
const marker = 'return Object.freeze({ downloadRange, applySettings, getConcurrency: () => semaphore.limit });';
if (!source.includes(marker)) throw Error('Pinned BTR export changed');
vm.runInThisContext(source.replace(marker, 'return { assignPrimaries, recordMeter, adaptiveMinChunk, hedgeDelayMs, hedgeDue };'));
const factory = globalThis.__BILI_IDM_DOWNLOADER_FACTORY__;
const tests = [];
for (const input of [
  { urls: ['a','b'], speeds: [0,0], count: 7 },
  { urls: ['a','b','c'], speeds: [1200,300,1], count: 7 },
  { urls: ['a','b','c'], speeds: [1200,0,0], count: 7 },
  { urls: ['a','b'], speeds: [1200,0], count: 2 },
  { urls: ['a','b','c'], speeds: [100,100,100], count: 13 }
]) {
  const engine = factory.createDownloader({ getSettings: () => ({}) });
  const resolver = { speed: url => input.speeds[input.urls.indexOf(url)] };
  const rounds = Array.from({length: 8}, () => engine.assignPrimaries(input.urls, resolver, input.count));
  tests.push({...input, rounds});
}
const splits = [];
for (const length of [1,32769,65536,131073,2097152]) for (const limit of [1,4,7]) {
  splits.push({length,limit,pieces:globalThis.__BILI_RANGE_CORE__.splitRange(17,16+length,limit,65536)});
}
const engine = factory.createDownloader({getSettings: () => ({})});
const meters=[];
for (const [bytes,seconds] of [[1000,1],[65536,0.4],[524288,0.8],[131072,2]]) {
  engine.recordMeter(bytes,seconds*1000);
  meters.push({bytes,seconds,delay:engine.hedgeDelayMs({hedgeDelayMs:900})/1000,
    minimum:engine.adaptiveMinChunk({minChunkBytes:65536},2097152,7,2)});
}
const autoScenarios = [
  [{at:0,op:'newSession'},{at:3000,op:'buffer',ahead:16,playing:true},{at:6000,op:'buffer',ahead:16,playing:true}],
  [{at:1000,op:'delivered',bytes:1000000},{at:2000,op:'delivered',bytes:1000000},
   {at:3000,op:'slow'},{at:3000,op:'stall'},{at:3000,op:'demand',active:12,limit:12,queued:1},
   {at:14000,op:'delivered',bytes:1000},{at:17000,op:'slow'},{at:20000,op:'stall'}],
  [{at:0,op:'newSession'},{at:3000,op:'pushback',status:429},{at:6000,op:'stall'},
   {at:10000,op:'newSession'},{at:200000,op:'stall'}],
  Array.from({length:20},(_,i)=>[{at:i*250+1000,op:'activity'},
    {at:i*250+1000,op:'buffer',ahead:2,playing:true}]).flat(),
  [{at:0,op:'newSession'},{at:3000,op:'buffer',ahead:2,playing:false},
   {at:31000,op:'buffer',ahead:2,playing:true},{at:32000,op:'pushback',status:412}],
  [{at:3000,op:'demand',active:8,limit:8,queued:1},{at:7000,op:'slow'},
   {at:8000,op:'demand',active:0,limit:12,queued:0},{at:20000,op:'delivered',bytes:65536}],
];
const autos = autoScenarios.map(events => {
  let clock=0; const controller=factory.createAutoConcurrency({now:()=>clock});
  return events.map(e=>{
    clock=e.at;
    if(e.op==='buffer') controller.buffer(e.ahead,e.playing);
    else if(e.op==='delivered') controller.delivered(e.bytes);
    else if(e.op==='demand') controller.demand(e.active,e.limit,e.queued);
    else if(e.op==='pushback') controller.pushback(e.status);
    else controller[e.op]();
    const state=controller.status();
    return {...e,threads:state.threads,steps:state.steps,trialFrom:state.trial?.from ?? -1,
      throughput:state.throughputBps,saturation:state.saturation};
  });
});
const savedPerformance = Object.getOwnPropertyDescriptor(globalThis,'performance');
let hedgeClock=0;
Object.defineProperty(globalThis,'performance',{value:{now:()=>hedgeClock},configurable:true});
const hedgeInputs = [
  {now:100,bytes:0,length:200000,deadline:2000,copy:200000,seenAt:0},
  {now:1000,bytes:0,length:200000,deadline:2000,copy:200000,seenAt:0},
  {now:1000,bytes:100000,length:150000,deadline:10000,copy:100000,seenAt:1000},
  {now:1000,bytes:100000,length:300000,deadline:2000,copy:200000,seenAt:1000},
  {now:1000,bytes:30000,length:300000,deadline:2000,copy:100000,seenAt:1000},
  {now:1000,bytes:100000,length:300000,deadline:2000,copy:0,seenAt:1000},
  {now:1000,bytes:100000,length:300000,deadline:2000,copy:100000,seenAt:1000},
  {now:2000,bytes:100000,length:300000,deadline:2500,copy:100000,seenAt:500},
];
const hedges=hedgeInputs.map(input=>{
  const engine=factory.createDownloader({getSettings:()=>({})});engine.recordMeter(100000,1000);
  hedgeClock=input.now; let budget=1;
  const first={startedAt:0,recorder:{bytes:input.bytes},length:input.length,seenBytes:input.bytes,seenAt:input.seenAt};
  const due=engine.hedgeDue(first,900,input.deadline,input.copy,{claimStale:()=>budget>0 ? (budget--,true):false});
  return {...input,due,remaining:budget};
});
Object.defineProperty(globalThis,'performance',savedPerformance);
const output=path.join(__dirname,'oracle.json');
fs.writeFileSync(output, JSON.stringify({tests,splits,meters,autos,hedges},null,2)+'\n');
console.log(`BTR original-source oracle: ${tests.length*8} assignments, ${splits.length} splits, ${meters.length} measurements`);

console.log(`BTR original auto-concurrency oracle: ${autos.reduce((n,s)=>n+s.length,0)} transitions`);

console.log(`BTR original deadline hedge oracle: ${hedges.length} cases`);
