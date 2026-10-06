#!/bin/sh
# 兼容旧构建入口，现在生成包含桌面小组件的完整本机版本。
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$project_dir/build-widget.sh"
