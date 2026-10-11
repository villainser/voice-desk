#!/bin/zsh
set -eu
cd "${0:A:h}"
destination="${1:-../../outputs}"
mkdir -p "$destination"
destination="${destination:A}"
app="$destination/Folder do Glosu.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" ../build/module-cache
if [[ ! -f Vendor/libmp3lame.a ]]; then ./build-lame.sh; fi
xcrun swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macos14.0 \
  -module-cache-path ../build/module-cache \
  -import-objc-header Vendor/lame.h -L Vendor -lmp3lame \
  Sources/Core.swift Sources/App.swift -o "$app/Contents/MacOS/FolderVoice"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>FolderVoice</string>
<key>CFBundleIdentifier</key><string>local.foldervoice.desktop</string>
<key>CFBundleName</key><string>Folder do Glosu</string>
<key>CFBundleDisplayName</key><string>Folder → Głos</string>
<key>CFBundleVersion</key><string>3</string>
<key>CFBundleShortVersionString</key><string>1.2</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
</dict></plist>
PLIST
if [[ -f Resources/AppIcon.icns ]]; then cp Resources/AppIcon.icns "$app/Contents/Resources/"; fi
cp Resources/ThirdParty.txt "$app/Contents/Resources/"
cp Resources/LAME-LICENSE.txt "$app/Contents/Resources/"
codesign --force --sign - "$app"
echo "$app"
