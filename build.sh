#!/bin/bash
# Сборка приложения «Проектор» в .app-бандл.
set -e
cd "$(dirname "$0")"

APP="Проектор.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> компилирую"
swiftc -O \
  -target arm64-apple-macos13.0 \
  -framework AppKit -framework AVFoundation -framework CoreImage -framework VideoToolbox \
  -o "$APP/Contents/MacOS/Proyektor" \
  Sources/*.swift

# Иконка приложения в стиле macOS (генерируется из iconset/).
if [ -f "Проектор.icns" ]; then
  cp "Проектор.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Проектор</string>
    <key>CFBundleDisplayName</key><string>Проектор</string>
    <key>CFBundleIdentifier</key><string>ru.smartproject.remote</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>Proyektor</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSHumanReadableCopyright</key><string>Управление проектором Smart Project</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" 2>/dev/null || true
echo "==> готово: $(pwd)/$APP"
