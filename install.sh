#!/usr/bin/env bash
# 月伴 Yueban · macOS 一键安装脚本
#
#   curl -fsSL https://raw.githubusercontent.com/xingqiyi-97/yueban/main/install.sh | bash
#
# 可选环境变量：
#   YUEBAN_REPO     仓库，默认 xingqiyi-97/yueban
#   INSTALL_DIR     安装位置，默认 /Applications（无权限时自动退回 ~/Applications）
#   YUEBAN_VERSION  指定版本，如 v1.0.0；默认最新版

set -euo pipefail

REPO="${YUEBAN_REPO:-xingqiyi-97/yueban}"
APP="月伴.app"
ZIP="月伴-Mac版.zip"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say() { printf '\033[1;36m==>\033[0m %s\n' "$1"; }
die() { printf '\033[1;31m✗\033[0m %s\n' "$1" >&2; exit 1; }

[[ "$(uname)" == "Darwin" ]] || die "月伴只支持 macOS"

# 选安装目录
DIR="${INSTALL_DIR:-/Applications}"
if [[ ! -w "$DIR" ]]; then
  DIR="$HOME/Applications"
  mkdir -p "$DIR"
  say "/Applications 不可写，改装到 $DIR"
fi

asset_url() {
  local api="https://api.github.com/repos/$REPO/releases/latest"
  [[ -n "${YUEBAN_VERSION:-}" ]] && api="https://api.github.com/repos/$REPO/releases/tags/$YUEBAN_VERSION"
  curl -fsSL "$api" \
    | grep -o '"browser_download_url":[[:space:]]*"[^"]*\.zip"' \
    | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//'
}

# 1) 优先拿已编译好的发布包
say "查找安装包的版本…"
URL="$(asset_url || true)"
if [[ -n "$URL" ]]; then
  say "下载 $URL"
  curl -fsSL "$URL" -o "$TMP/pkg.zip" || URL=""
fi

if [[ -n "$URL" ]]; then
  unzip -q "$TMP/pkg.zip" -d "$TMP/unz"
  SRC="$(find "$TMP/unz" -maxdepth 2 -name "$APP" -type d | head -1)"
  [[ -n "$SRC" ]] || die "压缩包结构异常，没找到 $APP"
else
  # 2) 没有发布包就从源码编译（需要 Xcode 命令行工具）
  say "没有现成安装包，改为从源码编译…"
  command -v swiftc >/dev/null 2>&1 || die "需要 Xcode 命令行工具，请先执行：xcode-select --install"
  curl -fsSL "https://github.com/$REPO/archive/refs/heads/main.tar.gz" -o "$TMP/src.tgz"
  mkdir -p "$TMP/src" && tar -xzf "$TMP/src.tgz" -C "$TMP/src" --strip-components=1
  ( cd "$TMP/src" && ./build.sh ) || die "编译失败"
  SRC="$TMP/src/$APP"
fi

# 3) 安装
say "安装到 $DIR"
pkill -f "Yueban" >/dev/null 2>&1 || true
rm -rf "$DIR/$APP"
cp -R "$SRC" "$DIR/$APP"

# 4) 去掉隔离标记（没有苹果开发者证书，否则首次打开会被拦）
xattr -dr com.apple.quarantine "$DIR/$APP" >/dev/null 2>&1 || true
codesign --force --deep -s - "$DIR/$APP" >/dev/null 2>&1 || true

say "完成！正在启动…"
open "$DIR/$APP"

cat <<EOF

  月伴已装好 🎀
  · 桌面左下角那只小猫就是它，可拖动
  · 双击 → 日历（点日期记录）；右键 → 更多（可用照片自定义形象）
  · 想卸载：rm -rf "$DIR/$APP"
EOF
