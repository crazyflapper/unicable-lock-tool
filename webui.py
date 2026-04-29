#!/usr/bin/env python3
import json
import os
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.environ.get("LOCK_JSON", os.path.join(BASE_DIR, "lock.json"))
BINARY_PATH = os.environ.get("LOCK_TOOL_BIN", os.path.join(BASE_DIR, "lock_tool_v2_6"))
HOST = os.environ.get("LOCK_WEBUI_HOST", "127.0.0.1")
PORT = int(os.environ.get("LOCK_WEBUI_PORT", "8088"))
RUN_LOCK = threading.Lock()


def run_json(cmd):
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False)
    raw = proc.stdout.strip() or proc.stderr.strip()
    if not raw:
        raise RuntimeError("brak odpowiedzi z backendu")
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        raise RuntimeError(f"niepoprawny JSON z backendu: {e}: {raw[:400]}")
    return proc.returncode, data


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, payload, content_type="application/json; charset=utf-8"):
        if isinstance(payload, (dict, list)):
            body = json.dumps(payload, ensure_ascii=False, indent=2)
        else:
            body = payload
        raw = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        if self.path == "/":
            self._send(200, self._html(), "text/html; charset=utf-8")
            return
        if self.path == "/api/adapters":
            rc, data = run_json([BINARY_PATH, "--list-adapters", "--json"])
            self._send(200 if rc == 0 else 500, data)
            return
        if self.path == "/api/ubs":
            rc, data = run_json([BINARY_PATH, "--config", CONFIG_PATH, "--list-ubs", "--json"])
            self._send(200 if rc == 0 else 500, data)
            return
        self._send(404, {"ok": False, "error": "NOT_FOUND"})

    def do_POST(self):
        if self.path != "/api/test":
            self._send(404, {"ok": False, "error": "NOT_FOUND"})
            return
        length = int(self.headers.get("Content-Length", "0"))
        try:
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
        except Exception:
            self._send(400, {"ok": False, "error": "INVALID_JSON"})
            return

        probe_raw = payload.get("probe")
        adapter_raw = payload.get("adapter")
        timeout_raw = payload.get("timeout")

        if probe_raw is None or probe_raw == "":
            probe = 0
        else:
            probe = int(probe_raw)

        if adapter_raw is None or adapter_raw == "":
            adapter = -1
        else:
            adapter = int(adapter_raw)

        if timeout_raw is None or timeout_raw == "":
            timeout = 20
        else:
            timeout = int(timeout_raw)
        if probe < 1 or probe > 32:
            self._send(400, {"ok": False, "error": "INVALID_PROBE", "message": "probe musi być 1..32"})
            return
        if adapter < 0:
            self._send(400, {"ok": False, "error": "INVALID_ADAPTER", "message": "adapter musi być liczbą nieujemną; lista dostępnych adapterów pochodzi z /api/adapters"})
            return
        if timeout < 5 or timeout > 120:
            self._send(400, {"ok": False, "error": "INVALID_TIMEOUT", "message": "timeout musi być 5..120"})
            return
        if not RUN_LOCK.acquire(blocking=False):
            self._send(409, {"ok": False, "error": "TEST_IN_PROGRESS", "message": "inny test już trwa"})
            return
        try:
            rc, data = run_json([
                BINARY_PATH, "--config", CONFIG_PATH,
                "--adapter", str(adapter),
                "--probe", str(probe),
                "--timeout", str(timeout),
                "--json"
            ])
            self._send(200 if rc in (0, 1) else 500, data)
        finally:
            RUN_LOCK.release()

    def log_message(self, fmt, *args):
        return

    def _html(self):
        return r'''<!doctype html>
<html lang="pl">
<head>
<meta charset="utf-8">
<title>LOCK TOOL v2.6</title>
<style>
body{font-family:Arial,sans-serif;margin:24px;background:#111;color:#eee}
.card{max-width:980px;margin:auto;background:#1b1b1b;border:1px solid #333;border-radius:14px;padding:20px}
.row{display:grid;grid-template-columns:220px 1fr;gap:12px;align-items:center;margin:10px 0}
input,select,button{padding:10px;border-radius:10px;border:1px solid #555;background:#222;color:#eee}
button{cursor:pointer}.ok{color:#71d17b;font-weight:bold}.bad{color:#ff7b7b;font-weight:bold}
pre{background:#0c0c0c;border:1px solid #333;padding:14px;border-radius:12px;white-space:pre-wrap}
.small{color:#bbb;font-size:14px}.box{background:#141414;border:1px solid #333;border-radius:12px;padding:14px;margin-top:18px}
</style>
</head>
<body>
<div class="card">
<h1>LOCK TOOL v2.6</h1>
<p class="small">Model diagnostyczny: 1 test = 1 wynik. Adaptery są wykrywane dynamicznie przez backend i są 0-based zgodnie z /dev/dvb/adapterN. UB/SLOT są 1-based (1..32).</p>
<div class="row"><label for="adapter">Adapter</label><select id="adapter"></select></div>
<div class="row"><label for="probe">Kanał UB</label><select id="probe"></select></div>
<div class="row"><label>UB/SLOT</label><div id="slot_view"></div></div>
<div class="row"><label>Częstotliwość UB</label><div id="freq_view"></div></div>
<div class="row"><label>Standard</label><div id="std_view"></div></div>
<div class="row"><label for="timeout">Timeout [s]</label><input id="timeout" type="number" min="5" max="120" value="20"></div>
<div class="row"><label></label><button id="run_btn" onclick="runTest()">CHECK LOCK</button></div>
<div class="box"><div>Wynik: <span id="status">brak</span></div><div class="small" id="request_echo">Gotowe do testu.</div></div>
<pre id="output">{}</pre>
</div>
<script>
let ubMap = {};
function setStatus(text, ok){ const e=document.getElementById('status'); e.textContent=text; e.className=ok==='LOCK'?'ok':(ok?'bad':''); }
function refreshUbMeta(){ const probe=parseInt(document.getElementById('probe').value||'0',10); const ub=ubMap[probe]; if(!ub)return; document.getElementById('slot_view').textContent=ub.slot; document.getElementById('freq_view').textContent=(ub.freq_khz/1000)+' MHz ('+ub.freq_khz+' kHz)'; document.getElementById('std_view').textContent=ub.standard; document.getElementById('request_echo').textContent='Wybrane: adapter '+document.getElementById('adapter').value+', probe CH'+ub.id+', slot '+ub.slot+', '+ub.freq_khz+' kHz'; document.getElementById('output').textContent='{}'; setStatus('brak', null); }
async function loadData(){
  const a=await fetch('/api/adapters'); const ad=await a.json(); const as=document.getElementById('adapter'); as.innerHTML='';
  (ad.adapters||[]).forEach(x=>{ const o=document.createElement('option'); o.value=x.adapter; o.textContent='Adapter '+x.adapter; as.appendChild(o); });
  const u=await fetch('/api/ubs'); const ud=await u.json(); const us=document.getElementById('probe'); us.innerHTML=''; ubMap={};
  (ud.ub_channels||[]).forEach(x=>{ ubMap[x.id]=x; const o=document.createElement('option'); o.value=x.id; o.textContent='CH'+x.id+' — '+(x.freq_khz/1000)+' MHz — '+x.standard; us.appendChild(o); });
  if(!(ad.adapters||[]).length){ setStatus('ERROR', true); document.getElementById('request_echo').textContent='Brak dostępnych adapterów DVB. Sprawdź sterownik i /dev/dvb/.'; document.getElementById('run_btn').disabled=true; }
  refreshUbMeta();
}
async function runTest(){
  const adapter=parseInt(document.getElementById('adapter').value,10); const probe=parseInt(document.getElementById('probe').value,10); const timeout=parseInt(document.getElementById('timeout').value,10);
  const ub=ubMap[probe]; document.getElementById('run_btn').disabled=true; setStatus('test trwa...', null);
  document.getElementById('request_echo').textContent='Request: adapter='+adapter+', probe=CH'+probe+', slot='+ub.slot+', ub_freq_khz='+ub.freq_khz+', timeout='+timeout;
  const res=await fetch('/api/test',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({adapter,probe,timeout})});
  const data=await res.json(); setStatus(data.result||'ERROR', data.result); document.getElementById('output').textContent=JSON.stringify(data,null,2); document.getElementById('run_btn').disabled=false;
}
document.addEventListener('DOMContentLoaded', async()=>{ await loadData(); document.getElementById('adapter').addEventListener('change', refreshUbMeta); document.getElementById('probe').addEventListener('change', refreshUbMeta); });
</script>
</body>
</html>'''


def main():
    print(f"[INFO] WebUI: http://{HOST}:{PORT}/")
    print(f"[INFO] LOCK_JSON={CONFIG_PATH}")
    print(f"[INFO] LOCK_TOOL_BIN={BINARY_PATH}")
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
