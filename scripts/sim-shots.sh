#!/usr/bin/env bash
# App Store screenshots from an iOS simulator: installs the simulator build, launches it with
# -shots (lxios/LxTerm/Tour.swift types the commands), and takes a screenshot each time the tour
# writes a scene name to Documents/shots/ready, answering in Documents/shots/next.
# Usage: sim-shots.sh "<device name>" <out dir>
#   iPhone 17 Pro -> 1206x2622 (6.3"), iPad Pro 13-inch (M5) -> 2064x2752
set -euo pipefail
NAME_DEV=$1; OUT=$2
BUNDLE=com.heyobi.lxterm
mkdir -p "$OUT"
DEV=$(bash scripts/sim-device.sh "$NAME_DEV")
echo "simulator $NAME_DEV $DEV"
xcrun simctl boot "$DEV" || true
xcrun simctl bootstatus "$DEV" -b > /dev/null
xcrun simctl status_bar "$DEV" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100 || true
# no "slide to type" introduction over the keyboard
xcrun simctl spawn "$DEV" defaults write com.apple.Preferences DidShowContinuousPathIntroduction -bool true || true
APP=$(find build/dd -name LxTerm.app -path '*iphonesimulator*' | head -n 1)
xcrun simctl uninstall "$DEV" "$BUNDLE" || true
xcrun simctl install "$DEV" "$APP"
xcrun simctl launch "$DEV" "$BUNDLE" -shots
DATA=$(xcrun simctl get_app_container "$DEV" "$BUNDLE" data)
for i in $(seq 1 1800); do
  if [ -f "$DATA/Documents/shots/ready" ]; then
    NAME=$(cat "$DATA/Documents/shots/ready")
    [ "$NAME" = "done" ] && { echo "tour finished after ${i}s"; break; }
    if [ ! -f "$OUT/$NAME.png" ]; then
      sleep 1
      xcrun simctl io "$DEV" screenshot "$OUT/$NAME.png" || echo "screenshot failed for $NAME"
      echo "saved $NAME after ${i}s"
    fi
    printf '%s' "$NAME" > "$DATA/Documents/shots/next"
  fi
  sleep 1
done
sips -g pixelWidth -g pixelHeight "$OUT"/*.png | grep pixel | sort | uniq -c || true
xcrun simctl shutdown "$DEV" || true
