#!/bin/bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_BUNDLE="$ROOT_DIR/烂笔头.app"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
EXPECTED_BUNDLE_ID="com.ban1et.lanbitou"
EXPECTED_VERSION="1.0"
DMG_NAME="LanBiTou-${EXPECTED_VERSION}.dmg"
SHA_NAME="${DMG_NAME}.sha256"
DMG_PATH="$ROOT_DIR/$DMG_NAME"
SHA_PATH="$ROOT_DIR/$SHA_NAME"

die() {
  printf '错误：%s\n' "$1" >&2
  exit 1
}

[[ "$(uname -s)" == "Darwin" ]] || die "此脚本只能在 macOS 上运行。"
for command_name in codesign ditto hdiutil perl shasum; do
  command -v "$command_name" >/dev/null 2>&1 || die "缺少系统命令：$command_name"
done
[[ -x /usr/libexec/PlistBuddy ]] || die "找不到系统工具 PlistBuddy。"
[[ -d "$APP_BUNDLE" ]] || die "项目根目录中找不到烂笔头.app。"
[[ -f "$INFO_PLIST" ]] || die "应用缺少 Contents/Info.plist。"

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
[[ "$bundle_id" == "$EXPECTED_BUNDLE_ID" ]] || die "应用标识不符：期望 $EXPECTED_BUNDLE_ID，实际为 $bundle_id。"
[[ "$version" == "$EXPECTED_VERSION" ]] || die "应用版本不符：期望 $EXPECTED_VERSION，实际为 $version。"
codesign --verify --deep --strict "$APP_BUNDLE" || die "应用代码签名验证失败。"

if [[ -e "$DMG_PATH" || -L "$DMG_PATH" || -e "$SHA_PATH" || -L "$SHA_PATH" ]]; then
  die "目标 DMG 或 SHA-256 文件已存在；为避免覆盖，已停止。"
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lanbitou-dmg.XXXXXX")"
STAGING_DIR="$WORK_DIR/内容"
MOUNT_POINT="$WORK_DIR/挂载点"
TEMP_DMG="$WORK_DIR/$DMG_NAME"
TEMP_SHA="$WORK_DIR/$SHA_NAME"
MOUNTED=0
SUCCESS=0

cleanup() {
  local status=$?
  trap - EXIT
  if (( MOUNTED )); then
    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
  fi
  if (( ! SUCCESS )); then
    if [[ -e "$TEMP_SHA" && ( -e "$SHA_PATH" || -L "$SHA_PATH" ) && "$TEMP_SHA" -ef "$SHA_PATH" ]]; then
      rm -f "$SHA_PATH"
    fi
    if [[ -e "$TEMP_DMG" && ( -e "$DMG_PATH" || -L "$DMG_PATH" ) && "$TEMP_DMG" -ef "$DMG_PATH" ]]; then
      rm -f "$DMG_PATH"
    fi
  fi
  rm -rf "$WORK_DIR"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir "$STAGING_DIR" "$MOUNT_POINT"
ditto "$APP_BUNDLE" "$STAGING_DIR/烂笔头.app"
ln -s /Applications "$STAGING_DIR/Applications"
cat > "$STAGING_DIR/安装说明.txt" <<'EOF'
烂笔头 macOS 安装说明

1. 将“烂笔头.app”拖到“Applications”图标上，等待复制完成。
2. 退出此磁盘映像，然后从“应用程序”文件夹打开“烂笔头”。

此版本使用本机 ad-hoc 签名，未使用 Apple Developer ID 签名，也未经过 Apple 公证。macOS 可能会阻止首次打开。
如果你确认应用来自烂笔头官方 GitHub 发布页，可在苹果菜单 >“系统设置”>“隐私与安全性”中查看安全提示，并选择“仍要打开”授权。
Apple 官方说明：https://support.apple.com/en-us/102445
EOF

hdiutil create \
  -volname "烂笔头 $EXPECTED_VERSION" \
  -srcfolder "$STAGING_DIR" \
  -format UDZO \
  -fs HFS+ \
  "$TEMP_DMG" >/dev/null
hdiutil verify "$TEMP_DMG" >/dev/null

hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_POINT" "$TEMP_DMG" >/dev/null
MOUNTED=1
[[ -d "$MOUNT_POINT/烂笔头.app" ]] || die "DMG 中缺少烂笔头.app。"
[[ -L "$MOUNT_POINT/Applications" ]] || die "DMG 中缺少 Applications 快捷方式。"
[[ "$(readlink "$MOUNT_POINT/Applications")" == "/Applications" ]] || die "Applications 快捷方式目标不正确。"
[[ -f "$MOUNT_POINT/安装说明.txt" ]] || die "DMG 中缺少中文安装说明。"
codesign --verify --deep --strict "$MOUNT_POINT/烂笔头.app" || die "DMG 中应用的代码签名验证失败。"
hdiutil detach "$MOUNT_POINT" >/dev/null
MOUNTED=0

digest="$(shasum -a 256 "$TEMP_DMG" | awk '{print $1}')"
printf '%s  %s\n' "$digest" "$DMG_NAME" > "$TEMP_SHA"

if [[ -e "$DMG_PATH" || -L "$DMG_PATH" || -e "$SHA_PATH" || -L "$SHA_PATH" ]]; then
  die "目标 DMG 或 SHA-256 文件已存在；为避免覆盖，已停止。"
fi

link_for_publication() {
  perl -e '
    use Errno qw(EXDEV);
    my ($source, $destination) = @ARGV;
    if (!link($source, $destination)) {
      my $error_number = 0 + $!;
      my $error_message = "$!";
      if ($error_number == EXDEV) {
        print STDERR "错误：系统临时目录与项目目录不在同一文件系统，无法安全发布；不会复制文件。请调整 TMPDIR 后重试。\n";
      } else {
        print STDERR "错误：无法安全发布文件：$error_message\n";
      }
      exit 1;
    }
  ' "$1" "$2"
}

link_for_publication "$TEMP_DMG" "$DMG_PATH"
link_for_publication "$TEMP_SHA" "$SHA_PATH"
SUCCESS=1

printf '已生成：%s\n' "$DMG_PATH"
printf '校验文件：%s\n' "$SHA_PATH"
