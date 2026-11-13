(() => {
  'use strict';
  const video = document.querySelector('#vane-session');
  const toggle = document.querySelector('.session-playback');
  if (!video || !toggle || !('IntersectionObserver' in window)) return;
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  let visible = false;
  let userPaused = false;
  let userStarted = false;
  let failed = false;
  video.muted = true;
  video.controls = false;
  toggle.hidden = false;

  function update() {
    const playing = !video.paused;
    toggle.classList.toggle('is-playing', playing);
    toggle.setAttribute('aria-label', playing ? 'Pause video' : 'Play video');
  }
  function sync() {
    if (failed) return;
    if (!visible || document.hidden || userPaused || (reduced.matches && !userStarted)) {
      video.pause();
    } else {
      video.play().catch(update);
    }
  }
  toggle.addEventListener('click', () => {
    if (video.paused) {
      userStarted = true;
      userPaused = false;
      video.play().catch(update);
    } else {
      userPaused = true;
      video.pause();
    }
  });
  video.addEventListener('play', update);
  video.addEventListener('pause', update);
  video.addEventListener('error', () => {
    failed = true;
    toggle.hidden = true;
    video.controls = true;
  });
  new IntersectionObserver(entries => {
    visible = entries[0].isIntersecting;
    sync();
  }, { threshold: 0 }).observe(video);
  document.addEventListener('visibilitychange', sync);
  reduced.addEventListener('change', () => {
    userStarted = false;
    sync();
  });
  update();
})();
