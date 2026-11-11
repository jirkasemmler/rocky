#!/bin/bash
# Builds Rocky (iPhone app only, without the watch app) signed with the team in project.yml and
# installs it on the connected iPhone. Free Personal Team signing expires after 7 days: just run
# this again (the app's data stays on the phone).
# Usage: bash tools/install-iphone.sh        (iPhone connected by cable, unlocked)
set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE=$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /iPhone/ && / connected /' | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' | head -1 || true)
if [ -z "$DEVICE" ]; then
  echo "iPhone nenalezen. Připoj ho kabelem, odemkni a zkus to znovu." >&2
  xcrun devicectl list devices 2>/dev/null | grep physical >&2 || true
  exit 1
fi
echo "iPhone: $DEVICE"

# Phone-only variant of project.yml: the watch app is not embedded, so signing does not need a
# registered Apple Watch.
SPEC=build/project.phone-only.yml
mkdir -p build
python3 - "$SPEC" <<'PY'
import sys
s = open("project.yml").read()
s = s.replace("name: Rocky\n", "name: RockyPhone\n", 1)
watch_dep = """      - target: RockyWatch
        embed: true
        codeSign: true
        copy:
          destination: productsDirectory
          subpath: $(CONTENTS_FOLDER_PATH)/Watch
"""
assert watch_dep in s, "project.yml changed: update tools/install-iphone.sh"
s = s.replace(watch_dep, "").replace("        Rocky: all\n        RockyWatch: all\n", "        Rocky: all\n")
open(sys.argv[1], "w").write(s)
PY
xcodegen generate -q --spec "$SPEC" --project-root . --project .

echo "Sestavuji a podepisuji…"
xcodebuild -project RockyPhone.xcodeproj -scheme Rocky -destination "id=$DEVICE" \
  -derivedDataPath build/dd-dev -allowProvisioningUpdates build -quiet

echo "Instaluji…"
xcrun devicectl device install app --device "$DEVICE" build/dd-dev/Build/Products/Debug-iphoneos/Rocky.app >/dev/null
xcrun devicectl device process launch --device "$DEVICE" cz.semmler.rocky >/dev/null 2>&1 \
  && echo "Hotovo, Rocky běží." \
  || echo "Nainstalováno. Pokud iOS hlásí nedůvěryhodného vývojáře: Nastavení → Obecné → Správa VPN a zařízení → Důvěřovat."
