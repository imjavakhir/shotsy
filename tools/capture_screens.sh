#!/bin/zsh
# Captures raw App Store screens for each language from a simulator (Debug build).
# Usage: tools/capture_screens.sh <device-udid> <out-dir> <lang> [<lang> ...]   (lang = iOS language code)
# The device should hold a prepared library: real photos, one finished scan, a few photos marked for deletion.
set -e
DEV=$1; OUT=$2; shift 2
BID=com.solo.shotsy
shoot() { # lang file route
  xcrun simctl terminate $DEV $BID >/dev/null 2>&1 || true
  xcrun simctl launch $DEV $BID -AppleLanguages "($1)" -appearance light -onboarded YES -screenshotMode YES \
    -screenshotRoute "$3" >/dev/null
  sleep 6
  xcrun simctl io $DEV screenshot "$OUT/$1/$2.png" >/dev/null 2>&1
}
for LANG in "$@"; do
  mkdir -p "$OUT/$LANG"
  shoot $LANG 01-swipe quick20
  shoot $LANG 02-similar similar
  shoot $LANG 03-clean clean
  shoot $LANG 04-library library
  shoot $LANG 05-review review
  echo "captured $LANG"
done
