#!/bin/zsh
# Builds "build/Zero-One AI Launcher.app" from Sources/ + Resources/.
# Needs only the Xcode Command Line Tools (swiftc). No SwiftPM / Xcode project required.
#   ./build_app.sh            release build
#   ./build_app.sh --assets   regenerate Resources/ from ../Assets first (uses work/tools FFDec at build time)
#   ./build_app.sh --install  also copy the app to /Applications (Spotlight / Launchpad)
set -euo pipefail
cd "${0:A:h}"

APP_NAME="Zero-One AI Launcher"
EXE="ZeroOneLauncher"
BUILD="build"
APP="$BUILD/$APP_NAME.app"

REGEN_ASSETS=""
INSTALL=""
for arg in "$@"; do
  [[ "$arg" == "--assets" ]] && REGEN_ASSETS=1
  [[ "$arg" == "--install" ]] && INSTALL=1
done
[[ -n "$REGEN_ASSETS" || -f Resources/manifest.json ]] || { echo "Resources/ missing: run ./build_app.sh --assets"; exit 1; }

# Pick an SDK the installed compiler can use (CLT may ship a newer SDK than its swiftc).
pick_sdk() {
  local probe="$BUILD/.sdkprobe.swift"
  mkdir -p "$BUILD"
  print 'import SwiftUI\nimport AVFoundation\nlet _ = NSApplication.shared' > "$probe"
  local candidates=()
  [[ -n "${SDKROOT:-}" ]] && candidates+=("$SDKROOT")
  candidates+=("$(xcrun --show-sdk-path 2>/dev/null || true)")
  for s in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.[0-9]*.sdk 2>/dev/null | sort -t X -k 2 -V -r); do candidates+=("$s"); done
  for s in "${candidates[@]}"; do
    [[ -d "$s" ]] || continue
    if swiftc -sdk "$s" -target arm64-apple-macos14.0 -typecheck "$probe" >/dev/null 2>&1; then echo "$s"; return 0; fi
  done
  return 1
}
SDK=$(pick_sdk) || { echo "No macOS SDK compatible with $(swiftc --version 2>&1 | head -1)"; exit 1; }
echo "SDK: $SDK"

if [[ -n "$REGEN_ASSETS" ]]; then
  swiftc -O -sdk "$SDK" -target arm64-apple-macos14.0 Tools/asset_tool.swift -o "$BUILD/asset_tool"
  swiftc -O -sdk "$SDK" -target arm64-apple-macos14.0 Tools/sfx_tool.swift -o "$BUILD/sfx_tool"
  swiftc -O -sdk "$SDK" -target arm64-apple-macos14.0 Tools/voice_tool.swift -o "$BUILD/voice_tool"
  python3 Tools/prepare_assets.py --tool "$BUILD/asset_tool" --sfx-tool "$BUILD/sfx_tool" --voice-tool "$BUILD/voice_tool"
  REGEN_ICON=1
fi

if [[ -n "${REGEN_ICON:-}" || ! -f Resources/AppIcon.icns ]]; then
  swiftc -O -sdk "$SDK" -target arm64-apple-macos14.0 Tools/make_icon.swift -o "$BUILD/make_icon" && "$BUILD/make_icon" Resources
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -wmo -sdk "$SDK" -target arm64-apple-macos14.0 -parse-as-library -module-name "$EXE" \
  Sources/*.swift -o "$APP/Contents/MacOS/$EXE"

cp -R Skin Resources/Images Resources/Audio Resources/FX Resources/manifest.json Resources/ASSET_MANIFEST.md Resources/CREDITS.txt "$APP/Contents/Resources/"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>local.personal.zeroone-ai-launcher</string>
  <key>CFBundleExecutable</key><string>$EXE</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST

codesign --force --sign - --timestamp=none "$APP" >/dev/null
echo "Built: $PWD/$APP"

if [[ -n "$INSTALL" ]]; then
  DEST="/Applications/$APP_NAME.app"
  [[ -w /Applications ]] || DEST="$HOME/Applications/$APP_NAME.app"
  pkill -f "$DEST/Contents/MacOS/$EXE" 2>/dev/null || true
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  mdimport "$DEST" 2>/dev/null || true
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" 2>/dev/null || true
  echo "Installed: $DEST"
fi
