#!/bin/bash
# 把编译产物打包成 NotchQuota.app(含图标)
set -e
cd ~/NotchQuota
swift build -c release

# 若图标不存在则重新生成
if [ ! -f AppIcon.icns ]; then
  echo "生成图标..."
  swift scripts/make_icon.swift AppIconSource.png
  ICONSET=AppIcon.iconset; rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  specs=("16 32" "32 64" "128 256" "256 512" "512 1024")
  i=0
  while [ $i -lt ${#specs[@]} ]; do
    read base ret <<< "${specs[$i]}"
    sips -z "$base" "$base" AppIconSource.png --out "$ICONSET/icon_${base}x${base}.png" >/dev/null 2>&1
    sips -z "$ret" "$ret" AppIconSource.png --out "$ICONSET/icon_${base}x${base}@2x.png" >/dev/null 2>&1
    i=$((i+1))
  done
  iconutil -c icns "$ICONSET" -o AppIcon.icns
fi

APP=~/Applications/NotchQuota.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/NotchQuota "$APP/Contents/MacOS/NotchQuota"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>NotchQuota</string>
  <key>CFBundleDisplayName</key><string>NotchQuota</string>
  <key>CFBundleIdentifier</key><string>com.simaojiu.notchquota</string>
  <key>CFBundleVersion</key><string>0.1</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleExecutable</key><string>NotchQuota</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# 刷新 Finder/Launchpad 图标缓存
touch "$APP"

echo "✅ 打包完成(含图标): $APP"
