const tabs = [...document.querySelectorAll('[data-feature]')];
const captures = [...document.querySelectorAll('[data-capture]')];
const explanation = document.querySelector('#tour-explanation');
const panel = document.querySelector('#tour-panel');
const descriptions = {
  spaces: 'Keep research, projects, and everyday pages together in a Space.',
  split: 'Bring two pages together without switching windows.',
  little: 'Take a quick look in Little Vane, then return to your main window.'
};
let tourMotion;
const tourReduceMotion=matchMedia('(prefers-reduced-motion: reduce)');
tourReduceMotion.addEventListener('change',()=>{ if(tourReduceMotion.matches) tourMotion?.finish(); });
function select(name, updateHash = true) {
  tourMotion?.cancel();
  const feature = tabs.some(tab => tab.dataset.feature === name) ? name : 'spaces';
  tabs.forEach(tab => {
    const selected = tab.dataset.feature === feature;
    tab.setAttribute('aria-selected', String(selected));
    tab.tabIndex = selected ? 0 : -1;
  });
  captures.forEach(capture => {
    const selected = capture.dataset.capture === feature;
    capture.classList.toggle('is-active', selected);
    capture.setAttribute('aria-hidden', String(!selected));
  });
  if (feature === 'little' && !matchMedia('(prefers-reduced-motion: reduce)').matches) {
    tourMotion = document.querySelector('[data-capture="little"] .capture-floating').animate([{transform:'translate(16px,6px)'},{transform:'translate(0,0)'}],{duration:260,easing:'cubic-bezier(.16,1,.3,1)'});
  }
  panel.setAttribute('aria-labelledby', 'tab-' + feature);
  explanation.textContent = descriptions[feature];
  if (updateHash) history.replaceState(null, '', '#' + feature);
}
tabs.forEach((tab, i) => {
  tab.addEventListener('click', () => select(tab.dataset.feature));
  tab.addEventListener('keydown', event => {
    let index;
    if (event.key === 'ArrowRight') index = (i + 1) % tabs.length;
    if (event.key === 'ArrowLeft') index = (i + tabs.length - 1) % tabs.length;
    if (event.key === 'Home') index = 0;
    if (event.key === 'End') index = tabs.length - 1;
    if (index !== undefined) {
      event.preventDefault();
      select(tabs[index].dataset.feature);
      tabs[index].focus();
    }
  });
});
window.addEventListener('hashchange', () => select(location.hash.slice(1), false));
select(location.hash.slice(1), false);
