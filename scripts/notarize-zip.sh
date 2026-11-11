#!/bin/zsh
# Submit a signed ZIP with credentials from a local environment or Keychain.
# Do not print/store private keys, and never publish unless status Accepted.
set -e
cd "$(dirname "$0")/.."
archive="$1"
if [[ -z "$archive" || ! -f "$archive" ]]; then
  echo "Usage: scripts/notarize-zip.sh path/to/signed.zip" >&2
  exit 2
fi
result="$archive.notary.json"
if [[ -n "$NOTARYTOOL_PROFILE" ]]; then
  xcrun notarytool submit "$archive" --keychain-profile "$NOTARYTOOL_PROFILE" --wait --output-format json > "$result"
elif [[ -n "$ASC_KEY_PATH" && -n "$ASC_KEY_ID" && -n "$ASC_ISSUER_ID" ]]; then
  xcrun notarytool submit "$archive" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait --output-format json > "$result"
else
  echo "Set NOTARYTOOL_PROFILE or ASC_KEY_PATH / ASC_KEY_ID / ASC_ISSUER_ID" >&2
  exit 2
fi
/usr/bin/python3 - "$result" <<'PY'
import json,sys
data=json.load(open(sys.argv[1]))
print("Apple notarization:",data.get("status"),"submission:",data.get("id"))
if data.get("status")!="Accepted":
    raise SystemExit("Apple did not accept this archive; do not distribute it")
PY
