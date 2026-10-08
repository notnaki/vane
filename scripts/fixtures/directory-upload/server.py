#!/usr/bin/env python3
"""Loopback-only synthetic upload receiver. Persist observations and exact multipart bytes."""
import argparse
import hashlib
import json
from email.parser import BytesParser
from email.policy import default
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

FILES = {"tree/top.txt": b"folder top level\n", "tree/nested/child.bin": bytes([0, 255, 1, 128, 13, 10])}
PAGE = '''<!doctype html><meta charset="utf-8"><title>Directory upload probe</title>
<h1>Directory upload probe</h1><p id="state">No upload received.</p>
<form action="/receive/MODE" method="post" enctype="multipart/form-data">
<input id="files" name="files" type="file" multiple DIRECTORY><button>Send form</button></form>
<pre id="observations"></pre><script>
files.onchange = async () => {
 const entries = await Promise.all(Array.from(files.files, async f => ({name:f.name,
 path:f.webkitRelativePath, hex:Array.from(new Uint8Array(await f.arrayBuffer()),
 b=>b.toString(16).padStart(2,'0')).join('')})));
 observations.textContent=JSON.stringify(entries,null,2);
 await fetch('/observe',{method:'POST',body:JSON.stringify(entries)});
 state.textContent='Selection read; not submitted.';
};</script>'''

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('evidence', type=Path, help='Disposable directory for synthetic files and evidence')
    parser.add_argument('--port', type=int, default=0)
    args = parser.parse_args()
    args.evidence.mkdir(parents=True, exist_ok=True)
    for path, data in FILES.items():
        target = args.evidence / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        ordinary = args.evidence / "files" / Path(path).name
        ordinary.parent.mkdir(parents=True, exist_ok=True)
        ordinary.write_bytes(data)
    events = []
    class Handler(BaseHTTPRequestHandler):
        def respond(self, text, status=200):
            body = text.encode()
            self.send_response(status)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def do_GET(self):
            mode = 'files' if self.path == '/files' else 'directory'
            self.respond(PAGE.replace('DIRECTORY', '' if mode == 'files' else 'webkitdirectory').replace('MODE', mode))
        def do_POST(self):
            body = self.rfile.read(int(self.headers['Content-Length']))
            if self.path == '/observe':
                events.append({'selection': json.loads(body)})
                self.respond('Selection observed; not uploaded.')
            elif self.path in ('/receive/directory', '/receive/files'):
                (args.evidence / 'multipart.bin').write_bytes(body)
                message = BytesParser(policy=default).parsebytes(
                    ('Content-Type: ' + self.headers['Content-Type'] + '\r\nMIME-Version: 1.0\r\n\r\n').encode() + body)
                received = {}
                for part in message.iter_parts():
                    filename = part.get_filename()
                    data = part.get_payload(decode=True)
                    received[filename] = data
                # Compare the whole map, including paths, binary bytes and file count.
                expected = FILES if self.path == '/receive/directory' else {
                    Path(p).name: d for p, d in FILES.items()}
                ok = received == expected and len(list(message.iter_parts())) == len(expected)
                events.append({'received': [{'filename': p, 'hex': d.hex(), 'sha256': hashlib.sha256(d).hexdigest()}
                                            for p, d in received.items()], 'verified': ok})
                self.respond('<title>Upload verified</title>Exact filenames, paths and bytes verified.' if ok else
                             '<title>Upload mismatch</title>Upload did not match expected files.', 200 if ok else 422)
            else:
                self.respond('Unknown endpoint', 404)
            (args.evidence / 'events.json').write_text(json.dumps(events, indent=2))
    server = HTTPServer(('127.0.0.1', args.port), Handler)
    print(f'http://127.0.0.1:{server.server_port}/directory', flush=True)
    print(f'Choose folder: {args.evidence / "tree"}', flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()

if __name__ == '__main__':
    main()
