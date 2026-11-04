#!/usr/bin/env bash
# 构建 release 二进制并组装 build/Xup.app（含内置 CLI、config.schema.json、SKILL.md）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Xup"
# CLI 的 SwiftPM product 名。注意：macOS 默认文件系统不区分大小写，product 不能叫 "xup"
# （会与 "Xup" 的二进制/中间目录互相覆盖），因此 Package.swift 中的 CLI 目标/产品名为 xup-cli。
# 同理 CLI 不能放在 Contents/MacOS/xup（与 Contents/MacOS/Xup 同一文件），改放 Contents/Helpers/xup。
CLI_PRODUCT="${XUP_CLI_PRODUCT:-xup-cli}"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP/Contents"

echo "==> swift build -c release --product $APP_NAME"
swift build -c release --product "$APP_NAME"
echo "==> swift build -c release --product $CLI_PRODUCT"
swift build -c release --product "$CLI_PRODUCT"

BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"
CLI_BIN="$BIN_DIR/$CLI_PRODUCT"
if [[ ! -x "$BIN" ]]; then
  echo "找不到可执行文件: $BIN" >&2
  exit 1
fi
if [[ ! -x "$CLI_BIN" ]]; then
  echo "找不到 CLI 可执行文件: $CLI_BIN" >&2
  exit 1
fi

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Helpers" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/$APP_NAME"
cp "$CLI_BIN" "$CONTENTS/Helpers/xup"
cp "$ROOT/Support/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/Support/config.schema.json" "$CONTENTS/Resources/config.schema.json"
cp "$ROOT/Support/SKILL.md" "$CONTENTS/Resources/SKILL.md"
cp "$ROOT/Support/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
printf 'APPL????' > "$CONTENTS/PkgInfo"

# 签名：设置 XUP_SIGN_IDENTITY（如 "Developer ID Application: Xi Ming (A42PRR7Z3U)"）时用正式证书 +
# 强化运行时 + 时间戳 + entitlements；否则 ad-hoc。
if [[ -n "${XUP_SIGN_IDENTITY:-}" ]]; then
  echo "==> codesign (Developer ID: $XUP_SIGN_IDENTITY)"
  codesign --force --options runtime --timestamp --sign "$XUP_SIGN_IDENTITY" "$CONTENTS/Helpers/xup"
  codesign --force --options runtime --timestamp --entitlements "$ROOT/Support/Xup.entitlements" \
    --sign "$XUP_SIGN_IDENTITY" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
else
  echo "==> codesign (ad-hoc)"
  codesign --force --sign - "$CONTENTS/Helpers/xup"
  codesign --force --deep --sign - "$APP"
fi

echo "完成: $APP"
echo "CLI:  $CONTENTS/Helpers/xup"
