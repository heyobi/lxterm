#!/bin/sh
# Builds LxTerm.app with plain clang (no Xcode project).
# usage: scripts/build-app.sh sim|dev OUT.app [BUILD_NUMBER]
# Needs: xt/ (xterm.js from npm), rootfs-*.tar.gz, Xcode command line tools.
set -eu
KIND=$1; APP=$2; BUILD=${3:-1}
if [ "$KIND" = sim ]; then SDK=iphonesimulator; TGT=arm64-apple-ios15.0-simulator; PLAT=iPhoneSimulator
else SDK=iphoneos; TGT=arm64-apple-ios15.0; PLAT=iPhoneOS; fi
SDKPATH=$(xcrun --sdk $SDK --show-sdk-path)
SRC="lxios/main.m lxios/untar.c core/elf.c core/scan.c core/vm.c core/cpu.c core/simd.c core/linux.c core/load.c core/dl.c core/bionic.c core/proc.c core/binder.c core/sf.c core/af.c core/gralloc.c core/snap.c core/hle.c core/tty.c"
rm -rf "$APP"; mkdir -p "$APP"
xcrun --sdk $SDK clang -target $TGT -isysroot "$SDKPATH" -O2 -g0 -Wall -fobjc-arc -std=gnu11 \
    -o "$APP/LxTerm" $SRC -framework UIKit -framework Foundation -framework WebKit -framework QuartzCore -lz -lresolv

# the icon: an asset catalog compiled by actool (App Store Connect wants Assets.car)
AC=$(mktemp -d)/Assets.xcassets
mkdir -p "$AC/AppIcon.appiconset"
cp lxios/AppIcon.png "$AC/AppIcon.appiconset/AppIcon.png"
cat > "$AC/Contents.json" <<'J'
{ "info" : { "author" : "xcode", "version" : 1 } }
J
cat > "$AC/AppIcon.appiconset/Contents.json" <<'J'
{ "images" : [ { "filename" : "AppIcon.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" } ],
  "info" : { "author" : "xcode", "version" : 1 } }
J
xcrun actool "$AC" --compile "$APP" --platform $SDK --minimum-deployment-target 15.0 --app-icon AppIcon \
    --output-partial-info-plist "$AC/../partial.plist" --target-device iphone --target-device ipad > /dev/null

cp lxios/Info.plist lxios/PrivacyInfo.xcprivacy lxios/term.html "$APP/"
P="$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$P"
/usr/libexec/PlistBuddy -c "Delete :CFBundleSupportedPlatforms" "$P"
/usr/libexec/PlistBuddy -c "Add :CFBundleSupportedPlatforms array" -c "Add :CFBundleSupportedPlatforms:0 string $PLAT" "$P"
/usr/libexec/PlistBuddy -c "Merge $AC/../partial.plist" "$P"
# what Xcode would record about the build (App Store Connect checks these)
SDKVER=$(xcrun --sdk $SDK --show-sdk-version)
XCV=$(xcodebuild -version | awk 'NR==1{print $2}' | awk -F. '{printf "%d%d%d", $1, $2, ($3==""?0:$3)}')
XCB=$(xcodebuild -version | awk 'NR==2{print $3}')
for kv in "DTPlatformName string $SDK" "DTPlatformVersion string $SDKVER" "DTSDKName string $SDK$SDKVER" \
          "DTSDKBuild string $(xcrun --sdk $SDK --show-sdk-build-version)" "DTXcode string 0$XCV" "DTXcodeBuild string $XCB" \
          "DTCompiler string com.apple.compilers.llvm.clang.1_0" "DTPlatformBuild string $(xcrun --sdk $SDK --show-sdk-build-version)" \
          "BuildMachineOSBuild string $(sw_vers -buildVersion)"; do
    set -- $kv
    /usr/libexec/PlistBuddy -c "Delete :$1" "$P" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :$1 $2 $3" "$P"
done
plutil -lint "$P"

XT=xt/$(ls xt | grep '^xterm-xterm-5' | grep -v tgz); FIT=xt/$(ls xt | grep '^xterm-addon-fit' | grep -v tgz)
cp $XT/package/lib/xterm.js $XT/package/css/xterm.css $FIT/package/lib/addon-fit.js "$APP/"
mkdir -p "$APP/licenses"; cp $XT/package/LICENSE "$APP/licenses/xterm.js.txt"; cp LICENSE NOTICE.md "$APP/licenses/"
cp rootfs-alpine.tar.gz rootfs-debian.tar.gz "$APP/"
du -sh "$APP"
