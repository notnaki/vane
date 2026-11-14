(() => {
  const root = document.documentElement;

  // Theme: dark unless the visitor chose light.
  const toggle = document.querySelector('.theme-toggle');
  const syncTheme = () => toggle.setAttribute('aria-pressed', String(root.dataset.theme === 'light'));
  toggle.addEventListener('click', () => {
    const light = root.dataset.theme !== 'light';
    if (light) root.dataset.theme = 'light'; else delete root.dataset.theme;
    try { localStorage.theme = light ? 'light' : 'dark'; } catch (error) { /* private mode: the choice lasts for this page */ }
    syncTheme();
  });
  syncTheme();

  // Homepage video: plays by itself unless Reduce Motion is on; the button always works.
  const video = document.getElementById('vane-session');
  if (video) {
    const button = document.querySelector('.stage-toggle');
    const syncVideo = () => {
      button.dataset.playing = String(!video.paused);
      button.setAttribute('aria-label', video.paused ? 'Play video' : 'Pause video');
    };
    video.addEventListener('play', syncVideo);
    video.addEventListener('pause', syncVideo);
    button.addEventListener('click', () => (video.paused ? video.play() : video.pause()));
    syncVideo();
    if (!matchMedia('(prefers-reduced-motion: reduce)').matches) video.play().catch(() => {});
  }

  // Homepage tour: one list of features, one capture at a time.
  const tabs = [...document.querySelectorAll('.tour-tab')];
  if (tabs.length) {
    const panel = document.getElementById('tour-panel');
    const select = tab => {
      for (const other of tabs) {
        other.setAttribute('aria-selected', String(other === tab));
        other.tabIndex = other === tab ? 0 : -1;
      }
      for (const image of panel.querySelectorAll('img')) image.hidden = image.dataset.tour !== tab.dataset.tour;
      panel.setAttribute('aria-labelledby', tab.id);
    };
    // Wide screens: the section stays put and scrolling walks through the list. Small screens: tap to switch.
    const section = document.querySelector('.tour');
    const wide = matchMedia('(min-width: 901px)');
    const span = () => section.offsetHeight - innerHeight;
    const onScroll = () => {
      if (!wide.matches) return;
      const progress = Math.min(0.999, Math.max(0, -section.getBoundingClientRect().top / span()));
      const tab = tabs[Math.floor(progress * tabs.length)];
      if (tab.getAttribute('aria-selected') !== 'true') select(tab);
    };
    addEventListener('scroll', onScroll, { passive: true });
    const go = (tab, index) => {
      if (!wide.matches) return select(tab);
      const top = section.getBoundingClientRect().top + scrollY + ((index + 0.5) / tabs.length) * span();
      scrollTo({ top, behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth' });
    };
    for (const [index, tab] of tabs.entries()) {
      tab.addEventListener('click', () => go(tab, index));
      tab.addEventListener('keydown', event => {
        const step = { ArrowDown: 1, ArrowUp: -1 }[event.key];
        if (!step) return;
        event.preventDefault();
        const next = (index + step + tabs.length) % tabs.length;
        tabs[next].focus({ preventScroll: true });
        go(tabs[next], next);
      });
    }
  }

  // Guide and privacy: the contents list is collapsed on small screens.
  const contents = document.querySelector('.toc details');
  if (contents) {
    const small = matchMedia('(max-width: 900px)');
    const syncContents = () => { contents.open = !small.matches; };
    small.addEventListener('change', syncContents);
    syncContents();
    contents.addEventListener('click', event => { if (small.matches && event.target.closest('a')) contents.open = false; });
  }

  // Guide: filter the shortcut tables.
  const query = document.getElementById('shortcut-query');
  if (query) {
    const tables = [...document.querySelectorAll('#shortcuts table')];
    const count = document.getElementById('shortcut-count');
    query.addEventListener('input', () => {
      const term = query.value.trim().toLowerCase();
      let total = 0;
      for (const table of tables) {
        let shown = 0;
        for (const row of [...table.rows].slice(1)) {
          row.hidden = !row.textContent.toLowerCase().includes(term);
          if (!row.hidden) shown++;
        }
        table.hidden = !shown;
        const heading = table.previousElementSibling;
        if (heading && heading.tagName === 'H3') heading.hidden = !shown;
        total += shown;
      }
      count.textContent = term ? (total ? `${total} shortcut${total === 1 ? '' : 's'} found` : 'No shortcuts match. Try a shorter word.') : '';
    });
  }

  // Download: copy the build command.
  for (const button of document.querySelectorAll('[data-copy-command]')) {
    button.hidden = false;
    button.addEventListener('click', async () => {
      const status = button.parentElement.querySelector('[role="status"]');
      try {
        await navigator.clipboard.writeText(document.getElementById(button.dataset.copyCommand).textContent);
        status.textContent = 'Command copied.';
      } catch (error) {
        status.textContent = 'Couldn’t copy. Select the command to copy it manually.';
      }
    });
  }
})();
