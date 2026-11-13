"""Check the primary static site's local assets, page anchors, and canonical sitemap."""
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
NAMES = ["index.html", "features.html", "docs.html", "download.html", "privacy.html"]


class Page(HTMLParser):
    def __init__(self, source):
        super().__init__()
        self.ids, self.refs = [], []
        self.headings = 0
        self.feed(source)

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "id" in attrs:
            self.ids.append(attrs["id"])
        self.headings += tag == "h1"
        for key in ("href", "src", "poster"):
            if key in attrs:
                self.refs.append(attrs[key])
        self.refs += [part.strip().split()[0] for part in attrs.get("srcset", "").split(",") if part.strip()]


pages = {name: Page((ROOT / name).read_text()) for name in NAMES}
references = 0
for name, page in pages.items():
    assert page.headings == 1, (name, "expected one h1")
    assert len(page.ids) == len(set(page.ids)), (name, "duplicate id")
    for ref in page.refs:
        url = urlsplit(ref)
        if url.scheme or url.netloc:
            continue
        target = ROOT / unquote(url.path) if url.path else ROOT / name
        if target.is_dir():
            target /= "index.html"
        assert target.is_file(), (name, "missing asset", ref)
        if url.fragment and target.name in pages:
            assert unquote(url.fragment) in pages[target.name].ids, (name, "missing anchor", ref)
        references += 1

namespace = {"s": "http://www.sitemaps.org/schemas/sitemap/0.9"}
locations = [item.text for item in ET.parse(ROOT / "sitemap.xml").findall("s:url/s:loc", namespace)]
expected = ["https://vane.so/" + ("" if name == "index.html" else name) for name in NAMES]
assert sorted(locations) == sorted(expected), "Sitemap must list each canonical page once"
print(f"PASS: {len(pages)} pages, {references} local references/anchors, and canonical sitemap")
