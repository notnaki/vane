const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const source=fs.readFileSync(require('node:path').join(__dirname,'../scroll-stories.js'),'utf8');
const topics=['spaces','split','little','command','library'];
for(const topic of topics)for(const reduced of [false,true]){
  const frames=[],events=[],buttons=topics.map(feature=>({dataset:{feature}}));
  const stage={getBoundingClientRect:()=>({height:500}),querySelectorAll:()=>buttons,querySelector:()=>({hidden:true,textContent:''}),addEventListener(){},dispatchEvent:event=>events.push(event.detail.topic)};
  const root={dataset:{scrollStory:'features'},querySelector:()=>stage,classList:{add(){},toggle(){}},style:{setProperty(){}},getBoundingClientRect:()=>({top:1000-sandbox.scrollY})};
  const sandbox={document:{hidden:false,querySelectorAll:()=>[root],addEventListener(){}},location:{hash:'#'+topic},innerHeight:900,scrollY:0,performance:{now:()=>0},matchMedia:()=>({matches:reduced,addEventListener(){}}),requestAnimationFrame:f=>(frames.push(f),frames.length),addEventListener(){},scrollTo:options=>{sandbox.scrollY=options.top;},CustomEvent:class{constructor(type,options){this.detail=options.detail;}}};
  vm.runInNewContext(source,sandbox);
  if(!reduced&&sandbox.scrollY===0)sandbox.scrollY=800;
  frames.splice(0).forEach(f=>f());
  if(reduced){assert.equal(sandbox.scrollY,0,'Reduced motion keeps ordinary page navigation');assert.equal(events.length,0);}
  else assert.deepEqual(events,[topic],`Initial #${topic} must remain selected when the scroll story starts`);
}
console.log('PASS: all five feature deep links retain their chapter; reduced motion keeps ordinary navigation');
