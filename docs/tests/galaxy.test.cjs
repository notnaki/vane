const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const source=fs.readFileSync(require('node:path').join(__dirname,'../space.js'),'utf8');
for(const viewport of [{width:1280,height:800},{width:240,height:718},{width:480,height:600},{width:480,height:390},{width:844,height:390}]) for(const gpu of [false,true]) for(const testShape of ["spiral","fine","soft"]) {
 const {width,height}=viewport; const compact=width<=600; const shortWide=!compact && height<=520; const openingZoom=compact && height<=520 ? 55/Math.min(width*.44,height*.42) : shortWide ? .65 : .92;
 const frames=new Map();let nextFrame=0,draws=0,intersect;
 const ctx={setTransform(){},beginPath(){},arc(){},moveTo(){},lineTo(){},stroke(){},fill(){},fillRect(){},clearRect(){},drawImage(){},createRadialGradient(){return {addColorStop(){}}}};
 const gl=new Proxy({getShaderParameter(){return true;},getProgramParameter(){return true;},getAttribLocation(){return 0;},createShader(){return {};},createProgram(){return {};},createBuffer(){return {};},getUniformLocation(){return {};},drawArrays(){draws++;}},{get(target,key){return key in target?target[key]:key===key.toUpperCase()?1:()=>{};}});
 const element=()=>({width:0,height:0,dataset:{},style:{},classList:{add(){},toggle(){}},handlers:{},attrs:{},parentElement:{prepend(){}},firstElementChild:{textContent:''},setAttribute(k,v){this.attrs[k]=v;},removeAttribute(k){delete this.attrs[k];},getContext(type){return type==='webgl'?(gpu?gl:null):ctx;},getBoundingClientRect(){return {width,height:this.journey?height*8:(sceneReady?height:height*3),top:this.journey?-scroll:0};},addEventListener(k,f){this.handlers[k]=f;},setPointerCapture(){}});
 const hero=element(),toggle=element(),reset=element(),journey=element(),logo=element(),panels=Array.from({length:4},element),links=Array.from({length:4},element); journey.journey=true; const shapeButtons=['spiral','fine','soft'].map(shape=>{const e=element();e.dataset.shape=shape;return e;}); const productStage=element(),productShell=element(),productAddress=element(),heroMessage=element(),introSupport=element(),productPages=[1,2,3].map(n=>{const e=element();e.dataset.product=String(n);return e;}); let scroll=0; let sceneReady=false; journey.classList.add=()=>{sceneReady=true;}; const windowHandlers={};
 heroMessage.offsetWidth=compact?width-40:480; heroMessage.offsetHeight=50; productStage.offsetWidth=compact?width-40:552; productShell.offsetHeight=369; const navigation=element(); navigation.getBoundingClientRect=()=>({bottom:70}); panels.slice(1).forEach(panel=>{panel.querySelector=()=>({offsetHeight:120});});
 const motion={matches:true,addEventListener(k,f){this.change=f;}};
 const document={hidden:false,handlers:{},body:{prepend(){}},createElement:element,querySelectorAll(s){return s==='[data-chapter]'?panels:s==='.journey-nav a'?links:s==='[data-shape]'?shapeButtons:s==='[data-product]'?productPages:[];},querySelector(s){return {'[data-galaxy="hero"]':hero,'.galaxy-toggle':toggle,'.galaxy-reset':reset,'.galaxy-journey':journey,'.galaxy-v':logo,'.product-stage':productStage,'.product-shell':productShell,'.product-address':productAddress,'.hero-message':heroMessage,'.intro-support':introSupport,'.site-nav':navigation}[s];},addEventListener(k,f){this.handlers[k]=f;}};
 const sandbox={document,URL,URLSearchParams,window:{location:{search:'?shape='+testShape,href:'http://localhost/?shape='+testShape},history:{replaceState(){}},innerWidth:width,devicePixelRatio:2,addEventListener(k,f){windowHandlers[k]=f;},IntersectionObserver:true},matchMedia(){return motion;},requestAnimationFrame(f){const id=++nextFrame;frames.set(id,f);return id;},cancelAnimationFrame(id){frames.delete(id);},IntersectionObserver:class{constructor(f){intersect=f;}observe(){}}};
 vm.runInNewContext(source,sandbox);
 assert.equal(logo.style.top,height*(shortWide?.48:compact?(height<=520?.33:.36):.40)+'px','Opening V must be centered using the final viewport height'); assert.equal(hero.dataset.renderer,gpu?'webgl':'canvas');
 assert.equal(frames.size,0,'Reduced motion must start paused');
 assert.equal(toggle.attrs['aria-pressed'],'true');
 toggle.handlers.click();assert.equal(frames.size,1);
 // A fast display must produce a galaxy frame on every animation callback.
 // Counting draw passes catches a site-side cap even when rAF itself runs at 120 Hz.
 if(gpu) for(const hz of [60,90,120,144]) {
   const before=draws;
   for(let i=0;i<24;i++) {
     for(const [id,f] of [...frames]){frames.delete(id);f(1000+i*1000/hz);}
   }
   assert.equal(draws-before,48,`WebGL must draw all 24 display frames at ${hz} Hz`);
   toggle.handlers.click(); toggle.handlers.click(); // Reset the animation clock.
 }
 document.hidden=true;document.handlers.visibilitychange();assert.equal(frames.size,0);
 document.hidden=false;document.handlers.visibilitychange();assert.equal(frames.size,1);
 intersect([{isIntersecting:false}]);assert.equal(frames.size,0);
 intersect([{isIntersecting:true}]);assert.equal(frames.size,1);
 toggle.handlers.click();assert.equal(frames.size,0);
 let prevented=false;hero.handlers.keydown({key:'ArrowRight',preventDefault(){prevented=true;}});assert.ok(prevented);assert.equal(frames.size,0);
 reset.handlers.click();assert.equal(frames.size,0);
 if(gpu){assert.ok(draws>0);toggle.handlers.click();hero.handlers.webglcontextlost({preventDefault(){}});assert.equal(frames.size,0);hero.handlers.webglcontextrestored();assert.equal(frames.size,1);}
 motion.matches=false; motion.change();
 scroll=height*.5; windowHandlers.scroll();
 for(const [id,f] of [...frames]){frames.delete(id);f(70);}
 assert.equal(productStage.style.opacity,'0','Initial card must be completely invisible');
 assert.equal(productStage.style.visibility,'hidden');
 assert.ok(productStage.style.transform.includes('scale(0.0005)'));
 scroll=height*2; windowHandlers.scroll();
 for(const [id,f] of [...frames]){frames.delete(id);f(100);}
 assert.equal(hero.dataset.chapter,'1'); assert.equal(hero.dataset.zoom,'2.60');
 const scale=Number(productShell.style.transform.match(/scale\(([^)]+)\)/)[1]);
 assert.ok(552*scale<=productStage.offsetWidth+.01,'The complete browser must fit its available width');
 assert.equal(Number.parseFloat(productStage.style.height),369*scale,'The preview frame must preserve its aspect ratio');
 if(compact){
   assert.ok(Number.parseFloat(productStage.style.height)<=height-110-Number.parseFloat(panels[1].style.paddingTop)-120-20+.01,'Preview must clear the feature copy and footer');
   assert.equal(introSupport.style.top,Math.min(height*.48,height-50-110-86)+50+16+'px','Description follows measured headline height');
 }
 assert.equal(panels[0].inert,false); assert.equal(panels[1].inert,false);
 scroll=height*2.1; windowHandlers.scroll();
 for(const [id,f] of [...frames]){frames.delete(id);f(125);}
 assert.equal(hero.dataset.zoom,'2.60','A small scroll must hold the current card');
 assert.equal(productPages[0].style.transform,'translateX(0%)');
 assert.equal(panels[0].attrs['aria-hidden'],'false','Main headline stays accessible');
 scroll=height*4; windowHandlers.scroll();
 for(const [id,f] of [...frames]){frames.delete(id);f(140);}
 assert.equal(hero.dataset.chapter,'2'); assert.equal(hero.dataset.zoom,'1.80');
 scroll=height*6; windowHandlers.scroll();
 for(const [id,f] of [...frames]){frames.delete(id);f(180);}
 assert.equal(hero.dataset.chapter,'3'); assert.equal(hero.dataset.zoom,'3.10');
 scroll=height*3.6; windowHandlers.scroll();
 for(const [id,f] of [...frames]){frames.delete(id);f(220);}
 assert.equal(productStage.style.opacity,'1','Browser must never fade');
 assert.equal(productPages[0].style.transform,'translateX(-50%)');
 assert.equal(productPages[1].style.transform,'translateX(50%)');
 assert.equal(panels[1].style.opacity,'1');
 assert.equal(hero.dataset.shape,testShape);
 motion.matches=true; motion.change(); assert.equal(hero.dataset.zoom,openingZoom.toFixed(2)); assert.equal(frames.size,0);
 console.log('PASS '+width+'×'+height+': spiral variants, chapter hold zones, persistent headline, microscopic invisible opening, held previews, '+(gpu?'WebGL orchestration':'Canvas fallback')+' — motion preference, pause/resume, keyboard, reset, tab visibility, offscreen lifecycle'+(gpu?', context restoration':''));
}
