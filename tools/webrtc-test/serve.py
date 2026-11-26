"""Sert la page du banc d'essai et start.txt (python3 serve.py, port 8000)."""
import http.server
import socketserver

PORT = 8000
with socketserver.TCPServer(("", PORT), http.server.SimpleHTTPRequestHandler) as httpd:
    print(f"http://localhost:{PORT}/index.html")
    httpd.serve_forever()
