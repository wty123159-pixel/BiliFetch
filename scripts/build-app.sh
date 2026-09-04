#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_NAME="BiliFetch"
APP_VERSION="1.5.7"
APP_BUILD="17"
BUILD_DIR="$PROJECT_DIR/.build/release"
HOST_ARCH="$(uname -m)"
if [[ "$HOST_ARCH" == "arm64" ]]; then
    OTHER_ARCH="x86_64"
else
    OTHER_ARCH="arm64"
fi
OTHER_BUILD_DIR="$PROJECT_DIR/.build/manual-$OTHER_ARCH"
APP_DIR="$PROJECT_DIR/dist/$APP_NAME.app"
ZIP_PATH="$PROJECT_DIR/dist/BiliFetch-macOS-$APP_VERSION.zip"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
USER_TOOLS_DIR="$HOME/Library/Application Support/BiliFetch/Tools"
VENDOR_TOOLS_DIR="$PROJECT_DIR/Vendor/Tools"

cd "$PROJECT_DIR"
swift build -c release
mkdir -p "$OTHER_BUILD_DIR"
swiftc \
    -O \
    -target "$OTHER_ARCH-apple-macosx13.0" \
    -parse-as-library \
    "$PROJECT_DIR"/Sources/BiliFetch/*.swift \
    -o "$OTHER_BUILD_DIR/$APP_NAME"

if [[ -d "$APP_DIR" ]]; then
    find "$APP_DIR" -depth -delete
fi
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR/Tools"
lipo -create \
    "$BUILD_DIR/$APP_NAME" \
    "$OTHER_BUILD_DIR/$APP_NAME" \
    -output "$MACOS_DIR/$APP_NAME"
cp "$PROJECT_DIR/scripts/prepare-tools.command" "$RESOURCES_DIR/prepare-tools.command"
cp "$PROJECT_DIR/Assets/BiliFetch.icns" "$RESOURCES_DIR/BiliFetch.icns"
cp "$PROJECT_DIR/Windows/update-channel.json" "$RESOURCES_DIR/update-channel.json"
chmod +x "$MACOS_DIR/$APP_NAME" "$RESOURCES_DIR/prepare-tools.command"

for tool_name in yt-dlp ffmpeg ffprobe aria2c; do
    if [[ -x "$VENDOR_TOOLS_DIR/$tool_name" ]]; then
        cp "$VENDOR_TOOLS_DIR/$tool_name" "$RESOURCES_DIR/Tools/$tool_name"
        xattr -d com.apple.quarantine "$RESOURCES_DIR/Tools/$tool_name" 2>/dev/null || true
    elif [[ -x "$USER_TOOLS_DIR/$tool_name" ]]; then
        cp "$USER_TOOLS_DIR/$tool_name" "$RESOURCES_DIR/Tools/$tool_name"
    fi
done

mkdir -p "$RESOURCES_DIR/ThirdPartyLicenses"
if [[ -f "$VENDOR_TOOLS_DIR/FFmpeg-COPYING.LGPLv2.1" ]]; then
    cp "$VENDOR_TOOLS_DIR/FFmpeg-COPYING.LGPLv2.1" "$RESOURCES_DIR/ThirdPartyLicenses/FFmpeg-COPYING.LGPLv2.1"
fi
if [[ -f "$VENDOR_TOOLS_DIR/aria2-COPYING" ]]; then
    cp "$VENDOR_TOOLS_DIR/aria2-COPYING" "$RESOURCES_DIR/ThirdPartyLicenses/aria2-COPYING"
fi

if [[ -f "$PROJECT_DIR/Vendor/Source/aria2-1.37.0.tar.xz" ]]; then
    mkdir -p "$RESOURCES_DIR/ThirdPartySource"
    cp "$PROJECT_DIR/Vendor/Source/aria2-1.37.0.tar.xz" "$RESOURCES_DIR/ThirdPartySource/aria2-1.37.0.tar.xz"
    cp "$PROJECT_DIR/Vendor/Source/aria2-BUILD.md" "$RESOURCES_DIR/ThirdPartySource/aria2-BUILD.md"
fi

cp "$PROJECT_DIR/THIRD_PARTY_NOTICES.md" "$RESOURCES_DIR/THIRD_PARTY_NOTICES.md"

/usr/libexec/PlistBuddy -c "Clear dict" "$CONTENTS_DIR/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleName string $APP_NAME" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $APP_NAME" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.local.BiliFetch" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $APP_NAME" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string BiliFetch.icns" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $APP_VERSION" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $APP_BUILD" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 13.0" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSMultipleInstancesProhibited bool true" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSHighResolutionCapable bool true" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSHumanReadableCopyright string For authorized personal downloads only" "$CONTENTS_DIR/Info.plist"

codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

find "$PROJECT_DIR/dist" -maxdepth 1 -name "BiliFetch-macOS-$APP_VERSION.zip" -delete
COPYFILE_DISABLE=1 /usr/bin/ditto -c -k --keepParent --norsrc --noextattr "$APP_DIR" "$ZIP_PATH"

print ""
print "Built: $APP_DIR"
print "Open with: open '$APP_DIR'"
print "Archive: $ZIP_PATH"
shasum -a 256 "$ZIP_PATH"
