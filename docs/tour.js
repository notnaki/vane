(() => {
  const tabs=[...document.querySelectorAll('[data-feature]')];
  const captures=[...document.querySelectorAll('[data-capture]')];
  const descriptions=[...document.querySelectorAll('[data-description]')];
  const panel=document.querySelector('#tour-panel');
  const list=document.querySelector('.feature-selector');
  const reduced=matchMedia('(prefers-reduced-motion: reduce)');
  const narrow=matchMedia('(max-width:760px)');
  const stage=document.querySelector('.feature-playground');
  const hint=document.querySelector('.feature-hint');
  let motion,request=0;
  function orientation(){list.setAttribute('aria-orientation',narrow.matches?'horizontal':'vertical');}
  orientation();narrow.addEventListener('change',orientation);
  reduced.addEventListener('change',()=>{if(reduced.matches)motion?.finish();});
  async function select(name,updateHash=true,animate=true,fromScroll=false){
    const token=++request;
    const feature=tabs.some(tab=>tab.dataset.feature===name)?name:'spaces';
    const capture=captures.find(item=>item.dataset.capture===feature);
    panel.setAttribute('aria-busy','true');
    try{
      const images=[...capture.querySelectorAll('img')];
      images.forEach(image=>{image.loading='eager';if(image.complete&&!image.naturalWidth)image.src=image.getAttribute('src');});
      await Promise.all(images.map(image=>image.decode()));
    }catch{if(token===request){panel.removeAttribute('aria-busy');hint.textContent='This view couldn’t load. Choose it again to retry.';stage.dispatchEvent(new CustomEvent('feature-selection-error',{detail:{topic:feature}}));}return;}
    if(token!==request)return;
    panel.removeAttribute('aria-busy');hint.textContent='';
    motion?.cancel();
    tabs.forEach(tab=>{const active=tab.dataset.feature===feature;tab.setAttribute('aria-selected',String(active));tab.tabIndex=active?0:-1;});
    captures.forEach(capture=>{const active=capture.dataset.capture===feature;capture.classList.toggle('is-active',active);capture.setAttribute('aria-hidden',String(!active));capture.inert=!active;});
    descriptions.forEach(description=>{const active=description.dataset.description===feature;description.classList.toggle('is-active',active);description.setAttribute('aria-hidden',String(!active));description.inert=!active;});
    panel.setAttribute('aria-labelledby','tab-'+feature);
    if(animate&&!reduced.matches)motion=captures.find(capture=>capture.dataset.capture===feature).animate([{opacity:.5,filter:'blur(2px)'},{opacity:1,filter:'blur(0)'}],{duration:240,easing:'cubic-bezier(.16,1,.3,1)'});
    if(updateHash)history.replaceState(null,'','#'+feature);
    stage.dispatchEvent(new CustomEvent('feature-selection',{detail:{topic:feature,fromScroll}}));
  }
  tabs.forEach((tab,i)=>{
    tab.addEventListener('click',()=>select(tab.dataset.feature));
    tab.addEventListener('keydown',event=>{
      let next;
      if(event.key==='ArrowRight'||event.key==='ArrowDown')next=(i+1)%tabs.length;
      if(event.key==='ArrowLeft'||event.key==='ArrowUp')next=(i-1+tabs.length)%tabs.length;
      if(event.key==='Home')next=0;if(event.key==='End')next=tabs.length-1;
      if(next!==undefined){event.preventDefault();tabs[next].focus();select(tabs[next].dataset.feature);}
    });
  });
  stage.addEventListener('feature-scroll-step',event=>select(event.detail.topic,false,true,true));
  window.addEventListener('hashchange',()=>{if(tabs.some(tab=>tab.dataset.feature===location.hash.slice(1)))select(location.hash.slice(1),false);});
  select(location.hash.slice(1)==='sidebar'?'spaces':location.hash.slice(1),false,false,true);
})();
