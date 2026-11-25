#!/bin/bash
# Builds Rocky signed with the team in project.yml and installs it on the connected iPhone and,
# if Xcode sees a paired Apple Watch, on the watch too (watch app + complication). Without a
# watch it builds the phone-only variant (signing a watch app needs a registered watch).
# Free Personal Team signing expires after 7 days: just run this again (app data stays). Every
# run renews the signing for the phone, the watch and the complication together (D-28), and the
# app itself reminds you before it runs out.
# Usage: bash tools/install-iphone.sh        (iPhone connected by cable, unlocked; the watch
#                                             unlocked and next to the phone)
#   ROCKY_FRESH_PROFILES=1   renew the signing even when the cached profiles are fresh
set -euo pipefail
cd "$(dirname "$0")/.."

# --- Signing renewal ---------------------------------------------------------------------------
# Xcode reissues a provisioning profile only after it expired, so a mid-week build keeps the old
# expiry and the profiles drift apart (the watch app once died 4 days before the phone app).
# Before building, Rocky's cached profiles are therefore moved aside when any of them has less
# than PROFILE_MIN_HOURS left; Xcode then issues new ones, all for a full 7 days. They are put
# back when the build fails (offline, Apple error), so a still valid signing is never lost.
PROFILE_MIN_HOURS=156   # 6.5 days: renews at most once per 12 hours
PROFILE_STASH=""
BUILD_OK=0
LAUNCHED=0
PHONE_ONLY=0

profile_field() {  # <decoded profile plist> <key>
  printf '%s' "$1" | plutil -extract "$2" raw - 2>/dev/null || true
}

epoch_of() {  # 2026-12-02T21:02:40Z -> seconds since 1970, empty when unparsable
  date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || true
}

restore_profiles() {
  [ -n "$PROFILE_STASH" ] && [ -d "$PROFILE_STASH" ] || return 0
  if [ "$BUILD_OK" != 1 ]; then
    local sub target f
    for sub in "$PROFILE_STASH"/*; do
      [ -f "$sub/origin" ] || continue
      target=$(cat "$sub/origin")
      for f in "$sub"/*.mobileprovision; do
        [ -f "$f" ] || continue
        [ -e "$target/$(basename "$f")" ] || mv "$f" "$target/"
      done
    done
    echo "Sestavení selhalo, původní podpisové profily jsem vrátil." >&2
  fi
  rm -rf "$PROFILE_STASH"
}
trap restore_profiles EXIT

renew_profiles() {  # all | phone (phone: the watch app's profiles stay, they cannot be reissued without the watch)
  local scope=$1 now dir f plist name expiry seconds stale=0 list="" index=0 sub
  now=$(date +%s)
  for dir in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" "$HOME/Library/MobileDevice/Provisioning Profiles"; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*.mobileprovision; do
      [ -f "$f" ] || continue
      plist=$(security cms -D -i "$f" 2>/dev/null || true)
      name=$(profile_field "$plist" Name)
      case "$name" in *cz.semmler.rocky*) ;; *) continue ;; esac
      if [ "$scope" = phone ]; then case "$name" in *watchkitapp*) continue ;; esac; fi
      seconds=$(epoch_of "$(profile_field "$plist" ExpirationDate)")
      if [ -z "$seconds" ] || [ $((seconds - now)) -lt $((PROFILE_MIN_HOURS * 3600)) ]; then stale=1; fi
      list="$list$f
"
    done
  done
  if [ -z "$list" ]; then return 0; fi
  if [ "$stale" != 1 ] && [ "${ROCKY_FRESH_PROFILES:-0}" != 1 ]; then return 0; fi
  echo "Obnovuji podpis (nové profily na 7 dní)…"
  PROFILE_STASH=$(mktemp -d)
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    index=$((index + 1))
    sub="$PROFILE_STASH/$index"
    mkdir -p "$sub"
    dirname "$f" > "$sub/origin"
    mv "$f" "$sub/"
  done <<EOF
$list
EOF
}

watch_profiles_ready() {  # <watch device id>: do the cached watch app + complication profiles list it?
  local dir f plist name ready=0
  for dir in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" "$HOME/Library/MobileDevice/Provisioning Profiles"; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*.mobileprovision; do
      [ -f "$f" ] || continue
      plist=$(security cms -D -i "$f" 2>/dev/null || true)
      name=$(profile_field "$plist" Name)
      case "$name" in *cz.semmler.rocky.watchkitapp|*cz.semmler.rocky.watchkitapp.widgets) ;; *) continue ;; esac
      if printf '%s' "$plist" | plutil -extract ProvisionedDevices json -o - - 2>/dev/null | grep -q "$1"; then
        ready=$((ready + 1))
      else
        return 1
      fi
    done
  done
  [ "$ready" -ge 2 ]
}

report_expiry() {  # <built Rocky.app>: prints when the earliest of its profiles runs out
  local f plist seconds earliest=""
  while IFS= read -r f; do
    plist=$(security cms -D -i "$f" 2>/dev/null || true)
    seconds=$(epoch_of "$(profile_field "$plist" ExpirationDate)")
    [ -n "$seconds" ] || continue
    if [ -z "$earliest" ] || [ "$seconds" -lt "$earliest" ]; then earliest=$seconds; fi
  done <<EOF
$(find "$1" -name embedded.mobileprovision 2>/dev/null)
EOF
  if [ -n "$earliest" ]; then
    if [ "$LAUNCHED" = 1 ]; then
      echo "Podpis platí do $(date -r "$earliest" '+%-d. %-m. %H:%M'). Rocky ti přeinstalaci včas připomene."
    else
      echo "Podpis platí do $(date -r "$earliest" '+%-d. %-m. %H:%M'). Připomínka se naplánuje, až Rocky v telefonu otevřeš."
    fi
    if [ "$PHONE_ONLY" = 1 ]; then
      echo "Pozor: aplikace v hodinkách má vlastní, starší podpis a tato připomínka ho nehlídá."
    fi
  fi
}

launch_or_hint() {  # <phone device id> <message when it runs>
  if xcrun devicectl device process launch --device "$1" cz.semmler.rocky >/dev/null 2>&1; then
    LAUNCHED=1
    echo "$2"
  else
    echo "Nainstalováno, ale Rocky se nepodařilo spustit (zamčený telefon?). Otevři ho jednou ručně, aby si naplánoval připomínku přeinstalace."
    echo "Pokud iOS hlásí nedůvěryhodného vývojáře: Nastavení → Obecné → Správa VPN a zařízení → Důvěřovat."
  fi
}
# -----------------------------------------------------------------------------------------------

# Real iPhones only (not simulators). The "Reality" column is empty while the phone is
# "available" but not fully connected yet, so filter out simulators instead of matching "physical".
DEVICE=$(xcrun devicectl list devices 2>/dev/null | grep -v simulated | grep -E ' (connected|available) ' \
  | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' | head -1 || true)
if [ -z "$DEVICE" ]; then
  echo "iPhone nenalezen. Připoj ho kabelem, odemkni a zkus to znovu." >&2
  xcrun devicectl list devices 2>/dev/null | grep physical >&2 || true
  exit 1
fi
echo "iPhone: $DEVICE"

WATCH=$(xcrun devicectl list devices 2>/dev/null | grep -v simulated | grep -i "watch" | grep -E ' (connected|available) ' \
  | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' | head -1 || true)
if [ -n "$WATCH" ]; then
  echo "Apple Watch: $WATCH (instaluji i na hodinky)"
  renew_profiles all
  xcodegen generate -q
  echo "Sestavuji a podepisuji…"
  # A phone-destination build issues missing watch profiles for the iPhone only, and the watch
  # then refuses the install (0xe8008012). So when the cached watch profiles do not list the
  # watch (just moved aside above, or never issued), build the watch targets first with the watch
  # as destination: that puts the watch in. Same derived data, so nothing is built twice. Skipped
  # otherwise, because this build needs the watch awake and reachable.
  if ! watch_profiles_ready "$WATCH"; then
    xcodebuild -project Rocky.xcodeproj -scheme RockyWatch -destination "id=$WATCH" -destination-timeout 180 \
      -derivedDataPath build/dd-full -allowProvisioningUpdates build -quiet \
      || { echo "Hodinky nejsou dostupné pro podpis. Odemkni je, nech je u telefonu a pusť skript znovu." >&2; exit 1; }
  fi
  xcodebuild -project Rocky.xcodeproj -scheme Rocky -destination "id=$DEVICE" \
    -derivedDataPath build/dd-full -allowProvisioningUpdates build -quiet
  BUILD_OK=1
  APP=build/dd-full/Build/Products/Debug-iphoneos/Rocky.app
  echo "Instaluji do iPhonu…"
  xcrun devicectl device install app --device "$DEVICE" "$APP" >/dev/null
  echo "Instaluji do hodinek…"
  # The connection to the watch goes through the phone and often times out on the first try.
  for attempt in 1 2 3; do
    if xcrun devicectl device install app --device "$WATCH" "$APP/Watch/RockyWatch.app" >/dev/null; then break; fi
    if [ "$attempt" = 3 ]; then
      echo "Do hodinek se nepodařilo nainstalovat. Odemkni je, nech je u telefonu a pusť skript znovu." >&2
      exit 1
    fi
    echo "Hodinky neodpověděly, zkouším znovu ($attempt/3)…"
    sleep 5
  done
  launch_or_hint "$DEVICE" "Hotovo, Rocky běží (iPhone + hodinky)."
  report_expiry "$APP"
  exit 0
fi

echo "Hodinky nevidím: instaluji jen do iPhonu, podpis aplikace v hodinkách se NEobnoví." >&2
renew_profiles phone
PHONE_ONLY=1

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
BUILD_OK=1

echo "Instaluji…"
APP=build/dd-dev/Build/Products/Debug-iphoneos/Rocky.app
xcrun devicectl device install app --device "$DEVICE" "$APP" >/dev/null
launch_or_hint "$DEVICE" "Hotovo, Rocky běží."
report_expiry "$APP"
