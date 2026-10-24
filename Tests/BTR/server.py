import http.server, json, re, threading, time, socket, sys
from pathlib import Path
DATA = bytes(range(256)) * (4 * 1024 * 1024 // 256)
LOG = []
LOCK = threading.Lock()
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        if self.path == '/stats':
            with LOCK: body = json.dumps(LOG).encode()
            self.send_response(200); self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body); return
        match = re.fullmatch(r'bytes=(\d+)-(\d+)', self.headers.get('Range',''))
        if not match: self.send_error(400); return
        start,end=map(int,match.groups())
        with LOCK: LOG.append({'path':self.path,'start':start,'end':end})
        if self.path == '/wait': time.sleep(10)
        if self.path == '/refused': self.send_error(403); return
        total=len(DATA)
        self.send_response(200 if self.path == '/full' else 206)
        self.send_header('Content-Range', f'bytes {start+1 if self.path=="/wrong" else start}-{end}/{total}')
        self.send_header('Content-Length',str(end-start+1)); self.end_headers()
        body=DATA[start:end+1]
        if self.path == '/corrupt': body=bytes([v ^ 255 for v in body])
        try:
            if self.path == '/resume' and start == 0 and end >= 131071:
                self.wfile.write(body[:65536]); self.wfile.flush()
                self.connection.shutdown(socket.SHUT_RDWR); self.connection.close(); return
            if self.path == '/slow' and end-start+1 > 32768:
                self.wfile.write(body[:65536]); self.wfile.flush(); time.sleep(2)
                self.wfile.write(body[65536:]); return
            if self.path == '/reorder': time.sleep(0.15 if start % 2 == 0 else 0.01)
            self.wfile.write(body)
        except (BrokenPipeError,ConnectionResetError,OSError): pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
