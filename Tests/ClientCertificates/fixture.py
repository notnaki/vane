#!/usr/bin/env python3
"""Local mTLS regression. Generated keys stay in a disposable directory only."""
import http.server
import pathlib
import ssl
import subprocess
import sys
import tempfile
import threading

with tempfile.TemporaryDirectory(prefix="vane-client-certificates-") as directory:
    root = pathlib.Path(directory)

    project = pathlib.Path(__file__).resolve().parents[2]
    probe = root / "probe"
    subprocess.run(["/usr/bin/xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
                    str(project / "Sources/Vane/ClientCertificates.swift"),
                    str(project / "Tests/ClientCertificates/main.swift"), "-o", str(probe)], check=True)

    def openssl(*args):
        result = subprocess.run(["/usr/bin/openssl", *args], cwd=root, capture_output=True)
        if result.returncode:
            raise RuntimeError(result.stderr.decode())

    openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-sha256",
            "-subj", "/CN=Vane fixture root", "-keyout", "root.key", "-out", "root.pem",
            "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "subjectKeyIdentifier=hash")
    for name, subject, issuer, extensions in [
        ("intermediate", "Vane fixture root" if "--rollover" in sys.argv else "Vane fixture intermediate", "root",
         "basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid:always"),
        ("client", "Vane fixture client", "intermediate",
         "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid:always"),
        ("server", "localhost", "root",
         "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n"
         "extendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost"),
    ]:
        (root / f"{name}.ext").write_text(extensions + "\n")
        openssl("req", "-new", "-newkey", "rsa:2048", "-nodes", "-subj", f"/CN={subject}",
                "-keyout", f"{name}.key", "-out", f"{name}.csr")
        openssl("x509", "-req", "-in", f"{name}.csr", "-CA", f"{issuer}.pem",
                "-CAkey", f"{issuer}.key", "-CAcreateserial", "-days", "1", "-sha256",
                "-extfile", f"{name}.ext", "-out", f"{name}.pem")
    (root / "chain.pem").write_bytes((root / "intermediate.pem").read_bytes() + (root / "root.pem").read_bytes())
    openssl("pkcs12", "-export", "-inkey", "client.key", "-in", "client.pem",
            "-certfile", "chain.pem", "-out", "identity.p12", "-passout", "pass:fixture")
    openssl("x509", "-in", "root.pem", "-outform", "der", "-out", "root.der")

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            authenticated = bool(self.connection.getpeercert())
            self.send_response(200 if authenticated else 403)
            self.end_headers()
            self.wfile.write(b"mTLS fixture authenticated" if authenticated else b"missing identity")

        def log_message(self, *args):
            pass

    server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(root / "server.pem", root / "server.key")
    context.load_verify_locations(root / "root.pem")
    context.verify_mode = ssl.CERT_REQUIRED
    server.socket = context.wrap_socket(server.socket, server_side=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        result = subprocess.run([str(probe), str(root), str(server.server_port), *sys.argv[1:]], timeout=30)
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
    sys.exit(result.returncode)
