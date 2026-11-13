#!/bin/sh
# PluginTool 未签名 IPA 构建脚本（Linux / clang-18 + ld64.lld-18）
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SDK=/opt/theos-build/sdks/iPhoneOS16.5.sdk
APP=PluginTool
cd "$ROOT"
mkdir -p build dist

echo "[1/5] compile"
clang-18 -target arm64-apple-ios14.0 -isysroot "$SDK" -fobjc-arc -fblocks -Os -w \
  -c ios/main.m -o build/main.o

echo "[2/5] link"
ld64.lld-18 -arch arm64 -platform_version ios 14.0 14.0 -syslibroot "$SDK" \
  -F"$SDK/System/Library/Frameworks" -o build/$APP build/main.o \
  -framework UIKit -framework Foundation -framework WebKit -framework CoreGraphics \
  -framework UniformTypeIdentifiers -adhoc_codesign "$SDK/usr/lib/libSystem.B.tbd"

echo "[3/5] stage"
STAGE=/tmp/plugintool-stage   # workspace 是 fake fs，权限位会被吃掉；打包必须在 /tmp
rm -rf "$STAGE"; mkdir -p "$STAGE/Payload/$APP.app"
cp build/$APP "$STAGE/Payload/$APP.app/$APP"
cp ios/Info.plist ios/PkgInfo "$STAGE/Payload/$APP.app/"
[ -d www ] && cp -R www "$STAGE/Payload/$APP.app/www"
find "$STAGE/Payload/$APP.app" -type d -exec chmod 755 {} \;
find "$STAGE/Payload/$APP.app" -type f -exec chmod 644 {} \;
# 可执行文件必须最后设 755（zip 直接读磁盘权限位）
chmod 755 "$STAGE/Payload/$APP.app/$APP"
ls -l "$STAGE/Payload/$APP.app"

echo "[4/5] zip"
rm -f "dist/$APP-unsigned.ipa"
(cd "$STAGE" && zip -qry "$ROOT/dist/$APP-unsigned.ipa" Payload)

echo "[5/5] verify"
python3 - "dist/$APP-unsigned.ipa" "$APP" <<'PY'
import sys, zipfile
ipa, app = sys.argv[1], sys.argv[2]
exe = f"Payload/{app}.app/{app}"
with zipfile.ZipFile(ipa) as z:
    bad = z.testzip()
    if bad: sys.exit(f"zip corrupt: {bad}")
    names = z.namelist()
    info = z.getinfo(exe)
    mode = (info.external_attr >> 16) & 0o777
    print(f"entries: {len(names)}")
    print(f"exe mode: {oct(mode)}")
    assert "Payload/%s.app/Info.plist" % app in names, "Info.plist missing"
    assert "Payload/%s.app/PkgInfo" % app in names, "PkgInfo missing"
    assert "Payload/%s.app/www/index.html" % app in names, "www missing"
    if mode != 0o755:
        # fs 不支持权限位时，强制改写 zip 条目属性
        mode = (info.external_attr >> 16) & 0xFFFF
        info.external_attr = (0o100755 << 16) | (mode & 0xFFFF)
        tmp = ipa + ".tmp"
        with zipfile.ZipFile(ipa) as zin, zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zout:
            for it in zin.infolist():
                data = zin.read(it.filename)
                if it.filename == exe:
                    it.external_attr = (0o100755 << 16) | (it.external_attr & 0xFFFF)
                zout.writestr(it, data)
        import os; os.replace(tmp, ipa)
        with zipfile.ZipFile(ipa) as z2:
            m2 = (z2.getinfo(exe).external_attr >> 16) & 0o777
        print("rewritten exe mode:", oct(m2))
        assert m2 == 0o755, "cannot set 755"
print("OK ipa ->", ipa)
PY
ls -lh "dist/$APP-unsigned.ipa"
