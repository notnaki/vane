(() => {
  const home=document.querySelector('.home-layout');
  if(!home)return;
  const reduced=matchMedia('(prefers-reduced-motion: reduce)');
  const opening=document.querySelector('.opening');
  const wordmark=opening.querySelector('h1');
  wordmark.dataset.homeDepth='';
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
})();
