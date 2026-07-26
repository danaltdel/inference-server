#!/usr/bin/env python3
"""Static file server for web/ with caching disabled, so a pushed page update
shows up on plain refresh. Stdlib only; run by launchd via run-web.sh.

Usage: serve.py [port] [directory]
"""
import os
import sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer


class Handler(SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    if len(sys.argv) > 2:
        os.chdir(sys.argv[2])
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
