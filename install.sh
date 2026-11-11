#!/bin/zsh
set -e
cd "$(dirname "$0")"
role="$1"
if [[ "$role" == "uninstall" ]]; then
  rm -f "$HOME/Library/LaunchAgents/com.uu.companion.plist"
  echo "已移除旧式登录项。请在系统设置 > 通用 > 登录项与扩展中关闭 uu伴侣。"
  exit 0
fi
if [[ "$role" != "sender" && "$role" != "receiver" ]]; then
  echo "用法: ./install.sh sender|receiver [本地认证密钥文件] [发送端局域网 IP]（密钥可省略，自动生成）"
  exit 2
fi
secret_file="$2"
host="$3"
if [[ -n "$secret_file" && ! -r "$secret_file" ]]; then
  echo "指定的本地认证密钥文件不存在"
  exit 2
fi
if [[ ! -d "build/uu伴侣.app" ]]; then ./build.sh; fi
mkdir -p "$HOME/Applications" "$HOME/Library/Application Support/uu伴侣" "$HOME/Library/Logs" backup
python3 - "$role" "$secret_file" "$host" <<'PY'
import datetime,json,os,pathlib,subprocess,sys,shutil,secrets
role,secret_file,host=sys.argv[1:]
target=pathlib.Path.home()/"Library/Application Support/uu伴侣/config.json"
existing={}
if target.exists():
    existing=json.loads(target.read_text())
    backup=target.with_name("config-before-reinstall-"+datetime.datetime.now().strftime("%Y%m%d%H%M%S")+".json")
    shutil.copy2(target,backup)
token=pathlib.Path(secret_file).read_text().strip() if secret_file else (existing.get("token") or secrets.token_hex(32))
if len(token)<32: raise SystemExit("本地密钥长度不足")
config={"role":role,"token":token,"host":(host or existing.get("host")) if role=="receiver" else None,"port":existing.get("port",50555)}
if role=="receiver":
    report=subprocess.run(["/usr/sbin/system_profiler","SPAudioDataType"],capture_output=True,text=True,timeout=20).stdout
    devices=[x for x in ("uu伴侣 Native Mic","uu伴侣 Mic","BlackHole 2ch") if x+":" in report]
    preferred=existing.get("virtualDeviceName") if existing.get("role")=="receiver" else None
    if preferred and preferred not in devices:
        print("原选定的虚拟麦克风不可用，尝试选择其他可用设备:",preferred)
        preferred=None
    if not devices: raise SystemExit("接收端缺少虚拟麦克风，请先安装 NativeMic 驱动")
    config["virtualDeviceName"]=preferred or devices[0]
target.write_text(json.dumps(config,ensure_ascii=False))
os.chmod(target,0o600)
print("配置完成:",role,"输入设备:",config.get("virtualDeviceName","本机麦克风"),"主机:",config.get("host") or "Bonjour")
PY
rm -f "$HOME/Library/LaunchAgents/com.uu.companion.plist"
if [[ -d "$HOME/Applications/uu伴侣.app" ]]; then
  echo "提示：如果旧版仍在运行，请先退出旧版 uu伴侣。"
  rm -rf backup/uu-before-reinstall.app
  cp -R "$HOME/Applications/uu伴侣.app" backup/uu-before-reinstall.app
fi
rm -rf "$HOME/Applications/uu伴侣.app"
cp -R "build/uu伴侣.app" "$HOME/Applications/uu伴侣.app"
codesign --verify --deep --strict "$HOME/Applications/uu伴侣.app"
echo "uu伴侣 已安装。打开 ~/Applications/uu伴侣.app；首次使用请批准麦克风/本地网络和登录项权限。"
