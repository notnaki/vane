#!/usr/bin/env python3
"""Actual production download with hostile loopback responses; no distribution trust claim."""
import gzip
import http.server
import pathlib
import socket
import subprocess
import tempfile
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
forbidden_requests = []


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        try:
            if self.path == '/forbidden':
                forbidden_requests.append(self.path)
            if self.path in ['/redirect-good', '/redirect-bad', '/redirect-loop']:
                self.send_response(302)
                self.send_header('Location', {'/redirect-good': '/complete', '/redirect-bad': '/forbidden',
                                              '/redirect-loop': '/redirect-loop'}[self.path])
                self.send_header('Content-Length', '0')
                self.end_headers()
                return
            body = b'complete archive fixture'
            self.send_response(503 if self.path == '/http-error' else 200)
            if self.path == '/unknown-large':
                self.end_headers()
                self.wfile.write(b'x' * 4096)
            elif self.path == '/chunked-large':
                self.send_header('Transfer-Encoding', 'chunked')
                self.end_headers()
                for _ in range(8):
                    self.wfile.write(b'200\r\n' + b'x' * 512 + b'\r\n')
                    self.wfile.flush()
                self.wfile.write(b'0\r\n\r\n')
            elif self.path == '/encoded':
                body = gzip.compress(b'x' * 4096)
                self.send_header('Content-Encoding', 'gzip')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            elif self.path in ['/cancel', '/slow']:
                self.end_headers()
                for _ in range(100):
                    self.wfile.write(b'x')
                    self.wfile.flush()
                    time.sleep(.02)
            else:
                if self.path == '/exact-cap':
                    body = b'x' * 1024
                if self.path == '/advertised-large':
                    body = b'x' * 100000
                size = 100000 if self.path in ['/advertised-large', '/truncated', '/interrupted'] else len(body)
                # A truncated small advertised body must fail independently of the cap.
                if self.path in ['/truncated', '/interrupted']:
                    size = 100
                self.send_header('Content-Length', str(size))
                self.end_headers()
                if self.path == '/advertised-large':
                    self.wfile.flush()
                    time.sleep(.1)
                self.wfile.write(body if self.path in ['/complete', '/exact-cap', '/advertised-large'] else body[:4])
                self.wfile.flush()
                if self.path == '/interrupted':
                    self.connection.shutdown(socket.SHUT_RDWR)
            self.close_connection = True
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass


with tempfile.TemporaryDirectory(prefix='vane-updater-transport-') as work:
    executable = pathlib.Path(work) / 'check'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', str(ROOT / 'Sources/Vane/UpdateDownload.swift'),
                    str(ROOT / 'Tests/UpdaterTransport/main.swift'), '-o', str(executable)], check=True)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        subprocess.run([str(executable), f'http://127.0.0.1:{server.server_port}', work], check=True, timeout=60)
        if forbidden_requests:
            raise SystemExit('FAIL: rejected redirect was fetched')
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
