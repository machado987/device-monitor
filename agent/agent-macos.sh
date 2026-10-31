#!/bin/bash
# Device Monitor agent for macOS (Apple Silicon and Intel). No sudo needed.
# Usage: agent-macos.sh <hub-url> <token>   (or HUB/TOKEN in a "config" file next to this script)
# Written for the bash 3.2 and BSD tools that ship with macOS.
DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$DIR/config" ] && . "$DIR/config"
HUB="${1:-$HUB}"; TOKEN="${2:-$TOKEN}"; INTERVAL="${INTERVAL:-2}"
if [ -z "$HUB" ] || [ -z "$TOKEN" ]; then echo "usage: $0 <hub> <token>"; exit 1; fi
HUB="${HUB%/}"
export LC_ALL=C
export PATH="$PATH:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"   # launchd gives a minimal PATH

esc() { printf '%s' "$1" | tr -d '"\\' | tr -d '[:cntrl:]'; }   # strip chars that would break JSON
num() { case "$1" in ''|*[!0-9.-]*) echo null ;; *) echo "$1" ;; esac; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time' 2>/dev/null || date +%s; }

ID="$(ioreg -rd1 -c IOPlatformExpertDevice | awk -F'"' '/IOPlatformUUID/ { print $4; exit }')"
[ -z "$ID" ] && ID="$(hostname)"
HOST="$(scutil --get ComputerName 2>/dev/null || hostname -s)"
MODEL="$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Model Name/ { print $2; exit }')"
OS="macOS $(sw_vers -productVersion 2>/dev/null)"
[ -n "$MODEL" ] && OS="$OS Â· $MODEL"
CPU_NAME="$(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
THREADS="$(sysctl -n hw.logicalcpu 2>/dev/null)"
case "$MODEL" in *Book*) FORM=laptop ;; *) FORM=desktop ;; esac
MEM_TOTAL="$(sysctl -n hw.memsize)"
BOOT="$(sysctl -n kern.boottime | awk -F'[ ,]+' '{ for (i = 1; i <= NF; i++) if ($i == "sec") { print $(i + 2); exit } }')"
# Optional temperature sensors: `brew install smctemp` (Apple Silicon + Intel).
SMCTEMP="$(command -v smctemp 2>/dev/null)"

read_net() { netstat -ibn | awk '$1 ~ /^en/ && $3 ~ /^<Link#/ { rx += $7; tx += $10 } END { printf "%.0f %.0f\n", rx, tx }'; }
read_disk() {
  ioreg -c IOBlockStorageDriver -r -w 0 | awk '
    /"Statistics"/ {
      s = $0
      if (match(s, /"Bytes \(Read\)"=[0-9]+/))  { t = substr(s, RSTART, RLENGTH); sub(/.*=/, "", t); r += t }
      if (match(s, /"Bytes \(Write\)"=[0-9]+/)) { t = substr(s, RSTART, RLENGTH); sub(/.*=/, "", t); w += t }
    }
    END { printf "%.0f %.0f\n", r, w }'
}
cpu_usage() {   # two samples 1s apart; the second one is the real reading
  top -l 2 -n 0 -s 1 | awk '/^CPU usage/ { idle = $7 } END { sub(/%/, "", idle); if (idle == "") print "null"; else printf "%.1f", 100 - idle }'
}
memory_used() {   # like Activity Monitor's "Memory Used": app (active) + wired + compressed
  vm_stat | awk '
    /page size of/ { for (i = 1; i <= NF; i++) if ($i == "of") page = $(i + 1) }
    /^Pages active/ { a = $3 + 0 } /^Pages wired down/ { w = $4 + 0 } /occupied by compressor/ { c = $5 + 0 }
    END { if (!page) page = 4096; printf "%.0f", (a + w + c) * page }'
}
gpus_json() {
  local gtemp="null"
  [ -n "$SMCTEMP" ] && gtemp="$(num "$("$SMCTEMP" -g 2>/dev/null | head -1)")"
  ioreg -r -d 1 -w 0 -c IOAccelerator | awk -v fallback="$(esc "$CPU_NAME") GPU" -v gtemp="$gtemp" '
    function val(s, key,   t) { if (match(s, "\"" key "\"=[0-9]+")) { t = substr(s, RSTART, RLENGTH); sub(/.*=/, "", t); return t } return "" }
    function flush() {
      if (!has) return
      if (name == "") name = fallback
      printf "%s{\"name\":\"%s\",\"vendor\":\"apple\",\"usage\":%s,\"temp\":%s,\"memUsed\":%s,\"memTotal\":null}", (n++ ? "," : ""), name, (util == "" ? "null" : util), gtemp, (mem == "" ? "null" : mem)
      name = ""; util = ""; mem = ""; has = 0
    }
    /\+-o/ { flush(); next }
    /"model" = "/ { s = $0; sub(/.*"model" = "/, "", s); sub(/".*/, "", s); gsub(/[\\"]/, "", s); name = s }
    /"PerformanceStatistics"/ {
      util = val($0, "Device Utilization %"); if (util == "") util = val($0, "GPU Activity\\(%\\)")
      mem = val($0, "In use system memory"); has = 1
    }
    END { flush() }'
}
disks_json() {   # APFS: report the container (total - available), like Finder does
  df -k -l | awk 'NR > 1 {
      mount = $9; for (i = 10; i <= NF; i++) mount = mount " " $i
      if (mount == "/System/Volumes/Data") name = "Macintosh HD"
      else if (mount ~ /^\/Volumes\//) { name = mount; sub(/^\/Volumes\//, "", name) }
      else next
      gsub(/["\\]/, "", name)
      printf "%s{\"name\":\"%s\",\"total\":%.0f,\"used\":%.0f}", (n++ ? "," : ""), name, $2 * 1024, ($2 - $4) * 1024
    }'
}

# AI models loaded (Ollama, LM Studio, ComfyUI, vLLM, llama.cpp...), checked every 5th report.
# Python runs isolated (-I): nothing is imported from the working directory or PYTHON* variables.
# /usr/bin/python3 is only a stub that offers to install developer tools until they are installed.
PY3="$(command -v python3)"; [ "$PY3" = /usr/bin/python3 ] && ! xcode-select -p >/dev/null 2>&1 && PY3=""
read -r -d '' AI_PY <<'PY'
import json, os, re, subprocess, urllib.request
def get(url):
    try:
        with urllib.request.urlopen(url, timeout=1.5) as r: return json.load(r)
    except Exception: return None
def run(args):
    try: return subprocess.run(args, capture_output=True, text=True, timeout=6).stdout
    except Exception: return ''
def cmdline(pid):
    try:
        with open('/proc/%d/cmdline' % pid, 'rb') as f: return [a.decode('utf-8', 'replace') for a in f.read().split(b'\0') if a]
    except Exception: return []
def arg(argv, *names):
    for i, a in enumerate(argv):
        for n in names:
            if a == n and i + 1 < len(argv): return argv[i + 1]
            if a.startswith(n + '='): return a.split('=', 1)[1]
    return None
def comfy(port, home, mem):
    # ComfyUI doesn't list what it holds in memory; use the loaders of the last workflow it ran.
    models, root = [], os.path.join(home, 'models') if home else ''
    for item in (get('http://127.0.0.1:%s/history?max_items=1' % port) or {}).values():
        prompt = item.get('prompt') or []
        for node in (prompt[2] if len(prompt) > 2 and isinstance(prompt[2], dict) else {}).values():
            if 'Loader' not in str(node.get('class_type', '')): continue
            for k, v in (node.get('inputs') or {}).items():
                if k.endswith('_name') and isinstance(v, str) and v not in [m['name'] for m in models]:
                    size = None
                    for sub in (os.listdir(root) if root and os.path.isdir(root) else []):
                        f = os.path.join(root, sub, v)
                        if os.path.isfile(f): size = os.path.getsize(f); break
                    models.append({'name': v, 'size': size, 'kind': k[:-5]})
    return {'app': 'ComfyUI', 'mem': mem, 'models': models}
gpu = {}
for line in run(['nvidia-smi', '--query-compute-apps=pid,used_memory', '--format=csv,noheader,nounits']).splitlines():
    p = [x.strip() for x in line.split(',')]
    if len(p) == 2 and p[0].isdigit() and re.match(r'^\d+(\.\d+)?$', p[1]): gpu[int(p[0])] = gpu.get(int(p[0]), 0) + int(float(p[1]) * 1048576)
groups = []
j = get('http://127.0.0.1:11434/api/ps')
if j and j.get('models'):
    groups.append({'app': 'Ollama', 'mem': sum(m.get('size_vram') or 0 for m in j['models']) or None,
                   'models': [{'name': m.get('name'), 'size': m.get('size')} for m in j['models']]})
lms = os.path.expanduser('~/.lmstudio/bin/lms')
if os.path.exists(lms) and run(['pgrep', '-f', 'llmster|LM Studio|lmstudio']).strip():
    try: arr = json.loads(run([lms, 'ps', '--json']) or '[]')
    except Exception: arr = []
    if arr:
        mem = sum(m for pid, m in gpu.items() if re.search('lmstudio|llmster', ' '.join(cmdline(pid)).lower())) or None
        groups.append({'app': 'LM Studio', 'mem': mem,
                       'models': [{'name': m.get('displayName') or m.get('identifier') or m.get('modelKey'), 'size': m.get('sizeBytes')} for m in arr]})
for pid, used in sorted(gpu.items(), key=lambda x: -x[1]):
    argv = cmdline(pid); c = ' '.join(argv).lower()
    if not argv or used < 256 * 1048576 or re.search('ollama|lmstudio|llmster', c): continue
    try: home = os.readlink('/proc/%d/cwd' % pid)
    except Exception: home = ''
    if 'comfy' in c or 'comfy' in home.lower():
        groups.append(comfy(arg(argv, '--port') or '8188', home, used)); continue
    app = 'vLLM' if 'vllm' in c else 'SGLang' if 'sglang' in c else 'llama.cpp' if 'llama-server' in c else os.path.basename(argv[0])
    m = arg(argv, '--model', '-m', '--model-path')
    if not m and 'serve' in argv:
        i = argv.index('serve'); m = argv[i + 1] if i + 1 < len(argv) and not argv[i + 1].startswith('-') else None
    if m and os.path.exists(m): m = os.path.basename(m.rstrip('/'))
    groups.append({'app': app, 'mem': used, 'models': [{'name': m, 'size': None}] if m else []})
if not any(g['app'] == 'ComfyUI' for g in groups) and (get('http://127.0.0.1:8188/system_stats') or {}).get('system', {}).get('comfyui_version'):
    g = comfy('8188', '', None)
    if g['models']: groups.append(g)
print(json.dumps(groups[:8], separators=(',', ':')))
PY
AI_N=0
PREV_NET="$(read_net)"; PREV_DISK="$(read_disk)"; PREV_T="$(now)"
# Python is optional: older systems keep metrics but report inventory unavailable.
DM_SUPPORT=$(cat <<'DM_PY'
import json, os, sys, time, hmac, hashlib, subprocess, pathlib, re
def collect():
    peripherals, macs = [], []
    if sys.platform == 'darwin':
        r = subprocess.run(['/usr/sbin/system_profiler', 'SPUSBDataType', '-json'], capture_output=True, text=True, timeout=10)
        if r.returncode: raise RuntimeError('USB inventory unavailable')
        def visit(items):
            for x in items:
                if x.get('vendor_id') or x.get('product_id'):
                    peripherals.append(dict(name=x.get('_name', 'USB device'), kind='USB', vendor=x.get('manufacturer')))
                visit(x.get('_items', []))
        visit(json.loads(r.stdout).get('SPUSBDataType', []))
        r = subprocess.run(['/sbin/ifconfig'], capture_output=True, text=True, timeout=5)
        macs = re.findall(r'ether\s+([0-9a-f:]{17})', r.stdout)
    else:
        for p in sorted(pathlib.Path('/sys/bus/usb/devices').glob('*')):
            try:
                name=(p/'product').read_text().strip()
                vendor=(p/'manufacturer').read_text().strip() if (p/'manufacturer').exists() else None
                peripherals.append(dict(name=name, kind='USB', vendor=vendor))
            except OSError: pass
        for p in sorted(pathlib.Path('/sys/class/input').glob('event*/device/name')):
            try:
                name=p.read_text().strip()
                if name not in [x['name'] for x in peripherals]: peripherals.append(dict(name=name, kind='Input'))
            except OSError: pass
        for p in pathlib.Path('/sys/class/net').glob('*/address'):
            if not (p.parent/'device').exists(): continue
            macs.append(p.read_text().strip())
    return dict(peripherals=peripherals[:128], macs=macs[:8], actions=['shutdown'] if os.getenv('DM_ALLOW_SHUTDOWN') == '1' else [])
def execute(reply):
    if os.getenv('DM_ALLOW_SHUTDOWN') != '1': return None
    device=os.environ['DM_DEVICE_ID']
    for c in reply.get('commands', [])[:8]:
        cid, action, expiry = c.get('id'), c.get('action'), c.get('expires')
        if not isinstance(cid,str) or not re.fullmatch('[a-f0-9]{12}',cid) or action != 'shutdown': continue
        if not isinstance(expiry,int) or not 0 < expiry - time.time()*1000 <= 60000: continue
        msg=f'device-monitor-cmd-v2:{device}:{cid}:{action}:{expiry}'
        sig=hmac.new(os.environ['TOKEN'].encode(),msg.encode(),hashlib.sha256).hexdigest()
        if not isinstance(c.get('sig'),str) or not hmac.compare_digest(sig,c['sig']): continue
        # Persist before executing; duplicate replies remain harmless across restarts.
        folder=pathlib.Path.home()/'.device-monitor'
        folder.mkdir(mode=0o700,exist_ok=True)
        ledger=folder/'power-seen.json'
        try: seen=json.loads(ledger.read_text()) if ledger.exists() else {}
        except (ValueError,OSError): return dict(id=cid,ok=False,message='Cannot read replay ledger')
        seen={k:v for k,v in seen.items() if isinstance(v,int) and v > time.time()*1000}
        if cid in seen: continue
        seen[cid]=expiry
        try:
            fd=os.open(str(ledger),os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
            with os.fdopen(fd,'w') as f: json.dump(seen,f); f.flush(); os.fsync(f.fileno())
            argv=['/sbin/shutdown','-h','+1'] if sys.platform == 'darwin' else ['/usr/bin/systemctl','--no-ask-password','poweroff']
            r=subprocess.run(argv,capture_output=True,timeout=10)
            return dict(id=cid,ok=r.returncode==0,message='OS accepted shutdown request' if r.returncode==0 else 'OS denied shutdown; check local permissions')
        except (OSError,subprocess.TimeoutExpired): return dict(id=cid,ok=False,message='Shutdown could not be started')
    return None
try:
    if sys.argv[1]=='inventory': print(json.dumps(collect(),separators=(',',':'))[1:-1])
    else: print(json.dumps(execute(json.load(sys.stdin)),separators=(',',':')))
except Exception:
    print('"peripherals":null,"macs":[],"actions":[]' if sys.argv[1]=='inventory' else 'null')
DM_PY
)
export TOKEN DM_ALLOW_SHUTDOWN
export DM_DEVICE_ID="$ID"
EXTRA='"peripherals":null,"macs":[],"actions":[]'; RESULT=null; INVENTORY_AT=0
while true; do
  if [ -n "$PY3" ] && [ $((AI_N++ % 5)) -eq 0 ]; then AI="$("$PY3" -I -c "$AI_PY" 2>/dev/null)"; fi
  # Exit with the desktop app that started us (if any).
  if [ -n "$PARENT_PID" ] && ! kill -0 "$PARENT_PID" 2>/dev/null; then exit 0; fi
  CPU="$(cpu_usage)"   # takes ~1s
  T="$(now)"; CUR_NET="$(read_net)"; CUR_DISK="$(read_disk)"
  set -- $PREV_NET $CUR_NET $PREV_DISK $CUR_DISK
  RATES="$(awk -v s="$(awk -v a="$PREV_T" -v b="$T" 'BEGIN { d = b - a; print (d > 0 ? d : 1) }')" \
    -v a="$1" -v b="$3" -v c="$2" -v d="$4" -v e="$5" -v f="$7" -v g="$6" -v h="$8" \
    'function rate(x, y) { return (y - x) / s < 0 ? 0 : (y - x) / s }
     BEGIN { printf "\"net\":{\"rx\":%.0f,\"tx\":%.0f},\"diskIO\":{\"read\":%.0f,\"write\":%.0f}", rate(a, b), rate(c, d), rate(e, f), rate(g, h) }')"
  PREV_NET="$CUR_NET"; PREV_DISK="$CUR_DISK"; PREV_T="$T"

  CPU_TEMP="null"
  [ -n "$SMCTEMP" ] && CPU_TEMP="$(num "$("$SMCTEMP" -c 2>/dev/null | head -1)")"
  UPTIME=$(( $(date +%s) - ${BOOT:-$(date +%s)} ))

  if [ -n "$PY3" ] && [ $(( $(date +%s) - INVENTORY_AT )) -ge 30 ]; then
    EXTRA="$("$PY3" -I -c "$DM_SUPPORT" inventory 2>/dev/null)"
    [ -n "$EXTRA" ] || EXTRA='"peripherals":null,"macs":[],"actions":[]'
    INVENTORY_AT=$(date +%s)
  fi
  BODY="{$EXTRA,\"actionResult\":$RESULT,\"id\":\"$(esc "$ID")\",\"token\":\"$TOKEN\",\"hostname\":\"$(esc "$HOST")\",\"platform\":\"macos\",\"appVersion\":\"$(esc "${DM_APP_VERSION:-}")\",\"os\":\"$(esc "$OS")\",\"formFactor\":\"$FORM\",\"uptime\":$UPTIME,\"cpu\":{\"name\":\"$(esc "$CPU_NAME")\",\"threads\":$(num "$THREADS"),\"clockMHz\":null,\"temp\":$CPU_TEMP,\"usage\":$CPU,\"cores\":[]},\"memory\":{\"total\":$MEM_TOTAL,\"used\":$(memory_used)},\"gpus\":[$(gpus_json)],\"disks\":[$(disks_json)],$RATES,\"ai\":${AI:-null}}"
  REPLY="$(curl -fsS -m 5 -X POST -H 'Content-Type: application/json' --data-binary "$BODY" "$HUB/api/report" 2>/dev/null)"
  if [ -n "$PY3" ] && [ -n "$REPLY" ]; then RESULT="$(printf '%s' "$REPLY" | "$PY3" -I -c "$DM_SUPPORT" reply 2>/dev/null)"; RESULT="${RESULT:-null}"; fi
  sleep $(( INTERVAL > 1 ? INTERVAL - 1 : 1 ))
done
