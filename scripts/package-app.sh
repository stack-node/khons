#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Khons"
VERSION="0.0.4"
BUILD_NUMBER="004"
BUILD_DIR="$ROOT_DIR/.build/arm64-apple-macosx/release"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
MODULE_CACHE_DIR="$ROOT_DIR/.build/module-cache"
ICON_SOURCE="$ROOT_DIR/Resources/Icon.png"
ICONSET_DIR="$DIST_DIR/$APP_NAME.iconset"
ICON_ICNS_PATH="$RESOURCES_DIR/Icon.icns"
ICON_BUNDLE_NAME="Icon"

cd "$ROOT_DIR"
mkdir -p "$MODULE_CACHE_DIR"

if [[ ! -x "$BUILD_DIR/$APP_NAME" ]]; then
  export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR"
  export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE_DIR"
  swift build -c release
fi

rm -rf "$APP_DIR"
rm -rf "$ICONSET_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BUILD_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME"
cp "$ROOT_DIR/Resources/Preview.png" "$RESOURCES_DIR/Preview.png"

if [[ -f "$ICON_SOURCE" ]]; then
  cp "$ICON_SOURCE" "$RESOURCES_DIR/Icon.png"
  mkdir -p "$ICONSET_DIR"
  ICON_RENDERER="$(mktemp "$DIST_DIR/icon-renderer.XXXXXX.swift")"
  cat > "$ICON_RENDERER" <<'EOF'
import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    fputs("Usage: icon-renderer <source> <size> <destination>\n", stderr)
    exit(1)
}

let sourceURL = URL(fileURLWithPath: arguments[1])
let destinationURL = URL(fileURLWithPath: arguments[3])
guard let image = NSImage(contentsOf: sourceURL) else {
    fputs("Unable to read source image.\n", stderr)
    exit(1)
}
guard let dimension = Int(arguments[2]) else {
    fputs("Invalid icon size.\n", stderr)
    exit(1)
}

let size = NSSize(width: dimension, height: dimension)
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: dimension,
    pixelsHigh: dimension,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("Unable to create bitmap context.\n", stderr)
    exit(1)
}

bitmap.size = size
NSGraphicsContext.saveGraphicsState()
guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Unable to create graphics context.\n", stderr)
    exit(1)
}

NSGraphicsContext.current = context
image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1.0)
context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Unable to create PNG data.\n", stderr)
    exit(1)
}

try pngData.write(to: destinationURL)
EOF

  for spec in \
    "16 icon_16x16.png" \
    "32 icon_16x16@2x.png" \
    "32 icon_32x32.png" \
    "64 icon_32x32@2x.png" \
    "128 icon_128x128.png" \
    "256 icon_128x128@2x.png" \
    "256 icon_256x256.png" \
    "512 icon_256x256@2x.png" \
    "512 icon_512x512.png" \
    "1024 icon_512x512@2x.png"
  do
    size="${spec%% *}"
    filename="${spec#* }"
    env CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR" SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE_DIR" \
      swift "$ICON_RENDERER" "$ICON_SOURCE" "$size" "$ICONSET_DIR/$filename" >/dev/null
  done

  rm -f "$ICON_RENDERER"

  if iconutil -c icns "$ICONSET_DIR" -o "$ICON_ICNS_PATH" >/dev/null 2>&1; then
    :
  else
    ICON_SETTER="$(mktemp "$DIST_DIR/icon-setter.XXXXXX.swift")"
    cat > "$ICON_SETTER" <<'EOF'
import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fputs("Usage: icon-setter <source> <bundle>\n", stderr)
    exit(1)
}

let sourceURL = URL(fileURLWithPath: arguments[1])
guard let image = NSImage(contentsOf: sourceURL) else {
    fputs("Unable to read source image.\n", stderr)
    exit(1)
}

let bundlePath = arguments[2]
guard NSWorkspace.shared.setIcon(image, forFile: bundlePath, options: []) else {
    fputs("Unable to assign bundle icon.\n", stderr)
    exit(1)
}
EOF

    env CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR" SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE_DIR" \
      swift "$ICON_SETTER" "$ICON_SOURCE" "$APP_DIR" >/dev/null
    rm -f "$ICON_SETTER"
  fi
fi

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
    <string>$ICON_BUNDLE_NAME</string>
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
