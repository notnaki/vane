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
    const saveData = navigator.connection && navigator.connection.saveData;
    if (!matchMedia('(prefers-reduced-motion: reduce)').matches && !saveData) video.play().catch(() => {});
  }

  const still = matchMedia('(prefers-reduced-motion: reduce)').matches;

  // Hills: a soft grainy hill rises with scroll until its core fills the screen.
  // Each .rise names a CSS custom property (data-ramp) holding its colours, outer to core, and gets --p (0…1).
  const hex = h => [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16));
  const mix = (a, b, t) => a.map((v, i) => Math.round(v + (b[i] - v) * t));
  const modest = (navigator.hardwareConcurrency || 8) <= 4; // older and low-power devices draw a coarser hill
  for (const section of document.querySelectorAll('.rise')) {
    const canvas = section.querySelector('canvas');
    const ctx = canvas.getContext('2d');
    ctx.filter = 'blur(2px)';
    const filters = ctx.filter === 'blur(2px)'; // older Safari has no canvas filters: blur the element instead
    if (!filters) canvas.classList.add('soft');
    const BANDS = modest ? 16 : 26, SCALE = modest ? 6 : 4;
    let key = '', stops = [], lean = 0.5, target = 0.5, queued = false;
    const ramp = t => {
      const x = t * (stops.length - 1), i = Math.min(stops.length - 2, Math.floor(x));
      return `rgb(${mix(stops[i], stops[i + 1], x - i)})`;
    };
    const draw = () => {
      queued = false;
      const r = section.getBoundingClientRect();
      const p = Math.min(1, Math.max(0, -r.top / (r.height - innerHeight)));
      section.style.setProperty('--p', p.toFixed(3));
      section.toggleAttribute('data-late-shown', p > (+section.dataset.late || 0.42));
      if (r.bottom < 0 || r.top > innerHeight) return; // off screen: nothing to draw
      const value = getComputedStyle(section).getPropertyValue('--' + section.dataset.ramp).trim();
      if (value !== key) { key = value; stops = value.split(',').map(s => hex(s.trim())); }
      if (stops.length < 2 || stops.some(s => s.some(Number.isNaN))) return;
      lean += (target - lean) * 0.08;
      const W = canvas.width = Math.ceil(innerWidth / SCALE), H = canvas.height = Math.ceil(innerHeight / SCALE);
      const e = p * p * (3 - 2 * p); // smoothstep
      const peak = H * (0.18 + 3.9 * e ** 1.35), half = W * (0.42 + 1.25 * e), cx = W * (0.5 + (lean - 0.5) * 0.18);
      ctx.fillStyle = ramp(0);
      ctx.fillRect(0, 0, W, H);
      if (filters) ctx.filter = `blur(${(2 + 7 * e).toFixed(1)}px)`;
      for (let b = 0; b < BANDS; b++) {
        const t = b / (BANDS - 1), h = peak * (1 - 0.62 * t), w = half * (1 - 0.38 * t);
        ctx.beginPath();
        ctx.moveTo(-20, H + 20);
        for (let x = -20; x <= W + 20; x += 2) ctx.lineTo(x, H - h * Math.exp(-2.1 * ((x - cx) / w) ** 2));
        ctx.lineTo(W + 20, H + 20);
        ctx.fillStyle = ramp(t);
        ctx.fill();
      }
      if (filters) ctx.filter = 'none';
      if (Math.abs(target - lean) > 0.002) queue();
    };
    const queue = () => { if (!queued) { queued = true; requestAnimationFrame(draw); } };
    addEventListener('scroll', queue, { passive: true });
    addEventListener('resize', queue);
    new MutationObserver(queue).observe(root, { attributes: true, attributeFilter: ['data-theme'] });
    if (!still && matchMedia('(pointer: fine)').matches) addEventListener('pointermove', event => { target = event.clientX / innerWidth; queue(); }, { passive: true });
    draw();
  }

  // Headline: each word rises out of a blur.
  for (const heading of document.querySelectorAll('.reveal')) {
    heading.innerHTML = heading.textContent.trim().split(/\s+/).map((word, i) => `<span class="w" style="--i:${i}">${word}</span>`).join(' ');
  }

  // Held sections expose their scroll progress as --p, and data-step when they step through items.
  const tracks = [...document.querySelectorAll('.track')];
  const sync = () => {
    for (const t of tracks) {
      const r = t.getBoundingClientRect();
      const p = Math.min(1, Math.max(0, -r.top / Math.max(1, r.height - innerHeight)));
      t.style.setProperty('--p', p.toFixed(4));
      if (t.dataset.steps) t.dataset.step = Math.min(+t.dataset.steps - 1, Math.floor(p * t.dataset.steps));
    }
  };
  if (tracks.length) { addEventListener('scroll', () => requestAnimationFrame(sync), { passive: true }); addEventListener('resize', sync); sync(); }

  // Manifesto: words fill in as you scroll.
  for (const text of document.querySelectorAll('.fill-in')) {
    const words = text.textContent.trim().split(/\s+/);
    text.style.setProperty('--n', words.length);
    text.innerHTML = words.map((word, i) => `<span style="--i:${i}">${word}</span>`).join(' ');
  }

  // Cards: a soft light follows the pointer.
  for (const card of document.querySelectorAll('.spot')) {
    card.addEventListener('pointermove', event => {
      const r = card.getBoundingClientRect();
      card.style.setProperty('--x', `${event.clientX - r.left}px`);
      card.style.setProperty('--y', `${event.clientY - r.top}px`);
    });
  }

  // Guide and privacy: the contents list is collapsed on small screens.
  const contents = document.querySelector('.toc details');
  if (contents) {
    const small = matchMedia('(max-width: 900px)');
    const syncContents = () => { contents.open = !small.matches; };
    small.addEventListener('change', syncContents);
    syncContents();
    contents.addEventListener('click', event => { if (small.matches && event.target.closest('a')) contents.open = false; });

    // Mark the section being read: the lowest heading that has passed the upper third of the screen.
    const links = [...contents.querySelectorAll('nav a[href^="#"]')];
    const targets = links.map(link => document.getElementById(decodeURIComponent(link.hash.slice(1))));
    let current, queued = false;
    const spy = () => {
      queued = false;
      const end = innerHeight + scrollY >= document.documentElement.scrollHeight - 2; // bottom reached: the lowest section
      let i = 0, best = -Infinity; // the list isn't in page order, so compare positions
      targets.forEach((t, k) => { const top = t ? t.getBoundingClientRect().top : -Infinity; if ((end || top < innerHeight / 3) && top > best) { best = top; i = k; } });
      const link = links[i];
      if (link === current) return;
      current?.removeAttribute('aria-current');
      (current = link).setAttribute('aria-current', 'location');
      const box = contents.parentElement; // keep it visible in the sidebar's own scroll without moving the page
      if (!small.matches && (link.offsetTop < box.scrollTop || link.offsetTop + link.offsetHeight > box.scrollTop + box.clientHeight)) box.scrollTop = link.offsetTop - box.clientHeight / 2;
    };
    addEventListener('scroll', () => { if (!queued) { queued = true; requestAnimationFrame(spy); } }, { passive: true });
    spy();
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
  // byearc toast: a gentle ask to vote for Vane, shown once until dismissed.
  let seen = false;
  try { seen = localStorage.byearcToast === 'done'; } catch (error) { /* private mode: show it */ }
  if (!seen) {
    const toast = document.createElement('aside');
    toast.className = 'toast';
    toast.setAttribute('aria-label', 'Vote for Vane');
    toast.innerHTML = '<p><strong>Enjoying Vane?</strong> Vote for it and leave a review on byearc.</p>'
      + '<a class="toast-cta" href="https://byearc.com/browsers/vane" target="_blank" rel="noopener">Vote on byearc</a>'
      + '<button class="toast-close" type="button" aria-label="Dismiss">&times;</button>';
    const done = () => {
      try { localStorage.byearcToast = 'done'; } catch (error) { /* private mode */ }
      toast.dataset.shown = 'false';
      setTimeout(() => toast.remove(), 400);
    };
    toast.querySelector('.toast-close').addEventListener('click', done);
    toast.querySelector('.toast-cta').addEventListener('click', done);
    document.body.append(toast);
    setTimeout(() => { toast.dataset.shown = 'true'; }, 4000);
  }
})();
