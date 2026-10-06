#!/bin/sh
# 为当前 Mac 构建包含原生 WidgetKit 小组件的本机版本。
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
output="$project_dir/烂笔头.app"
running_status=0
pgrep -x '烂笔头' >/dev/null || running_status=$?
case "$running_status" in
  0) echo '请先退出烂笔头应用，再重新构建。' >&2; exit 1 ;;
  1) ;;
  *) echo '无法检查应用是否运行，已停止构建，未覆盖现有应用。' >&2; exit 1 ;;
esac
if [ -e "$output" ]; then
  bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$output/Contents/Info.plist")
  if [ "$bundle_id" != 'com.ban1et.lanbitou' ]; then
    echo '输出位置已有其他应用，已停止，未覆盖。' >&2
    exit 1
  fi
fi
build_dir=$(mktemp -d /tmp/lanbitou-widget.XXXXXX)
installed=0
cleanup() {
  if [ "$installed" -eq 0 ] && [ -d "$build_dir/previous.app" ]; then
    if [ -e "$output" ]; then mv "$output" "$build_dir/failed.app"; fi
    mv "$build_dir/previous.app" "$output"
    /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f "$output" >/dev/null 2>&1 || true
    pluginkit -a "$output/Contents/PlugIns/LanBiTouWidget.appex" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$build_dir"
}
trap cleanup EXIT HUP INT TERM
xcodebuild -project "$project_dir/LanBiTou.xcodeproj" -scheme LanBiTou \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath "$build_dir" \
  CODE_SIGNING_ALLOWED=NO ENABLE_DEBUG_DYLIB=NO \
  LANBITOU_ICLOUD_ENABLED=NO \
  LANBITOU_APP_GROUP=com.ban1et.lanbitou.preview.data \
  'LANBITOU_WIDGET_SNAPSHOT_PATH=Library/Application Support/com.ban1et.lanbitou/widget-reminders.json' \
  build > "$build_dir/build.log" 2>&1 || {
    cat "$build_dir/build.log" >&2
    exit 1
  }
product="$build_dir/Build/Products/Debug/烂笔头.app"
extension="$product/Contents/PlugIns/LanBiTouWidget.appex"
# 保留 Widget 沙盒，只授权它读取本应用的单个数据快照文件。
codesign --force --sign - --entitlements "$project_dir/Widget/LanBiTouWidgetLocal.entitlements" "$extension"
codesign --force --sign - "$product"
codesign --verify --deep --strict "$product"
if [ -e "$output" ]; then mv "$output" "$build_dir/previous.app"; fi
ditto "$product" "$output"
codesign --verify --deep --strict "$output"
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f "$output"
pluginkit -a "$output/Contents/PlugIns/LanBiTouWidget.appex"
installed=1
echo "已生成：$output"
echo '打开应用后，桌面右键 → 编辑小组件 → 烂笔头，即可添加。'
