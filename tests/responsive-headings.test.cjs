const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');

// A layout-only line break must not be the only separator between words:
// hiding it on a smaller screen otherwise joins the words together.
let checked = 0;
for (const file of ['index.html', 'features.html', 'docs.html', 'download.html', 'privacy.html']) {
  const html = fs.readFileSync(path.join(__dirname, '..', file), 'utf8');
  for (const [, heading] of html.matchAll(/<h[1-6]\b[^>]*>([\s\S]*?)<\/h[1-6]>/g)) {
    if (!/<br\b/i.test(heading)) continue;
    const text = heading.replace(/<br\s*\/?\s*>/gi, '\0').replace(/<[^>]+>/g, '');
    assert.ok(!/\S\0\S/.test(text), `${file}: words join when the heading's line break is hidden: ${text.replaceAll('\0', '')}`);
    checked++;
  }
}
assert.ok(checked > 0, 'The fixture must exercise the real display headings');
console.log(`PASS: ${checked} display headings preserve word separation across responsive line breaks`);
