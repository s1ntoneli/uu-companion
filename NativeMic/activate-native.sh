#!/bin/zsh
set -eu
APPDATA="$HOME/Library/Application Support/uu伴侣"
CONFIG="$APPDATA/config.json"
DRIVER="/Library/Audio/Plug-Ins/HAL/UUMicNative.driver"
if [[ ! -f "$DRIVER/Contents/MacOS/UUMicNative" ]]; then
  echo "Native Mic driver not installed. Install UUMicNative-0.1.0.pkg first."
  exit 1
fi
if ! /usr/sbin/system_profiler SPAudioDataType 2>/dev/null | /usr/bin/grep -Fq 'uu伴侣 Native Mic:'; then
  echo "Native Mic is not visible to Core Audio. Please check driver installation."
  exit 1
fi
/usr/bin/python3 - "$CONFIG" <<'PY'
import sys, pathlib, shutil, datetime, os, json
p=pathlib.Path(sys.argv[1])
if not p.is_file(): raise SystemExit("Missing uu伴侣 config.json")
cfg=json.loads(p.read_text())
if cfg.get("role")!="receiver": raise SystemExit("Only a receiver Mac can activate a virtual mic")
backup=p.with_name("config-before-native-"+datetime.datetime.now().strftime("%Y%m%d%H%M%S")+".json")
shutil.copy2(p,backup)
cfg["virtualDeviceName"]="uu伴侣 Native Mic"
p.write_text(json.dumps(cfg,ensure_ascii=False))
os.chmod(p,0o600)
print("Selected uu伴侣 Native Mic. Original config backed up to "+str(backup))
PY
echo "Quit and reopen uu伴侣 to apply. Do not remove Loopback until independent acceptance is complete."
