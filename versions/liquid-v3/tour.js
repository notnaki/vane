const tabs = [...document.querySelectorAll('[data-feature]')];
const content = document.querySelector('#demo-content');
const explanation = document.querySelector('#tour-explanation');
const panel = document.querySelector('#tour-panel');
let space = 'Personal';
let feature = 'spaces';
const spaceData = { Personal: ['Reading list', 'Weekend plans', 'Recipes'], Work: ['Project notes', 'Research', 'Team calendar'], Explore: ['Why do cats purr?', 'The deep sea', 'One more question'] };
function render() {
  document.querySelector('.space-switches').hidden = feature !== 'spaces';
  document.querySelector('#space-name').textContent = space;
  document.querySelector('#demo-tabs').replaceChildren(...spaceData[space].map((name, i) => { const row = document.createElement('div'); row.className = 'preview-tab' + (i === 0 ? ' selected' : ''); row.textContent = name; return row; }));
  document.querySelectorAll('[data-space]').forEach(b => b.setAttribute('aria-pressed', String(b.dataset.space === space)));
  if (feature === 'spaces') {
    content.innerHTML = '<div class="page-label"></div><h2></h2><p></p><div class="page-links"><span></span><span></span></div>';
    content.querySelector('.page-label').textContent = space + ' Space';
    content.querySelector('h2').textContent = space === 'Personal' ? 'A moment for yourself.' : space === 'Work' ? 'Room for your next idea.' : 'Well, that escalated to twelve tabs.';
    content.querySelector('p').textContent = space === 'Personal' ? 'The reads, recipes, and plans you want to come back to.' : space === 'Work' ? 'Your project, research, and calendar. Together when you need them.' : 'One innocent question. A whole new corner of the internet. Keep the rabbit hole in its own Space.';
    content.querySelectorAll('.page-links span').forEach((el, i) => el.textContent = spaceData[space][i]);
    explanation.textContent = 'Work brain. Weekend brain. Rabbit-hole brain. Try a Space button—each one keeps its own tabs together.';
  } else if (feature === 'split') {
    content.innerHTML = '<div class="page-label">Split View</div><div class="split-pages"><article><h3>The reference.</h3><p>Keep the page you’re reading in view while you work. No switching back and forth.</p></article><article><h3>Your next idea.</h3><p>Compare two pages or keep your notes beside your research, in the same window.</p></article></div>';
    explanation.textContent = 'Two pages sit side by side in one window. Keep your context while you read, compare, or write.';
  } else {
    content.innerHTML = '<div class="page-label">Command bar illustration</div><div class="command-demo"><input aria-label="Filter example commands" placeholder="Search examples…"><ul></ul></div>';
    const commands = ['Switch to open tab', 'Search history', 'Open bookmarks', 'Toggle Reader mode', 'New private window'];
    const input = content.querySelector('input');
    const list = content.querySelector('ul');
    function filter() { const matches = commands.filter(c => c.toLowerCase().includes(input.value.toLowerCase())); list.replaceChildren(...(matches.length ? matches : ['No matching examples']).map(c => { const li = document.createElement('li'); li.textContent = c; return li; })); }
    input.addEventListener('input', filter); filter();
    explanation.textContent = 'In Vane, press ⌘⇧P to search tabs, history, bookmarks, and commands. Try filtering these examples above.';
  }
}
function select(name, updateHash = true) {
  feature = tabs.some(t => t.dataset.feature === name) ? name : 'spaces';
  tabs.forEach(t => { const selected = t.dataset.feature === feature; t.setAttribute('aria-selected', String(selected)); t.tabIndex = selected ? 0 : -1; });
  panel.setAttribute('aria-labelledby', 'tab-' + feature);
  if (updateHash) history.replaceState(null, '', '#' + feature);
  render();
}
tabs.forEach((t, i) => {
  t.addEventListener('click', () => select(t.dataset.feature));
  t.addEventListener('keydown', e => { let index; if (e.key === 'ArrowRight') index = (i + 1) % tabs.length; if (e.key === 'ArrowLeft') index = (i + tabs.length - 1) % tabs.length; if (e.key === 'Home') index = 0; if (e.key === 'End') index = tabs.length - 1; if (index !== undefined) { e.preventDefault(); select(tabs[index].dataset.feature); tabs[index].focus(); } });
});
document.querySelectorAll('[data-space]').forEach(b => b.addEventListener('click', () => { space = b.dataset.space; select('spaces'); }));
window.addEventListener('hashchange', () => select(location.hash.slice(1), false));
select(location.hash.slice(1), false);
