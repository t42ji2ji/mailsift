#!/bin/zsh
# Builds build/MailSift.app (app + bundled CLI).
#   ./build.sh             Developer ID signed, no hardened runtime (dev)
#   RELEASE=1 ./build.sh   Developer ID, hardened runtime, timestamp
set -euo pipefail
cd "${0:A:h}"

IDENTITY=40EE56946432E9A272F0B129ED83D5E843B5EAE8
ENTITLEMENTS=Resources/MailSift.entitlements
APP=build/MailSift.app

swift build -c release --product MailSiftApp
swift build -c release --product mailsift
BIN=$(swift build -c release --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/MailSiftApp" "$APP/Contents/MacOS/MailSift"
# Not in Contents/MacOS: "mailsift" and "MailSift" are the same name on a case-insensitive volume.
cp "$BIN/mailsift" "$APP/Contents/Helpers/mailsift"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Resources/Brand/*.pdf "$APP/Contents/Resources/"

# Inside out: the CLI first, then the bundle. Both drive Mail, so both get the Apple Events entitlement.
if [[ "${RELEASE:-0}" == 1 ]]; then
  SIGN=(--force --options runtime --timestamp --entitlements "$ENTITLEMENTS" -s "$IDENTITY")
  codesign "${SIGN[@]}" --identifier app.dorara.mailsift.cli "$APP/Contents/Helpers/mailsift"
  codesign "${SIGN[@]}" "$APP"
else
  # Same certificate as release: TCC matches grants by designated requirement, so dev builds and the
  # installed release share one Full Disk Access / Automation grant (ad-hoc would pin to the cdhash).
  codesign --force -s "$IDENTITY" --identifier app.dorara.mailsift.cli "$APP/Contents/Helpers/mailsift"
  codesign --force -s "$IDENTITY" "$APP"
fi

codesign --verify --deep --strict "$APP"
echo "$APP"
