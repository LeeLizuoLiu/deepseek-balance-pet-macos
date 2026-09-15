#!/usr/bin/env bash
# build.sh — 把 BalancePet.swift 编译并组装成 DeepSeekBalancePet.app
#
#   ./build.sh              # 编译 + 组装 .app + 自检
#   ./build.sh --run        # 编译后直接启动
#   ./build.sh --install    # 额外拷贝到 ~/Applications
#
# 只需要 Xcode Command Line Tools（xcode-select --install），不需要 .NET、
# 不需要 Xcode 工程、不需要任何第三方依赖。

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$HERE/build"
APP="$BUILD_DIR/DeepSeekBalancePet.app"
BIN_NAME="DeepSeekBalancePet"
PNG="$HERE/assets/pet.png"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "error: 找不到 swiftc。请先安装 Xcode Command Line Tools：xcode-select --install" >&2
  exit 1
fi

if [[ ! -f "$PNG" ]]; then
  echo "error: 找不到人物立绘 $PNG" >&2
  exit 1
fi

echo "==> 清理 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 编译 BalancePet.swift"
# 默认的 clang 模块缓存写在 $TMPDIR/clang 下；在受限环境里那可能不可写，
# 会把编译错误伪装成「SDK is not supported by the compiler」。统一改到 build 目录。
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/.modulecache"
export SWIFT_MODULE_CACHE_PATH="$BUILD_DIR/.modulecache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

# -parse-as-library: 配合 @main 入口；-swift-version 5 避免 Swift 6 严格并发检查
swiftc \
  -O \
  -parse-as-library \
  -swift-version 5 \
  -module-cache-path "$BUILD_DIR/.modulecache" \
  -framework AppKit \
  -o "$APP/Contents/MacOS/$BIN_NAME" \
  "$HERE/BalancePet.swift"

echo "==> 组装 .app"
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"
cp "$PNG" "$APP/Contents/Resources/pet.png"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 临时签名：本机自用足够，避免 Gatekeeper 直接拦下未签名二进制
if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$APP" >/dev/null 2>&1 && echo "==> 已做 ad-hoc 签名" || echo "==> 跳过签名（不影响本机运行）"
fi

echo "==> 自检"
"$APP/Contents/MacOS/$BIN_NAME" --selftest

echo
echo "构建完成：$APP"
echo "  启动：open \"$APP\""
echo "  退出：右键挂件 → 退出（或 pkill -f $BIN_NAME）"

for arg in "$@"; do
  case "$arg" in
    --run)
      echo "==> 启动"
      open "$APP"
      ;;
    --install)
      mkdir -p "$HOME/Applications"
      rm -rf "$HOME/Applications/DeepSeekBalancePet.app"
      cp -R "$APP" "$HOME/Applications/"
      echo "==> 已安装到 ~/Applications/DeepSeekBalancePet.app"
      echo "    开机自启：系统设置 → 通用 → 登录项 → 添加这个 .app"
      ;;
  esac
done
