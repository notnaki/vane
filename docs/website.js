(() => {
  'use strict';
  const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)');
  const arrow = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="m6 6 12 12M18 6 6 18"/></svg>';
  const pages = [
    { url:'index.html', title:'Vane', description:'A native Mac browser. Spaces, Split View, and Little Vane.' },
    { url:'features.html', title:'Features', description:'Explore Spaces, splits, the command bar, and more.' },
    { url:'docs.html', title:'The Vane guide', description:'Getting started, imports, shortcuts, and everyday browsing.' },
    { url:'download.html', title:'Download Vane', description:'Get Vane for macOS and learn how to install it.' },
    { url:'privacy.html', title:'Privacy policy', description:'Local data, network requests, and your controls.' }
  ];
  function backdropClose(dialog) {
    dialog.addEventListener('click', event => {
      if (event.target !== dialog) return;
      const r = dialog.getBoundingClientRect();
      if (event.clientX < r.left || event.clientX > r.right || event.clientY < r.top || event.clientY > r.bottom) dialog.close();
    });
  }
  const finder = document.createElement('dialog');
  finder.className = 'finder';
  finder.setAttribute('aria-label','Search the Vane website');
  finder.innerHTML = '<div class="finder-header"><label class="sr-only" for="site-query">Search pages and guides</label><input id="site-query" type="search" placeholder="Find a page, feature, or shortcut…" autocomplete="off" spellcheck="false"><button type="button" class="dialog-close" aria-label="Close search">'+arrow+'</button></div><ul class="finder-results" aria-label="Search results"></ul><p class="finder-status" role="status" aria-live="polite"></p>';
  document.body.append(finder);
  const query = finder.querySelector('input');
  const results = finder.querySelector('ul');
  const searchStatus = finder.querySelector('.finder-status');
  let index = pages.map(page => ({ ...page, text:page.description, page:page.url }));
  let indexLoad;
  let indexIncomplete = false;
  let searchScope;
  let searchOpener;
  function normalize(value) { return value.normalize('NFKD').replace(/[\u0300-\u036f]/g,'').toLowerCase(); }
  function renderResults() {
    const focusedResult=results.contains(document.activeElement) ? document.activeElement.closest('a')?.getAttribute('href') : undefined;
    const terms = normalize(query.value.trim()).split(/\s+/).filter(Boolean);
    const matches = index.filter(item => (!searchScope || item.page === searchScope) && terms.every(term => normalize(item.title+' '+item.text).includes(term)));
    const shown = matches.slice(0,20);
    results.replaceChildren(...shown.map(item => {
      const li = document.createElement('li');
      const a = document.createElement('a'); a.href = item.url;
      const title = document.createElement('strong'); title.textContent = item.title;
      const excerpt = document.createElement('span');
      let text = item.description || item.text;
      const at = terms.length ? normalize(text).indexOf(terms[0]) : 0;
      const start = Math.max(0,at-45);
      text = (start ? '…' : '') + text.slice(start,start+150) + (text.length > start+150 ? '…' : '');
      excerpt.textContent = text;
      a.append(title,excerpt); li.append(a);
      a.addEventListener('click', () => finder.close());
      return li;
    }));
    searchStatus.textContent = matches.length ? (matches.length > 20 ? 'Showing 20 of '+matches.length+' results.' : matches.length+' result'+(matches.length===1?'':'s')+'.') : 'No matches. Try “Spaces”, “import”, or “shortcuts”.';
    if (indexIncomplete) searchStatus.textContent += ' Some pages couldn’t load. Reopen search to retry.';
    if (focusedResult) {
      const replacement=[...results.querySelectorAll('a')].find(link=>link.getAttribute('href')===focusedResult);
      (replacement || query).focus({preventScroll:true});
    }
  }
  async function loadIndex() {
    if (!indexLoad) {
      indexLoad = Promise.all(pages.map(async page => {
        const current = location.pathname.split('/').pop() || 'index.html';
        let doc;
        if (page.url === current) doc = document;
        else {
          const response = await fetch(page.url);
          if (!response.ok) throw new Error('Page unavailable');
          doc = new DOMParser().parseFromString(await response.text(),'text/html');
        }
        return [...doc.querySelectorAll('main section[id]')].flatMap(section => {
          const heading = section.querySelector('h2,h3');
          if (!heading) return [];
          return [{ url:page.url+'#'+section.id, title:heading.textContent.trim(), text:section.textContent.replace(/\s+/g,' ').trim(), page:page.url }];
        });
      }).map(promise => promise.catch(() => { indexIncomplete = true; return []; }))).then(groups => {
        index = [...pages.map(page => ({...page,text:page.description,page:page.url})),...groups.flat()];
        if (finder.open) renderResults();
        if (indexIncomplete) indexLoad = undefined;
      });
    }
    return indexLoad;
  }
  function openSearch(source,scope) {
    searchOpener = source;
    searchScope = scope;
    query.value = '';
    query.placeholder = scope === 'docs.html' ? 'Find something in the guide…' : scope === 'privacy.html' ? 'Find something in the privacy policy…' : 'Find a page, feature, or shortcut…';
    indexIncomplete = false;
    renderResults(); finder.showModal(); query.focus(); loadIndex();
  }
  document.querySelectorAll('[data-site-search]').forEach(button => {
    button.hidden = false;
    button.addEventListener('click', () => openSearch(button,button.dataset.searchScope));
  });
  finder.querySelector('.dialog-close').addEventListener('click', () => finder.close());
  backdropClose(finder);
  finder.addEventListener('close', () => searchOpener?.focus({preventScroll:true}));
  query.addEventListener('input',renderResults);
  query.addEventListener('keydown',event => { if (event.key==='Enter') { const first=results.querySelector('a'); if(first) { event.preventDefault(); first.click(); } } });
  finder.addEventListener('keydown',event => {
    const links = [...results.querySelectorAll('a')];
    if (!['ArrowDown','ArrowUp'].includes(event.key) || !links.length) return;
    event.preventDefault();
    const at = links.indexOf(document.activeElement);
    if (event.key === 'ArrowDown') links[(at+1)%links.length].focus();
    else if (at<=0) query.focus();
    else links[at-1].focus();
  });
  document.addEventListener('keydown',event => {
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase()==='k' && !document.querySelector('dialog[open]')) {
      event.preventDefault(); openSearch(document.activeElement);
    }
  });

  // Keep the reader's current topic visible in the table of contents.
  const toc = document.querySelector('.guide-toc');
  if (toc) {
    const links = [...toc.querySelectorAll('a[href^="#"]')];
    const sections = links.map(link => document.getElementById(link.hash.slice(1))).filter(Boolean);
    let scheduled = false;
    function updateToc() {
      scheduled = false;
      let active = sections[0];
      sections.forEach(section => { if (section.getBoundingClientRect().top < innerHeight*.35) active=section; });
      links.forEach(link => { if (link.hash === '#'+active?.id) link.setAttribute('aria-current','location'); else link.removeAttribute('aria-current'); });
    }
    addEventListener('scroll',() => { if (!scheduled) { scheduled=true; requestAnimationFrame(updateToc); } },{passive:true});
    updateToc();
  }
  const shortcutQuery = document.querySelector('#shortcut-query');
  if (shortcutQuery) {
    const tables = [...document.querySelectorAll('#shortcuts table')];
    const count = document.querySelector('#shortcut-count');
    shortcutQuery.addEventListener('input',() => {
      const term = normalize(shortcutQuery.value.trim());
      let total=0;
      tables.forEach(table => {
        let shown=0;
        [...table.rows].slice(1).forEach(row => { row.hidden = !normalize(row.textContent).includes(term); if (!row.hidden) shown++; });
        table.hidden = !shown;
        const heading=table.previousElementSibling;
        if (heading?.tagName==='H3') heading.hidden=!shown;
        total+=shown;
      });
      count.textContent = total ? total+' matching command'+(total===1?'':'s') : 'No matching commands. Try another name or key.';
    });
  }
  document.querySelectorAll('[data-copy-command]').forEach(button => {
    button.hidden=false;
    button.addEventListener('click',async () => {
      const code = document.getElementById(button.dataset.copyCommand);
      const status = button.parentElement.querySelector('[role="status"]');
      try { await navigator.clipboard.writeText(code.textContent); status.textContent='Command copied.'; }
      catch { status.textContent='Couldn’t copy. Select the command to copy it manually.'; }
    });
  });
  reduceMotion.addEventListener('change',() => { if (reduceMotion.matches) document.querySelectorAll('[data-feature-group]').forEach(card=>card.getAnimations().forEach(animation=>animation.finish())); });
  const filters=[...document.querySelectorAll('[data-feature-filter]')];
  const cards=[...document.querySelectorAll('[data-feature-group]')];
  filters.forEach(button => button.addEventListener('click',() => {
    const group=button.dataset.featureFilter;
    filters.forEach(filter => filter.setAttribute('aria-pressed',String(filter===button)));
    let count=0;
    cards.forEach(card => {
      card.hidden = group!=='all' && !card.dataset.featureGroup.split(' ').includes(group);
      if (!card.hidden) {
        count++;
        card.getAnimations().forEach(animation=>animation.cancel());
        if (!reduceMotion.matches) card.animate([{opacity:.35,transform:'translateY(5px)'},{opacity:1,transform:'translateY(0)'}],{duration:220,easing:'cubic-bezier(.16,1,.3,1)'});
      }
    });
    document.querySelector('#feature-count').textContent=count+' features shown';
  }));

  const sidebar = document.querySelector('.sidebar-explorer-section');
  if (sidebar) {
    const description=sidebar.querySelector('#sidebar-explanation');
    const frame=sidebar.querySelector('.sidebar-window');
    const detail=sidebar.querySelector('.sidebar-detail-image');
    const buttons=[...sidebar.querySelectorAll('[data-sidebar-topic]')];
    const original=sidebar.querySelector('.sidebar-original');
    const resetZoom=sidebar.querySelector('.sidebar-zoom-reset');
    const lens=document.createElement('div');lens.className='sidebar-highlight';lens.setAttribute('aria-hidden','true');
    const magnified=document.createElement('img');magnified.className='sidebar-magnified-image';magnified.alt='';magnified.loading='lazy';magnified.src=detail.currentSrc||detail.src;lens.append(magnified);
    sidebar.querySelector('.sidebar-window-images').append(lens);
    const topics={
      favourites:{text:'Favourites stay with you as you move between Spaces.',x:.005469,y:.103571,w:.167188,h:.059524},
      pins:{text:'Keep the pages you return to in their Space. Pin them, rename them, and group them in folders.',x:.005469,y:.226,w:.167188,h:.032},
      today:{text:'The pages you’re browsing now, with older tabs kept in the Archive.',x:.005469,y:.345,w:.167188,h:.143},
      spaces:{text:'Work, personal browsing, and projects can each have a Space of their own.',x:.055,y:.95,w:.085,h:.035}
    };
    let selected='favourites';let zoomed=false;let topicRequest=0;
    function paintDetail(){
      const region=topics[selected];const scale=zoomed?1.75:1;
      const width=region.w*scale,height=region.h*scale;
      const clamp=(value,min,max)=>Math.max(min,Math.min(value,max));
      const left=zoomed?clamp(region.x,.004,1-width-.004):region.x;
      const top=zoomed?clamp(region.y,.004,1-height-.004):region.y;
      Object.assign(lens.style,{left:left*100+'%',top:top*100+'%',width:width*100+'%',height:height*100+'%'});
      Object.assign(magnified.style,{width:100/region.w+'%',left:-region.x/region.w*100+'%',top:-region.y/region.h*100+'%'});
      lens.classList.toggle('is-magnified',zoomed);resetZoom.hidden=!zoomed;
    }
    resetZoom.addEventListener('click',()=>{buttons.find(button=>button.dataset.sidebarTopic===selected).focus({preventScroll:true});zoomed=false;paintDetail();});
    reduceMotion.addEventListener('change',()=>{if(reduceMotion.matches){zoomed=false;paintDetail();}});
    async function selectTopic(button){
      const token=++topicRequest;frame.setAttribute('aria-busy','true');
      if(detail.complete&&!detail.naturalWidth)detail.src=detail.getAttribute('src');
      try{await detail.decode();}catch{if(token===topicRequest){frame.removeAttribute('aria-busy');description.textContent='This view couldn’t load. Choose a topic to retry.';}return;}
      if(token!==topicRequest)return;
      frame.removeAttribute('aria-busy');selected=button.dataset.sidebarTopic;zoomed=!reduceMotion.matches;
      buttons.forEach(item=>{const active=item===button;item.setAttribute('aria-selected',String(active));item.tabIndex=active?0:-1;});
      frame.setAttribute('aria-labelledby',button.id);original.href=detail.src;description.textContent=topics[selected].text;
      magnified.src=detail.currentSrc||detail.src;paintDetail();
    }
    buttons.forEach((button,i)=>{
      button.disabled=false;button.addEventListener('click',()=>selectTopic(button));
      button.addEventListener('keydown',event=>{let next;if(event.key==='ArrowDown'||event.key==='ArrowRight')next=(i+1)%buttons.length;if(event.key==='ArrowUp'||event.key==='ArrowLeft')next=(i-1+buttons.length)%buttons.length;if(event.key==='Home')next=0;if(event.key==='End')next=buttons.length-1;if(next!==undefined){event.preventDefault();buttons[next].focus();selectTopic(buttons[next]);}});
    });
    paintDetail();
  }

  // Keep question targets fixed and let every answer share one reserved space.
  // Native details remain the fallback when scripting is unavailable.
  const questions=document.querySelector('.mac-questions');
  if(questions){
    const entries=[...questions.querySelectorAll('details')];
    const list=document.createElement('div');list.className='mac-question-list';list.setAttribute('role','tablist');list.setAttribute('aria-label','About Vane for Mac');list.setAttribute('aria-orientation','vertical');
    const stack=document.createElement('div');stack.className='mac-answer-stack';
    const buttons=[];const panels=[];
    entries.forEach((entry,i)=>{
      const summary=entry.querySelector('summary');
      const button=document.createElement('button');button.type='button';button.className='mac-question';button.id='mac-question-'+i;button.setAttribute('role','tab');button.setAttribute('aria-controls','mac-answer-'+i);
      button.append(...summary.childNodes);list.append(button);buttons.push(button);
      const panel=document.createElement('div');panel.className='mac-answer';panel.id='mac-answer-'+i;panel.setAttribute('role','tabpanel');panel.setAttribute('aria-labelledby',button.id);panel.tabIndex=0;
      panel.append(...[...entry.children].filter(child=>child!==summary));stack.append(panel);panels.push(panel);
    });
    function selectQuestion(index,animate=true){
      buttons.forEach((button,i)=>{button.setAttribute('aria-selected',String(i===index));button.tabIndex=i===index?0:-1;});
      panels.forEach((panel,i)=>{panel.classList.toggle('is-active',i===index);panel.inert=i!==index;panel.setAttribute('aria-hidden',String(i!==index));panel.getAnimations().forEach(animation=>animation.cancel());});
      if(animate&&!reduceMotion.matches)panels[index].animate([{opacity:.35},{opacity:1}],{duration:140});
    }
    questions.replaceChildren(list,stack);
    buttons.forEach((button,i)=>{
      button.addEventListener('click',()=>selectQuestion(i));
      button.addEventListener('keydown',event=>{
        let next;if(event.key==='ArrowDown'||event.key==='ArrowRight')next=(i+1)%buttons.length;if(event.key==='ArrowUp'||event.key==='ArrowLeft')next=(i-1+buttons.length)%buttons.length;if(event.key==='Home')next=0;if(event.key==='End')next=buttons.length-1;
        if(next!==undefined){event.preventDefault();buttons[next].focus();selectQuestion(next);}
      });
    });
    selectQuestion(0,false);
  }

  const zoomImages=[...document.querySelectorAll('[data-zoom]')];
  if (zoomImages.length) {
    const dialog=document.createElement('dialog'); dialog.className='capture-dialog'; dialog.setAttribute('aria-label','App screenshot');
    dialog.innerHTML='<div class="capture-toolbar"><span>Vane</span><div><button class="capture-zoom" type="button" aria-pressed="false">Zoom in</button><button class="dialog-close" type="button" aria-label="Close screenshot">Close '+arrow+'</button></div></div><img alt="">';
    document.body.append(dialog); const image=dialog.querySelector('img'); const zoom=dialog.querySelector('.capture-zoom'); let opener;
    function reset() { dialog.classList.remove('is-zoomed'); zoom.textContent='Zoom in'; zoom.setAttribute('aria-pressed','false'); dialog.scrollTo(0,0); }
    zoomImages.forEach(source => {
      const button=document.createElement('button'); button.type='button'; button.className='capture-button'; button.setAttribute('aria-label','View full-size app screenshot');
      source.replaceWith(button); button.append(source);
      button.addEventListener('click',() => { opener=button; reset(); image.src=source.src; image.alt=source.alt; dialog.querySelector('.capture-toolbar > span').textContent=source.alt; dialog.showModal(); });
    });
    zoom.addEventListener('click',() => { const active=dialog.classList.toggle('is-zoomed'); zoom.textContent=active?'Fit window':'Zoom in'; zoom.setAttribute('aria-pressed',String(active)); if(!active)dialog.scrollTo(0,0); });
    dialog.querySelector('.dialog-close').addEventListener('click',()=>dialog.close());
    dialog.addEventListener('close',()=>{reset();opener?.focus({preventScroll:true});}); backdropClose(dialog);
  }
})();
