#!/bin/sh
# 打包 TencentVideo（APK 网页通道复刻版）为未签名 IPA
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SDK=/opt/theos-build/sdks/iPhoneOS16.5.sdk
APP=TencentVideo
cd "$ROOT"

echo "[1/6] compile"
clang-18 -target arm64-apple-ios14.0 -isysroot "$SDK" -fobjc-arc -fblocks -Os -w \
  -c tvapp/main.m -o build/tv.o

echo "[2/6] link"
ld64.lld-18 -arch arm64 -platform_version ios 14.0 14.0 -syslibroot "$SDK" \
  -F"$SDK/System/Library/Frameworks" -o build/$APP build/tv.o \
  -framework UIKit -framework Foundation -framework WebKit -framework CoreGraphics \
  -framework UniformTypeIdentifiers -framework AVKit -framework AVFoundation \
  -adhoc_codesign "$SDK/usr/lib/libSystem.B.tbd"

echo "[3/6] stage (in /tmp: workspace fs drops permission bits)"
STAGE=/tmp/tv-stage
rm -rf "$STAGE"; mkdir -p "$STAGE/Payload/$APP.app"
cp build/$APP "$STAGE/Payload/$APP.app/$APP"
cp tvapp/Info.plist "$STAGE/Payload/$APP.app/"
printf 'APPL????' > "$STAGE/Payload/$APP.app/PkgInfo"
for f in /tmp/Icon-*.png; do [ -f "$f" ] && cp "$f" "$STAGE/Payload/$APP.app/"; done || true

echo "[4/6] chmod"
find "$STAGE/Payload/$APP.app" -type d -exec chmod 755 {} \;
find "$STAGE/Payload/$APP.app" -type f -exec chmod 644 {} \;
chmod 755 "$STAGE/Payload/$APP.app/$APP"

echo "[5/6] zip"
mkdir -p dist
rm -f "dist/$APP-unsigned.ipa"
(cd "$STAGE" && zip -qry "$ROOT/dist/$APP-unsigned.ipa" Payload)

echo "[6/6] verify"
python3 - "dist/$APP-unsigned.ipa" "$APP" <<'PY'
import sys, zipfile, os, plistlib
ipa, app = sys.argv[1], sys.argv[2]
exe = f"Payload/{app}.app/{app}"
with zipfile.ZipFile(ipa) as z:
    assert z.testzip() is None
    names = z.namelist()
    info = z.getinfo(exe)
    mode = (info.external_attr >> 16) & 0o777
    if mode != 0o755:
        items = [(i, z.read(i.filename)) for i in z.infolist()]
        with zipfile.ZipFile(ipa + ".tmp", "w", zipfile.ZIP_DEFLATED) as out:
            for it, data in items:
                if it.filename == exe:
                    it.external_attr = (0o100755 << 16) | (it.external_attr & 0xFFFF)
                out.writestr(it, data)
        os.replace(ipa + ".tmp", ipa)
        mode = (zipfile.ZipFile(ipa).getinfo(exe).external_attr >> 16) & 0o777
    pl = plistlib.loads(zipfile.ZipFile(ipa).read(f"Payload/{app}.app/Info.plist"))
    print("app:", pl["CFBundleIdentifier"], pl["CFBundleShortVersionString"])
    print("exe mode:", oct(mode))
    print("entries:", len(names))
    print("icons:", [n.split('/')[-1] for n in names if n.endswith('.png')][:6])
    assert mode == 0o755
print("OK ->", ipa)
PY
ls -lh "dist/$APP-unsigned.ipa"
