#!/bin/zsh
# Builds Clarity.app into ./build. Pass --install to also copy it to ~/Applications.
set -euo pipefail
cd "${0:A:h}"

APP=build/Clarity.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 \
    -target arm64-apple-macos14.0 \
    -import-objc-header Support/CGVirtualDisplay.h \
    -framework AppKit -framework SwiftUI -framework CoreGraphics -framework ServiceManagement \
    Sources/*.swift \
    -o "$APP/Contents/MacOS/Clarity"

cp Support/Info.plist "$APP/Contents/Info.plist"
[[ -f Support/AppIcon.icns ]] && cp Support/AppIcon.icns "$APP/Contents/Resources/" \
    && /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"

# Ad-hoc signature: enough to run on this Mac without a developer account.
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    mkdir -p ~/Applications
    pkill -x Clarity 2>/dev/null && sleep 1 || true
    rm -rf ~/Applications/Clarity.app
    cp -R "$APP" ~/Applications/
    echo "Installed to ~/Applications/Clarity.app"
fi
