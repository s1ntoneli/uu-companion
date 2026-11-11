#!/bin/zsh
set -eu
CONFIG="$HOME/Library/Application Support/uu伴侣/config.json"
/usr/bin/python3 - "$CONFIG" <<'PY'
import sys, pathlib, json, os
p=pathlib.Path(sys.argv[1])
if not p.is_file(): raise SystemExit("Missing config.json")
cfg=json.loads(p.read_text())
if cfg.get("role")!="receiver": raise SystemExit("Not a receiver")
cfg["virtualDeviceName"]="uu伴侣 Mic"
p.write_text(json.dumps(cfg,ensure_ascii=False))
os.chmod(p,0o600)
print("Restored Loopback fallback. Quit and reopen uu伴侣 to apply.")
PY
