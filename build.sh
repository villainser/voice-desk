#!/bin/zsh
set -eu
cd "${0:A:h}"
destination="${1:-build}"
mkdir -p "$destination"
destination="${destination:A}"
app="$destination/Voice Desk.app"
cache="$PWD/.build/module-cache"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$cache"
if [[ ! -f Vendor/libmp3lame.a ]]; then ./build-lame.sh; fi
xcrun swiftc -swift-version 5 -O -whole-module-optimization -parse-as-library \
  -Xfrontend -warn-long-expression-type-checking=500 -target arm64-apple-macos14.0 \
  -module-cache-path "$cache" \
  -import-objc-header Vendor/lame.h -L Vendor -lmp3lame \
  Sources/*.swift -o "$app/Contents/MacOS/VoiceDesk"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>VoiceDesk</string>
<key>CFBundleIdentifier</key><string>local.foldervoice.desktop</string>
<key>CFBundleName</key><string>Voice Desk</string>
<key>CFBundleDisplayName</key><string>Voice Desk</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>pl</string></array>
<key>CFBundleVersion</key><string>6</string>
<key>CFBundleShortVersionString</key><string>2.0.2</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>Record your voice as the source for ElevenLabs audio tools.</string>
<key>LSApplicationCategoryType</key><string>public.app-category.music</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
</dict></plist>
PLIST
if [[ -f Resources/AppIcon.icns ]]; then cp Resources/AppIcon.icns "$app/Contents/Resources/"; fi
cp -R Resources/en.lproj Resources/pl.lproj "$app/Contents/Resources/"
cp Resources/ThirdParty.txt "$app/Contents/Resources/"
cp Resources/LAME-LICENSE.txt "$app/Contents/Resources/"
codesign --force --sign - "$app"
echo "$app"
