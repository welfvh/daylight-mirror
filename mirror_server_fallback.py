#!/usr/bin/env python3
"""
Daylight Mirror — streams Mac display to Daylight DC-1 over USB.
Instrumented with latency analytics on /stats endpoint.
"""
import subprocess
import threading
import time
import json
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
from collections import deque

latest_frame = b''
lock = threading.Lock()
DISPLAY_NUM = '1'

# Analytics
capture_times = deque(maxlen=100)   # ms per screencapture call
read_times = deque(maxlen=100)      # ms to read file
frame_sizes = deque(maxlen=100)     # bytes
serve_times = deque(maxlen=100)     # ms to serve a /frame request
frame_count = 0
capture_count = 0
start_time = time.time()

def capture():
    global latest_frame, capture_count
    path = '/tmp/_mirror_frame.jpg'
    while True:
        t0 = time.monotonic()
        try:
            subprocess.run(
                ['screencapture', '-C', '-x', '-D', DISPLAY_NUM, '-t', 'jpg', path],
                timeout=2, capture_output=True
            )
            t1 = time.monotonic()
            capture_ms = (t1 - t0) * 1000

            with open(path, 'rb') as f:
                data = f.read()
            t2 = time.monotonic()
            read_ms = (t2 - t1) * 1000

            if data:
                with lock:
                    latest_frame = data
                capture_times.append(capture_ms)
                read_times.append(read_ms)
                frame_sizes.append(len(data))
                capture_count += 1
        except Exception:
            pass
        # No sleep — capture as fast as possible


class ThreadedHTTP(ThreadingMixIn, HTTPServer):
    daemon_threads = True


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        global frame_count
        if self.path == '/':
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.end_headers()
            self.wfile.write(b'''<!DOCTYPE html><html>
<head><meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">
<style>*{margin:0;padding:0;overflow:hidden}
body{background:#000;width:100vw;height:100vh;touch-action:none}
img{width:100vw;height:100vh;object-fit:fill;display:block}</style></head>
<body><img id="v"><script>
const img=document.getElementById('v');
let prev='';
async function run(){
  while(true){
    try{
      const r=await fetch('/frame',{cache:'no-store'});
      const b=await r.blob();
      const u=URL.createObjectURL(b);
      img.src=u;
      if(prev)URL.revokeObjectURL(prev);
      prev=u;
    }catch(e){}
    await new Promise(r=>setTimeout(r,50));
  }
}
run();
document.body.addEventListener('click',()=>{
  document.documentElement.requestFullscreen().catch(()=>{});
});
</script></body></html>''')
        elif self.path == '/frame':
            t0 = time.monotonic()
            with lock:
                f = latest_frame
            if f:
                self.send_response(200)
                self.send_header('Content-Type', 'image/jpeg')
                self.send_header('Content-Length', str(len(f)))
                self.send_header('Cache-Control', 'no-store')
                self.end_headers()
                self.wfile.write(f)
                serve_times.append((time.monotonic() - t0) * 1000)
                frame_count += 1
            else:
                self.send_response(503)
                self.end_headers()
        elif self.path == '/stats':
            uptime = time.time() - start_time
            def avg(d): return sum(d) / len(d) if d else 0
            def p95(d):
                if not d: return 0
                s = sorted(d)
                return s[int(len(s) * 0.95)]
            stats = {
                'uptime_s': round(uptime, 1),
                'capture': {
                    'count': capture_count,
                    'fps': round(capture_count / uptime, 1) if uptime > 0 else 0,
                    'avg_ms': round(avg(capture_times), 1),
                    'p95_ms': round(p95(capture_times), 1),
                },
                'read': {
                    'avg_ms': round(avg(read_times), 1),
                },
                'frame_size': {
                    'avg_kb': round(avg(frame_sizes) / 1024, 1),
                },
                'serve': {
                    'count': frame_count,
                    'fps': round(frame_count / uptime, 1) if uptime > 0 else 0,
                    'avg_ms': round(avg(serve_times), 1),
                    'p95_ms': round(p95(serve_times), 1),
                },
                'pipeline_total_avg_ms': round(avg(capture_times) + avg(read_times), 1),
            }
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(stats, indent=2).encode())
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *args):
        pass


if __name__ == '__main__':
    t = threading.Thread(target=capture, daemon=True)
    t.start()
    print("Daylight Mirror — instrumented, /stats for analytics", flush=True)
    ThreadedHTTP(('127.0.0.1', 8888), Handler).serve_forever()
