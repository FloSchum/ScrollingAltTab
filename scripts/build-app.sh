#!/bin/bash
# Builds build/ScrollingAltTab.app (arm64).
# Signing: uses the local "ScrollingAltTab Local Signing" certificate when it is in the
# keychain, so the Accessibility permission survives rebuilds (macOS ties it to the
# signature). Without it the build is ad-hoc and must be re-authorised after every rebuild.
# Override with SIGN_IDENTITY="Name or SHA-1" scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/ScrollingAltTab"

APP="build/ScrollingAltTab.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ScrollingAltTab"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [ -z "${SIGN_IDENTITY:-}" ]; then
  if security find-certificate -c "ScrollingAltTab Local Signing" >/dev/null 2>&1; then
    SIGN_IDENTITY="ScrollingAltTab Local Signing"
  else
    SIGN_IDENTITY="-"
  fi
fi
echo "Signature : $SIGN_IDENTITY"
codesign --force --sign "$SIGN_IDENTITY" --identifier com.florentv.ScrollingAltTab "$APP"
codesign --verify --verbose=1 "$APP"
echo "OK: $APP"
