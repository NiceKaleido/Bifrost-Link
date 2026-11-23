#!/bin/zsh
set -e
ROOT="${0:A:h:h}"
cd "$ROOT"
APP="$ROOT/build/Bifrost Link.app"

# Sign with the self-signed "Bifrost Link Self-Signed" certificate so every build, local or from the
# release workflow, has the same identity: macOS then keeps things tied to it, like "Open at login",
# across updates. Without the certificate (fresh machine, CI without the secret) fall back to ad-hoc.
SIGN_ID="${BIFROST_SIGN_IDENTITY:-Bifrost Link Self-Signed}"
if ! security find-identity -p codesigning 2>/dev/null | grep -qF "\"$SIGN_ID\""; then
  echo "warning: signing identity \"$SIGN_ID\" not found, signing ad-hoc" >&2
  SIGN_ID="-"
fi
sign() { codesign --force --sign "$SIGN_ID" --timestamp=none "$@"; }

if [[ ! -f Resources/bifrost-server.jar ]]; then
  ./server/build.sh
fi

if [[ ! -f Resources/AppIcon.icns || Resources/logo.png -nt Resources/AppIcon.icns ]]; then
  TMP="$(mktemp -d)"
  cp Resources/logo.png "$TMP/icon.png"
  mkdir -p "$TMP/AppIcon.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
  rm -rf "$TMP"
fi

swift build -c release
BIN="$(swift build -c release --show-bin-path)/BifrostLink"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Bifrost Link"
cp Resources/bifrost-server.jar Resources/AppIcon.icns "$APP/Contents/Resources/"

ADB_BIN="$(command -v adb || true)"
[[ -z "$ADB_BIN" && -x /opt/homebrew/share/android-commandlinetools/platform-tools/adb ]] && ADB_BIN=/opt/homebrew/share/android-commandlinetools/platform-tools/adb
[[ -n "$ADB_BIN" ]] && cp "${ADB_BIN:A}" "$APP/Contents/Resources/adb"

bundle_tool() {
  local src="$1" dest="$2"
  local name="$(basename "$src")"
  cp -L "$src" "$dest/$name"
  chmod u+w "$dest/$name"
  fix_deps "$dest/$name" "$dest"
}

fix_deps() {
  local file="$1" dest="$2" dep base
  for dep in $(otool -L "$file" | awk 'NR>1 {print $1}' | grep -E '^/opt/homebrew|^/usr/local'); do
    base="$(basename "$dep")"
    if [[ ! -f "$dest/$base" ]]; then
      cp -L "$dep" "$dest/$base"
      chmod u+w "$dest/$base"
      install_name_tool -id "@loader_path/$base" "$dest/$base" 2>/dev/null
      fix_deps "$dest/$base" "$dest"
    fi
    install_name_tool -change "$dep" "@loader_path/$base" "$file" 2>/dev/null
  done
}

AAPT2="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}/build-tools/36.0.0/aapt2"
if [[ -x "$AAPT2" ]]; then
  mkdir -p "$APP/Contents/Resources/tools"
  cp "$AAPT2" "$APP/Contents/Resources/tools/aapt2"
fi

for tool in chdman xdelta3; do
  TOOL_PATH="$(command -v $tool || true)"
  if [[ -n "$TOOL_PATH" ]]; then
    mkdir -p "$APP/Contents/Resources/tools"
    bundle_tool "$TOOL_PATH" "$APP/Contents/Resources/tools"
  fi
done
# Helpers first (inside-out), then the app itself further down.
for f in "$APP/Contents/Resources/adb" "$APP/Contents/Resources/tools"/*(N); do
  [[ -f "$f" ]] && sign "$f"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Bifrost Link</string>
  <key>CFBundleDisplayName</key><string>Bifrost Link</string>
  <key>CFBundleIdentifier</key><string>eu.nicekaleido.bifrostlink</string>
  <key>CFBundleExecutable</key><string>Bifrost Link</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${BIFROST_VERSION:-1.0}</string>
  <key>CFBundleVersion</key><string>${BIFROST_BUILD:-1}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

sign "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP (signed: $([[ "$SIGN_ID" == "-" ]] && echo ad-hoc || echo "$SIGN_ID"))"
if [[ "$1" == "--dmg" ]]; then
  DMG="$ROOT/build/Bifrost-Link-${BIFROST_VERSION:-1.0}.dmg"
  STAGE="$(mktemp -d)"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  rm -f "$DMG"
  hdiutil create -volname "Bifrost Link" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG" >/dev/null
  rm -rf "$STAGE"
  echo "Built $DMG"
fi
if [[ "$1" == "--install" ]]; then
  rm -rf "/Applications/Bifrost Link.app"
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/Bifrost Link.app"
fi
