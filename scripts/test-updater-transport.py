#!/usr/bin/env python3
"""Actual URLSession and controlled loopback failures; no distribution trust claim."""
import http.server
import pathlib
import socket
import subprocess
import tempfile
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        try:
            if self.path == '/http-error':
                self.send_response(503)
                self.send_header('Content-Length', '0')
                self.end_headers()
                return
            body = b'complete archive fixture'
            self.send_response(200)
            self.send_header('Content-Length', str(len(body) if self.path == '/complete' else 100000))
            self.end_headers()
            if self.path == '/cancel':
                for _ in range(100):
                    self.wfile.write(b'x' * 100)
                    self.wfile.flush()
                    time.sleep(.02)
            else:
                self.wfile.write(body if self.path == '/complete' else body[:4])
                self.wfile.flush()
                if self.path == '/interrupted':
                    self.connection.shutdown(socket.SHUT_RDWR)
                self.close_connection = True
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass


with tempfile.TemporaryDirectory(prefix='vane-updater-transport-') as work:
    executable = pathlib.Path(work) / 'check'
    subprocess.run(['xcrun', 'swiftc', str(ROOT / 'Tests/UpdaterTransport/main.swift'), '-o', str(executable)], check=True)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        subprocess.run([str(executable), f'http://127.0.0.1:{server.server_port}'], check=True, timeout=60)
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
