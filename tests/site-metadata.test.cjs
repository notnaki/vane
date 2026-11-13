const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = path.join(__dirname, '..');
const site = 'https://vane.so/';
const pages = ['index.html', 'features.html', 'docs.html', 'download.html', 'privacy.html'];
const image = site + 'media/vane-share-20261113.png';

for (const page of pages) {
  const source = fs.readFileSync(path.join(root, page), 'utf8');
  const meta = Object.fromEntries([...source.matchAll(/<meta\s+(?:name|property)="([^"]+)"\s+content="([^"]*)"\s*\/?\s*>/g)].map(match => [match[1], match[2]]));
  const canonical = site + (page === 'index.html' ? '' : page);
  assert.ok(source.includes(`<link rel="canonical" href="${canonical}">`), page);
  assert.equal(meta['og:url'], canonical, page);
  assert.equal(meta['og:image'], image, page);
  assert.equal(meta['og:image:type'], 'image/png', page);
  assert.equal(meta['og:image:width'], '1200', page);
  assert.equal(meta['og:image:height'], '630', page);
  assert.ok(meta['og:image:alt'], page);
  assert.equal(meta['twitter:card'], 'summary_large_image', page);
  assert.equal(meta['twitter:image'], image, page);
  assert.ok(source.includes('rel="apple-touch-icon"'), page);
  assert.ok(!/noindex/i.test(meta.robots || ''), page);
}
const png = fs.readFileSync(path.join(root, 'media/vane-share-20261113.png'));
assert.equal(png.subarray(1, 4).toString(), 'PNG');
assert.equal(png.readUInt32BE(16), 1200);
assert.equal(png.readUInt32BE(20), 630);
const home = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
const graph = JSON.parse(home.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)[1])['@graph'];
assert.ok(graph.some(item => item['@type'] === 'WebSite' && item.url === site && item.name === 'Vane'));
assert.ok(graph.some(item => item['@type'] === 'SoftwareApplication' && /macOS/.test(item.operatingSystem)));
const sitemap = fs.readFileSync(path.join(root, 'sitemap.xml'), 'utf8');
for (const page of pages) assert.ok(sitemap.includes(`<loc>${site}${page === 'index.html' ? '' : page}</loc>`));
assert.ok(fs.readFileSync(path.join(root, 'robots.txt'), 'utf8').includes(`Sitemap: ${site}sitemap.xml`));
console.log('PASS: five canonical pages expose a real 1200×630 share image, site/app identity, and crawlable sitemap');
