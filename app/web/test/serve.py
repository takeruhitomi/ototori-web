"""Local static server for the web parity test (not deployed).

Serves the repository root with cross-origin isolation headers (COOP/COEP,
needed for ONNX Runtime threads) plus CORS/CORP, and accepts
POST /save?path=<relative path> to store a result under the output folder.

  python apps/choir_mobile/web/test/serve.py [--port 8765] [--out work/web-parity/out]

Then open http://localhost:8765/apps/choir_mobile/web/test/parity.html?song=tsubaki
"""
from __future__ import annotations

import argparse
import functools
import http.server
from pathlib import Path
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parents[4]


class Handler(http.server.SimpleHTTPRequestHandler):
    out_dir: Path = ROOT / 'work' / 'web-parity' / 'out'

    extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map,
                      '.mjs': 'text/javascript', '.js': 'text/javascript', '.wasm': 'application/wasm',
                      '.json': 'application/json', '.onnx': 'application/octet-stream'}

    def end_headers(self):
        self.send_header('Cross-Origin-Opener-Policy', 'same-origin')
        self.send_header('Cross-Origin-Embedder-Policy', 'require-corp')
        self.send_header('Cross-Origin-Resource-Policy', 'cross-origin')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()

    def do_POST(self):
        url = urlparse(self.path)
        rel = parse_qs(url.query).get('path', [''])[0]
        target = (self.out_dir / rel).resolve()
        if url.path != '/save' or not rel or self.out_dir.resolve() not in target.parents:
            self.send_error(400, 'bad save path')
            return
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(body)
        self.send_response(204)
        self.end_headers()

    def log_message(self, format, *args):
        if 'POST' in format % args or ' 404 ' in format % args:
            super().log_message(format, *args)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=8765)
    parser.add_argument('--out', type=Path, default=ROOT / 'work' / 'web-parity' / 'out')
    args = parser.parse_args()
    Handler.out_dir = args.out.resolve()
    server = http.server.ThreadingHTTPServer(('127.0.0.1', args.port), functools.partial(Handler, directory=str(ROOT)))
    print(f'serving {ROOT} on http://localhost:{args.port}/ (results -> {Handler.out_dir})', flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()
