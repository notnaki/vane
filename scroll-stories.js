(() => {
  const reduced=matchMedia('(prefers-reduced-motion: reduce)');
  const stories=[...document.querySelectorAll('[data-scroll-story]')].map(root=>{
    const feature=root.dataset.scrollStory==='features';
    const stage=root.querySelector(feature?'.feature-playground':'.sidebar-explorer-section');
    return {root,stage,feature,buttons:[...stage.querySelectorAll(feature?'[data-feature]':'[data-sidebar-topic]')],hint:stage.querySelector(feature?'.feature-scroll-hint':'.sidebar-scroll-hint'),counter:stage.querySelector(feature?'[data-story-step]':'[data-sidebar-step]'),enabled:false,top:32,distance:0,last:-1,manual:null,retryAt:0,initialTopic:feature?location.hash.slice(1):null};
  });
  if(!stories.length)return;
  let frame=0;
  const key=(story,button)=>story.feature?button.dataset.feature:button.dataset.sidebarTopic;
  function configure(){
    stories.forEach(story=>{
      story.root.classList.add('is-scroll-enabled');story.hint.hidden=false;
      const height=story.stage.getBoundingClientRect().height;
      story.enabled=!reduced.matches&&height<=innerHeight-64;
      story.root.classList.toggle('is-scroll-enabled',story.enabled);story.hint.hidden=!story.feature&&!story.enabled;
      if(story.enabled){
        story.top=Math.max(32,(innerHeight-height)/2);
        story.distance=innerHeight*(story.buttons.length*.5);
        story.root.style.setProperty('--story-frame',height+'px');
        story.root.style.setProperty('--story-distance',story.distance+'px');
        story.root.style.setProperty('--story-top',story.top+'px');
        const initialIndex=story.buttons.findIndex(button=>key(story,button)===story.initialTopic);
        if(initialIndex>=0){
          const start=story.root.getBoundingClientRect().top+scrollY-story.top;
          scrollTo({top:start+story.distance*(initialIndex+.5)/story.buttons.length,behavior:'instant'});
        }
      }
      story.initialTopic=null;
      story.manual=null;story.last=-1;story.retryAt=0;
    });
    schedule();
  }
  function paint(){
    frame=0;if(document.hidden)return;
    stories.forEach(story=>{
      if(!story.enabled)return;
      const start=story.root.getBoundingClientRect().top+scrollY-story.top;
      if(story.manual&&Math.abs(scrollY-story.manual.y)<3)story.manual=null;
      const progress=Math.max(0,Math.min(1,(scrollY-start)/story.distance));
      const index=story.manual?story.manual.index:Math.min(story.buttons.length-1,Math.floor(progress*story.buttons.length));
      if(scrollY>=start-innerHeight*.15&&index!==story.last&&performance.now()>=story.retryAt){
        story.last=index;
        story.stage.dispatchEvent(new CustomEvent(story.feature?'feature-scroll-step':'sidebar-scroll-step',{detail:{topic:key(story,story.buttons[index])}}));
      }
    });
  }
  function schedule(){if(!frame&&!document.hidden)frame=requestAnimationFrame(paint);}
  stories.forEach(story=>{
    story.stage.addEventListener(story.feature?'feature-selection':'sidebar-selection',event=>{
      const index=story.buttons.findIndex(button=>key(story,button)===event.detail.topic);
      if(index<0)return;
      story.counter.textContent=(index+1)+' / '+story.buttons.length;
      if(event.detail.fromScroll||!story.enabled)return;
      story.retryAt=0;
      const start=story.root.getBoundingClientRect().top+scrollY-story.top;
      const target=start+story.distance*(index+.1)/story.buttons.length;
      story.manual={index,y:target};story.last=index;story.counter.textContent=(index+1)+' / '+story.buttons.length;
      scrollTo({top:target,behavior:'smooth'});
    });
    story.stage.addEventListener(story.feature?'feature-selection-error':'sidebar-selection-error',()=>{story.last=-1;story.manual=null;story.retryAt=performance.now()+1000;});
  });
  function cancelManual(){stories.forEach(story=>story.manual=null);}
  addEventListener('wheel',cancelManual,{passive:true});addEventListener('touchstart',cancelManual,{passive:true});
  addEventListener('keydown',event=>{if(['PageDown','PageUp',' ','Escape'].includes(event.key))cancelManual();});
  addEventListener('scroll',schedule,{passive:true});addEventListener('resize',configure,{passive:true});
  document.addEventListener('visibilitychange',schedule);addEventListener('load',configure,{once:true});reduced.addEventListener('change',configure);
  document.fonts?.ready.then(configure);
  configure();
})();
