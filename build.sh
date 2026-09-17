#!/bin/zsh
# 月伴 · 构建脚本
#   ./build.sh                     默认构建通用版（Apple 芯片 + Intel 都能跑）
#   BUILD_ARCH=native ./build.sh   只构建当前机器架构（开发迭代更快）
set -e
cd "$(dirname "$0")"

APP="月伴.app"
TMP=".build"
rm -rf "$TMP"; mkdir -p "$TMP"
rm -f build_errors.log

compile() {  # $1=架构
    echo "==> 编译 $1"
    if ! swiftc -O -swift-version 5 -target "$1-apple-macosx11.0" \
         main.swift -o "$TMP/Yueban_$1" 2>>build_errors.log; then
        echo "✗ 编译失败（$1）："; grep "error:" build_errors.log | head -30; exit 1
    fi
}

if [ "${BUILD_ARCH:-universal}" = "native" ]; then
    A=$(uname -m)
    compile "$A"
    cp "$TMP/Yueban_$A" Yueban
else
    compile arm64
    compile x86_64
    echo "==> 合并为通用二进制"
    lipo -create -output Yueban "$TMP/Yueban_arm64" "$TMP/Yueban_x86_64"
fi

if grep -q "error:" build_errors.log 2>/dev/null; then
    echo "⚠ 编译错误："; grep "error:" build_errors.log | head -30; exit 1
fi
rm -f build_errors.log
rm -rf "$TMP"

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Yueban "$APP/Contents/MacOS/Yueban"
cp Info.plist "$APP/Contents/Info.plist"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep -s - "$APP" 2>/dev/null || true

echo "==> 完成: $(pwd)/$APP ($(lipo -info "$APP/Contents/MacOS/Yueban" | sed 's/.*architecture: //'))"
