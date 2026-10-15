#!/bin/sh
set -e
cd "$(dirname "$0")"
A="OpenMem.app"
rm -rf "$A"; mkdir -p "$A/Contents/MacOS"
swiftc -O -target "$(uname -m)-apple-macos14" *.swift -o "$A/Contents/MacOS/OpenMem"
mkdir -p "$A/Contents/Resources"
cp assets/AppIcon.icns "$A/Contents/Resources/AppIcon.icns"
cat > "$A/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>OpenMem</string>
<key>CFBundleIdentifier</key><string>io.github.medjbilou.openmem</string>
<key>CFBundleName</key><string>OpenMem</string><key>CFBundleShortVersionString</key><string>2.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
P
codesign --force --sign - "$A"
echo built $A
