#!/usr/bin/env python3
"""Deploy the free uu Relay on your own Cloudflare account with Python stdlib."""
import argparse, json, os, secrets
from pathlib import Path
from urllib.request import Request, urlopen
from urllib.error import HTTPError

ROOT = Path(__file__).resolve().parent
API = "https://api.cloudflare.com/client/v4"


def api(method, path, token, body=None, content_type="application/json"):
    payload = None
    if body is not None:
        payload = json.dumps(body).encode() if content_type == "application/json" else body
    req = Request(API+path, data=payload, method=method,
                  headers={"Authorization":"Bearer "+token,"Content-Type":content_type,
                           "User-Agent":"uu-companion-opensource"})
    try:
        with urlopen(req, timeout=35) as response: result = json.load(response)
    except HTTPError as e:
        raise SystemExit(f"Cloudflare HTTP {e.code}: "+e.read().decode(errors="replace")[:600])
    if not result.get("success"):
        raise SystemExit("Cloudflare error: "+json.dumps(result.get("errors",[])))
    return result.get("result")


def multipart(metadata, source):
    boundary="uu-"+secrets.token_hex(16)
    output=[]
    for name,filename,mime,content in [
        ("metadata",None,"application/json",json.dumps(metadata).encode()),
        ("worker.mjs","worker.mjs","application/javascript+module",source),
    ]:
        header=f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"'
        if filename: header+=f'; filename="{filename}"'
        header+=f"\r\nContent-Type: {mime}\r\n\r\n"
        output.extend([header.encode(),content,b"\r\n"])
    output.append(f"--{boundary}--\r\n".encode())
    return b"".join(output),"multipart/form-data; boundary="+boundary


def main():
    parser=argparse.ArgumentParser(description="Self-host the uu encrypted media relay")
    parser.add_argument("--account-id",default=os.getenv("CLOUDFLARE_ACCOUNT_ID"))
    parser.add_argument("--name",default="uu-companion-relay")
    args=parser.parse_args()
    token=os.getenv("CLOUDFLARE_API_TOKEN")
    if not token or not args.account_id:
        parser.error("Set CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID environment variables")
    endpoint=f"/accounts/{args.account_id}/workers/scripts/{args.name}"
    # The GET script-content endpoint is not a JSON API. Use the listing
    # instead to reliably detect a first deployment vs a code update.
    scripts=api("GET",f"/accounts/{args.account_id}/workers/scripts",token)
    initial=not any(x.get("id")==args.name for x in scripts)
    meta={"main_module":"worker.mjs","compatibility_date":"2026-11-11",
          "bindings":[{"name":"ROOMS","type":"durable_object_namespace","class_name":"RelayRoom"}]}
    if initial:
        meta["migrations"]={"new_tag":"v1","new_sqlite_classes":["RelayRoom"]}
    data,kind=multipart(meta,(ROOT/"worker.mjs").read_bytes())
    api("PUT",endpoint,token,data,kind)
    api("POST",endpoint+"/subdomain",token,{"enabled":True,"previews_enabled":False})
    sub=api("GET",f"/accounts/{args.account_id}/workers/subdomain",token)["subdomain"]
    print(f"Deployed: https://{args.name}.{sub}.workers.dev/health")
    print(f"Set on both Macs: wss://{args.name}.{sub}.workers.dev")


if __name__=="__main__": main()
