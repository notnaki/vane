const tabs = [...document.querySelectorAll('[data-feature]')];
const captures = [...document.querySelectorAll('[data-capture]')];
const explanation = document.querySelector('#tour-explanation');
const panel = document.querySelector('#tour-panel');
const descriptions = {
  spaces: 'A Work Space keeps pinned pages and project tabs together, with Personal and Explore a click away.',
  split: 'Fieldnotes and Project notes, open side by side in a real Vane Split View.',
  little: 'A Reading list page in Little Vane, alongside the main Work Space. Open a link without leaving your main window.'
};
function select(name, updateHash = true) {
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
