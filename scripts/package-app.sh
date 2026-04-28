#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Khons"
VERSION="0.0.1"
BUILD_NUMBER="001"
BUILD_DIR="$ROOT_DIR/.build/arm64-apple-macosx/release"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
MODULE_CACHE_DIR="$ROOT_DIR/.build/module-cache"

cd "$ROOT_DIR"

if [[ ! -x "$BUILD_DIR/$APP_NAME" ]]; then
  mkdir -p "$MODULE_CACHE_DIR"
  export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR"
  export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE_DIR"
  swift build -c release
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BUILD_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME"
cp "$ROOT_DIR/Resources/Preview.png" "$RESOURCES_DIR/Preview.png"

cat > "$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>Preview</string>
    <key>CFBundleIdentifier</key>
    <string>com.stacknode.khons</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo -n "APPL????" > "$CONTENTS_DIR/PkgInfo"

ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$DIST_DIR/$APP_NAME-$BUILD_NUMBER.zip"

echo "Created:"
echo "  $APP_DIR"
echo "  $DIST_DIR/$APP_NAME-$BUILD_NUMBER.zip"
