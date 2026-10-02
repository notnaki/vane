const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const source=fs.readFileSync(require('node:path').join(__dirname,'../space.js'),'utf8');
for(const gpu of [false,true]) for(const testShape of ["spiral","fine","soft"]) {
 const frames=new Map();let nextFrame=0,draws=0,intersect;
 const ctx={setTransform(){},beginPath(){},arc(){},moveTo(){},lineTo(){},stroke(){},fill(){},fillRect(){},clearRect(){},drawImage(){},createRadialGradient(){return {addColorStop(){}}}};
 const gl=new Proxy({getShaderParameter(){return true;},getProgramParameter(){return true;},getAttribLocation(){return 0;},createShader(){return {};},createProgram(){return {};},createBuffer(){return {};},getUniformLocation(){return {};},drawArrays(){draws++;}},{get(target,key){return key in target?target[key]:key===key.toUpperCase()?1:()=>{};}});
 const element=()=>({width:0,height:0,dataset:{},style:{},classList:{add(){},toggle(){}},handlers:{},attrs:{},parentElement:{prepend(){}},firstElementChild:{textContent:''},setAttribute(k,v){this.attrs[k]=v;},removeAttribute(k){delete this.attrs[k];},getContext(type){return type==='webgl'?(gpu?gl:null):ctx;},getBoundingClientRect(){return {width:1280,height:this.journey?6400:(sceneReady?800:2400),top:this.journey?-scroll:0};},addEventListener(k,f){this.handlers[k]=f;},setPointerCapture(){}});
 const hero=element(),toggle=element(),reset=element(),journey=element(),logo=element(),panels=Array.from({length:4},element),links=Array.from({length:4},element); journey.journey=true; const shapeButtons=['spiral','fine','soft'].map(shape=>{const e=element();e.dataset.shape=shape;return e;}); const productStage=element(),productShell=element(),productAddress=element(),heroMessage=element(),introSupport=element(),productPages=[1,2,3].map(n=>{const e=element();e.dataset.product=String(n);return e;}); let scroll=0; let sceneReady=false; journey.classList.add=()=>{sceneReady=true;}; const windowHandlers={};
 const motion={matches:true,addEventListener(k,f){this.change=f;}};
 const document={hidden:false,handlers:{},body:{prepend(){}},createElement:element,querySelectorAll(s){return s==='[data-chapter]'?panels:s==='.journey-nav a'?links:s==='[data-shape]'?shapeButtons:s==='[data-product]'?productPages:[];},querySelector(s){return {'[data-galaxy="hero"]':hero,'.galaxy-toggle':toggle,'.galaxy-reset':reset,'.galaxy-journey':journey,'.galaxy-v':logo,'.product-stage':productStage,'.product-shell':productShell,'.product-address':productAddress,'.hero-message':heroMessage,'.intro-support':introSupport}[s];},addEventListener(k,f){this.handlers[k]=f;}};
 const sandbox={document,URL,URLSearchParams,window:{location:{search:'?shape='+testShape,href:'http://localhost/?shape='+testShape},history:{replaceState(){}},innerWidth:1280,devicePixelRatio:2,addEventListener(k,f){windowHandlers[k]=f;},IntersectionObserver:true},matchMedia(){return motion;},requestAnimationFrame(f){const id=++nextFrame;frames.set(id,f);return id;},cancelAnimationFrame(id){frames.delete(id);},IntersectionObserver:class{constructor(f){intersect=f;}observe(){}}};
 vm.runInNewContext(source,sandbox);
 assert.equal(logo.style.top,'320px','Opening V must be centered using the final viewport height'); assert.equal(hero.dataset.renderer,gpu?'webgl':'canvas');
 assert.equal(frames.size,0,'Reduced motion must start paused');
 assert.equal(toggle.attrs['aria-pressed'],'true');
 toggle.handlers.click();assert.equal(frames.size,1);
 document.hidden=true;document.handlers.visibilitychange();assert.equal(frames.size,0);
 document.hidden=false;document.handlers.visibilitychange();assert.equal(frames.size,1);
 intersect([{isIntersecting:false}]);assert.equal(frames.size,0);
 intersect([{isIntersecting:true}]);assert.equal(frames.size,1);
 toggle.handlers.click();assert.equal(frames.size,0);
 let prevented=false;hero.handlers.keydown({key:'ArrowRight',preventDefault(){prevented=true;}});assert.ok(prevented);assert.equal(frames.size,0);
 reset.handlers.click();assert.equal(frames.size,0);
 if(gpu){assert.ok(draws>0);toggle.handlers.click();hero.handlers.webglcontextlost({preventDefault(){}});assert.equal(frames.size,0);hero.handlers.webglcontextrestored();assert.equal(frames.size,1);}
 motion.matches=false; motion.change();
 scroll=400; windowHandlers.scroll();
 for(const [id,f] of [...frames]){frames.delete(id);f(70);}
 assert.equal(productStage.style.opacity,'0','Initial card must be completely invisible');
 assert.equal(productStage.style.visibility,'hidden');
 assert.ok(productStage.style.transform.includes('scale(0.0005)'));
 scroll=1600; windowHandlers.scroll();
 for(const [id,f] of [...frames]){frames.delete(id);f(100);}
 assert.equal(hero.dataset.chapter,'1'); assert.equal(hero.dataset.zoom,'2.60'); assert.equal(panels[0].inert,false); assert.equal(panels[1].inert,false);
 scroll=1680; windowHandlers.scroll();
 for(const [id,f] of [...frames]){frames.delete(id);f(125);}
 assert.equal(hero.dataset.zoom,'2.60','A small scroll must hold the current card');
 assert.equal(productPages[0].style.transform,'translateX(0%)');
 assert.equal(panels[0].attrs['aria-hidden'],'false','Main headline stays accessible');
 scroll=3200; windowHandlers.scroll();
 for(const [id,f] of [...frames]){frames.delete(id);f(140);}
 assert.equal(hero.dataset.chapter,'2'); assert.equal(hero.dataset.zoom,'1.80');
 scroll=4800; windowHandlers.scroll();
 for(const [id,f] of [...frames]){frames.delete(id);f(180);}
 assert.equal(hero.dataset.chapter,'3'); assert.equal(hero.dataset.zoom,'3.10');
 scroll=2880; windowHandlers.scroll();
 for(const [id,f] of [...frames]){frames.delete(id);f(220);}
 assert.equal(productStage.style.opacity,'1','Browser must never fade');
 assert.equal(productPages[0].style.transform,'translateX(-50%)');
 assert.equal(productPages[1].style.transform,'translateX(50%)');
 assert.equal(panels[1].style.opacity,'1');
 assert.equal(hero.dataset.shape,testShape);
 motion.matches=true; motion.change(); assert.equal(hero.dataset.zoom,'0.92'); assert.equal(frames.size,0);
 console.log('PASS: spiral variants, chapter hold zones, persistent headline, microscopic invisible opening, held previews, '+(gpu?'WebGL orchestration':'Canvas fallback')+' — motion preference, pause/resume, keyboard, reset, tab visibility, offscreen lifecycle'+(gpu?', context restoration':''));
}
