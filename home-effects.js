(() => {
  const home=document.querySelector('.home-layout');
  if(!home)return;
  const reduced=matchMedia('(prefers-reduced-motion: reduce)');
  const header=document.querySelector('.site-header');
  const opening=document.querySelector('.opening');
  const wordmark=opening.querySelector('h1');
  wordmark.dataset.homeDepth='';
  // Measure the wrapped navigation instead of assuming a fixed mobile height.
  function measureHeader(){home.style.setProperty('--home-header-height',header.getBoundingClientRect().height+'px');}
  new ResizeObserver(measureHeader).observe(header);
  measureHeader();
  let frame=0;
  function paint(){
    frame=0;if(document.hidden)return;
    const travel=Math.max(0,Math.min(scrollY,innerHeight));
    wordmark.style.setProperty('--depth-y',reduced.matches?'0px':travel*.18+'px');
    opening.style.setProperty('--backdrop-y',reduced.matches?'0px':Math.min(travel*.05,60)+'px');
  }
  function schedule(){if(!frame&&!document.hidden)frame=requestAnimationFrame(paint);}
  addEventListener('scroll',schedule,{passive:true});addEventListener('resize',schedule,{passive:true});
  document.addEventListener('visibilitychange',schedule);addEventListener('load',schedule,{once:true});reduced.addEventListener('change',schedule);
  schedule();

  const nextSection=document.querySelector('.sidebar-scroll-story');
  if(!nextSection)return;
  const cue=document.createElement('button');
  cue.className='scroll-cue';cue.type='button';cue.hidden=true;
  cue.setAttribute('aria-label','Scroll to explore Vane');
  cue.innerHTML='<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 5v14m-6-6 6 6 6-6"/></svg>';
  opening.append(cue);
  let idleTimer=0,fadeTimer=0,cueFrame=0,used=false;
  function eligible(){
    return !used&&!document.hidden&&document.documentElement.scrollHeight>scrollY+innerHeight+8&&opening.getBoundingClientRect().bottom>innerHeight*.75&&!document.querySelector('dialog[open]')&&!header.querySelector('.is-menu-open');
  }
  function hideCue(){
    clearTimeout(idleTimer);clearTimeout(fadeTimer);cancelAnimationFrame(cueFrame);
    cue.classList.remove('is-visible');
    fadeTimer=setTimeout(()=>{cue.hidden=true;},reduced.matches?0:200);
  }
  function cueActivity(event){
    if(event&&((event.target instanceof Node&&cue.contains(event.target))||event.key==='Tab'))return;
    hideCue();
    if(!used&&!document.hidden)idleTimer=setTimeout(()=>{
      if(!eligible())return;
      clearTimeout(fadeTimer);cue.hidden=false;
      cueFrame=requestAnimationFrame(()=>cue.classList.add('is-visible'));
    },4000);
  }
  cue.addEventListener('click',()=>{
    used=true;hideCue();
    const heading=nextSection.querySelector('h2');
    heading.setAttribute('tabindex','-1');heading.focus({preventScroll:true});
    nextSection.scrollIntoView({behavior:reduced.matches?'instant':'smooth',block:'start'});
  });
  for(const name of ['scroll','pointermove','pointerdown','resize'])addEventListener(name,cueActivity,{passive:true});
  addEventListener('keydown',cueActivity);
  document.addEventListener('visibilitychange',cueActivity);
  cueActivity();
})();
