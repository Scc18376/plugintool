#!/bin/sh
# 一次性装好 iOS 交叉编译环境（Alpine / iSH）
set -e
echo "[1] clang-18 + ld64.lld-18"
apk add --no-cache clang18 lld18 llvm18 git
ln -sf /usr/bin/ld64.lld /usr/bin/ld64.lld-18
ln -sf /usr/bin/clang-18 /usr/bin/clang

echo "[2] iPhoneOS16.5.sdk (theos/sdks 稀疏检出)"
mkdir -p /opt/theos-build/sdks
if [ ! -d /opt/theos-build/sdks/iPhoneOS16.5.sdk ]; then
  cd /opt/theos-build
  rm -rf sdks-repo
  git -c http.version=HTTP/1.1 clone --depth 1 --filter=blob:none --sparse \
      https://github.com/theos/sdks.git sdks-repo
  cd sdks-repo && git sparse-checkout set iPhoneOS16.5.sdk
  mv iPhoneOS16.5.sdk /opt/theos-build/sdks/
  cd /opt/theos-build && rm -rf sdks-repo
fi
du -sh /opt/theos-build/sdks/iPhoneOS16.5.sdk
echo "done: clang-18 / ld64.lld-18 / SDK ready"
