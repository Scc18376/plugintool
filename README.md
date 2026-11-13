# PluginTool — Linux 交叉编译 iOS IPA

## 目录
```
ios/
  main.m              # WebView 外壳 + 原生插件桥 + SSH 探测
  Info.plist          # bundle id: com.baby.plugintool, minOS 14.0
  PkgInfo             # APPL????
  build_ipa.sh        # 编译→链接→打包→校验 一条龙
  setup_toolchain.sh  # 装 clang-18 / ld64.lld-18 / iPhoneOS16.5.sdk
www/                  # 前端资源，改完不用重编译，直接重打包
  index.html style.css app.js
keys/                 # 主机密钥（已部署到 165.99.43.34）
  id_ed25519 id_ed25519.pub  install_pubkey.sh  connect.sh
build/                # main.o / PluginTool
dist/
  PluginTool-unsigned.ipa
```

## 一条命令出包
```sh
sh ios/build_ipa.sh
```
产出 `dist/PluginTool-unsigned.ipa`，末尾自动校验：zip 完整、Info.plist/PkgInfo/www 存在、可执行文件 755。

## 手动三步（等价）
```sh
clang-18 -target arm64-apple-ios14.0 -isysroot /opt/theos-build/sdks/iPhoneOS16.5.sdk \
  -fobjc-arc -fblocks -Os -w -c ios/main.m -o build/main.o

ld64.lld-18 -arch arm64 -platform_version ios 14.0 14.0 \
  -syslibroot /opt/theos-build/sdks/iPhoneOS16.5.sdk \
  -F/opt/theos-build/sdks/iPhoneOS16.5.sdk/System/Library/Frameworks \
  -o build/PluginTool build/main.o \
  -framework UIKit -framework Foundation -framework WebKit \
  -framework CoreGraphics -framework UniformTypeIdentifiers \
  -adhoc_codesign /opt/theos-build/sdks/iPhoneOS16.5.sdk/usr/lib/libSystem.B.tbd

sh ios/build_ipa.sh   # 或手动 zip：Payload/PluginTool.app/{PluginTool,Info.plist,PkgInfo,www/}
```

## 只改前端
```sh
# www/ 改完，重 zip 即可，不动编译器
sh ios/build_ipa.sh      # 最省事：relink 很快，主要开销是 100ms 级
# 或只重打包：
cp -R www /tmp/plugintool-stage/Payload/PluginTool.app/
cd /tmp/plugintool-stage && rm -f dist.ipa && zip -qry dist.ipa Payload
```

## 坑（已处理）
1. `-adhoc_codesign` 必须带，否则 arm64 上 dyld 直接拒载。
2. `workspace` 在 fake fs 上，`chmod 755` 会被吃掉 → staging 放 `/tmp`，并在打包后用 Python 再确认 `external_attr == 0100755`。
3. 白图标闪退 = zip 里可执行不是 755；脚本第 5 步会硬校验并自动改写。

## App 里做了什么
- `WKWebView` 加载 bundle 内 `www/index.html`，file:// 直读，允许相对路径子资源。
- 注入 `window.pt(action, data) -> Promise`，原生动作：
  `hostInfo / sshCommand / pingSSH / deviceInfo / copy / paste / openURL / toast / vibrate / exitApp`
- 主机内置：`香港 165.99.43.34:22 root`，公钥 `id_ed25519`，指纹 `SHA256:UILGXdkSdzucU1CsN3OajdBr+73g5PvTsdtGMoZfwLg`
- 「连接」= 原生 socket（getaddrinfo + 非阻塞 connect + select）直连 22 端口并读 SSH banner，
  实测返回 `SSH-2.0-OpenSSH_10.2p1 Ubuntu-2ubuntu3.8`。

## 主机
```sh
sh keys/connect.sh                      # 一键登录
sh keys/install_pubkey.sh               # 幂等安装公钥（需已能登）
sh keys/install_pubkey.sh '<密码>'       # 只有密码时（主机需开 PasswordAuthentication）
```
