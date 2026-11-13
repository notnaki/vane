(() => {
  'use strict';
  const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
  const tabs = [...document.querySelectorAll('[data-view]')];
  const panel = document.querySelector('#demo-panel');
  const mainImage = document.querySelector('#main-capture');
  const mainOpener = document.querySelector('#main-opener');
  const littleWindow = document.querySelector('#little-capture');
  const description = document.querySelector('#demo-description');
  const status = document.querySelector('#demo-status');
  const closeLittle = document.querySelector('#little-close');
  const assets = {
    spaces: {
      src: 'media/vane-varied-spaces-v1.png?v=4',
      alt: 'NASA’s Mars page open in Vane’s lilac Explore Space.',
      description: 'Keep your favourites, pinned pages, and open tabs together in a Space.',
    },
    split: {
      src: 'media/vane-varied-split-v1.png?v=4',
      alt: 'NASA’s Mars page and a Creative Independent interview side by side in Vane.',
      description: 'Open two pages side by side without switching windows.',
    },
    little: {
      src: 'media/vane-varied-little-v1.png?v=4',
      alt: 'Figma’s colourful homepage in a native Little Vane window.',
      description: 'Take a quick look in Little Vane, then return to your main window.',
    }
  };
  const loads = new Map();
  function load(name) {
    if (!loads.has(name)) {
      const image = new Image();
      image.src = assets[name].src;
      loads.set(name, image.decode().then(() => image).catch(error => { loads.delete(name); throw error; }));
    }
    return loads.get(name);
  }
  let baseView = 'spaces';
  let selectedView = 'spaces';
  let request = 0;
  let runningAnimation;
  let incomingImage;
  function stopTransition() {
    runningAnimation?.cancel();
    runningAnimation = undefined;
    incomingImage?.remove();
    incomingImage = undefined;
  }
  function commit(name) {
    selectedView = name;
    tabs.forEach(tab => {
      const selected = tab.dataset.view === name;
      tab.setAttribute('aria-selected', String(selected));
      tab.tabIndex = selected ? 0 : -1;
    });
    panel.setAttribute('aria-labelledby', 'view-' + name);
    description.textContent = assets[name].description;
    closeLittle.hidden = name !== 'little';
    status.textContent = '';
    panel.removeAttribute('aria-busy');
  }
  async function select(name, animate = true) {
    if (name === selectedView && !panel.hasAttribute('aria-busy') && mainImage.complete && mainImage.naturalWidth > 0) return;
    const token = ++request;
    stopTransition();
    panel.setAttribute('aria-busy', 'true');
    status.textContent = 'Loading app capture…';
    try { await load(name); }
    catch {
      if (token === request) {
        panel.removeAttribute('aria-busy');
        status.textContent = 'This capture couldn’t load. Choose a view to try again.';
      }
      return;
    }
    if (token !== request) return;
    const useMotion = animate && !reducedMotion.matches;
    if (name === 'little') {
      littleWindow.hidden = false;
      commit(name);
      if (useMotion) {
        runningAnimation = littleWindow.animate([
          { transform: 'translate(18px, 8px)', opacity: 1 },
          { transform: 'translate(0, 0)', opacity: 1 }
        ], { duration: 280, easing: 'cubic-bezier(.16,1,.3,1)' });
      }
      return;
    }
    littleWindow.hidden = true;
    closeLittle.hidden = true;
    if (name !== baseView && useMotion) {
      const image = new Image();
      image.src = assets[name].src;
      image.alt = '';
      image.setAttribute('aria-hidden', 'true');
      image.className = 'transition-capture';
      incomingImage = image;
      mainOpener.append(image);
      const frames = [{ clipPath: 'inset(0 0 0 18%)', opacity: 0 }, { clipPath: 'inset(0 0 0 18%)', opacity: 1 }];
      runningAnimation = image.animate(frames, { duration: 220, easing: 'cubic-bezier(.16,1,.3,1)', fill: 'forwards' });
      try { await runningAnimation.finished; } catch { /* A newer selection interrupts this reveal. */ }
      if (token !== request) { image.remove(); return; }
    }
    baseView = name;
    mainImage.src = assets[name].src;
    mainImage.alt = assets[name].alt;
    incomingImage?.remove();
    incomingImage = undefined;
    commit(name);
  }
  tabs.forEach((tab, index) => {
    tab.disabled = false;
    tab.addEventListener('click', () => select(tab.dataset.view));
    tab.addEventListener('keydown', event => {
      let next;
      if (event.key === 'ArrowRight') next = (index + 1) % tabs.length;
      if (event.key === 'ArrowLeft') next = (index - 1 + tabs.length) % tabs.length;
      if (event.key === 'Home') next = 0;
      if (event.key === 'End') next = tabs.length - 1;
      if (next === undefined) return;
      event.preventDefault();
      tabs[next].focus();
      select(tabs[next].dataset.view, false);
    });
  });
  closeLittle.addEventListener('click', () => {
    const returnTab = tabs.find(tab => tab.dataset.view === baseView);
    returnTab.focus({ preventScroll: true });
    select(baseView);
  });
  panel.addEventListener('keydown', event => {
    if (event.key === 'Escape' && !littleWindow.hidden) {
      event.preventDefault();
      tabs.find(tab => tab.dataset.view === baseView).focus({ preventScroll: true });
      select(baseView, false);
    }
  });
  reducedMotion.addEventListener('change', () => {
    if (reducedMotion.matches) runningAnimation?.finish();
  });

  const dialog = document.querySelector('.image-dialog');
  const dialogImage = document.querySelector('#dialog-image');
  const dialogTitle = document.querySelector('#dialog-title');
  const zoom = document.querySelector('#dialog-zoom');
  const originalCapture = document.querySelector('#original-capture');
  function resetZoom() {
    dialog.classList.remove('is-zoomed');
    zoom.setAttribute('aria-pressed', 'false');
    zoom.textContent = 'Zoom in';
    dialog.scrollTo(0, 0);
  }
  zoom.addEventListener('click', () => {
    const enlarged = dialog.classList.toggle('is-zoomed');
    zoom.setAttribute('aria-pressed', String(enlarged));
    zoom.textContent = enlarged ? 'Fit window' : 'Zoom in';
    if (!enlarged) dialog.scrollTo(0, 0);
  });
  let opener;
  function enlarge(name, source) {
    opener = source;
    resetZoom();
    originalCapture.href = assets[name].src;
    dialogImage.src = assets[name].src;
    dialogImage.alt = assets[name].alt;
    dialogTitle.textContent = (name === 'little' ? 'Little Vane' : name === 'split' ? 'Vane · Split View' : 'Vane · Explore Space') + ' — native app capture';
    dialog.showModal();
    document.body.classList.add('dialog-open');
  }
  mainOpener.addEventListener('click', () => enlarge(baseView, mainOpener));
  const littleOpener = document.querySelector('#little-opener');
  littleOpener.addEventListener('click', () => enlarge('little', littleOpener));
  const enlargeCurrent = document.querySelector('#enlarge-current');
  enlargeCurrent.addEventListener('click', () => enlarge(selectedView === 'little' ? 'little' : baseView, enlargeCurrent));
  dialog.querySelector('.dialog-close').addEventListener('click', () => dialog.close());
  dialog.addEventListener('click', event => {
    if (event.target !== dialog) return;
    const bounds = dialog.getBoundingClientRect();
    if (event.clientX < bounds.left || event.clientX > bounds.right || event.clientY < bounds.top || event.clientY > bounds.bottom) dialog.close();
  });
  dialog.addEventListener('close', () => {
    document.body.classList.remove('dialog-open');
    resetZoom();
    opener?.focus({ preventScroll: true });
  });
  function initialCaptureFailed() {
    status.textContent = 'The app capture couldn’t load. Select Spaces to retry.';
  }
  mainImage.addEventListener('error', initialCaptureFailed);
  mainImage.addEventListener('load', () => { if (!panel.hasAttribute('aria-busy')) status.textContent = ''; });
  // Native captures preload after the visible first image; no automatic view cycling.
  mainImage.decode().catch(initialCaptureFailed).then(() => {
    load('split').catch(() => {});
    load('little').catch(() => {});
  });
})();
