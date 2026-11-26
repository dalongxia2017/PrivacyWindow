#!/bin/bash
# 构建 PrivacyWindow.app。只依赖 Xcode Command Line Tools（swiftc），不需要 Xcode。
#
#   ./build.sh            构建
#   ./build.sh test       构建并运行自检
#   ./build.sh run        构建并启动
#   ./build.sh dist       构建 + ad-hoc 签名 + 打包 zip
#   ./build.sh clean
set -euo pipefail

cd "$(dirname "$0")"

APP="build/PrivacyWindow.app"
CONTENTS="$APP/Contents"
BIN="$CONTENTS/MacOS/PrivacyWindow"
MIN_MACOS="14.0"
# 本机沙盒不允许写默认的模块缓存目录，所以指到项目里的 build/ 下。
CACHE_FLAGS=(-module-cache-path build/mcache -clang-scanner-module-cache-path build/mcache/clang)

build() {
	mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" build/mcache
	cp Info.plist "$CONTENTS/Info.plist"
	if [ -f Resources/AppIcon.icns ]; then
		cp Resources/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"
	fi
	local arch
	arch="$(uname -m)"
	local sources
	sources=(Sources/*.swift)
	swiftc \
		-swift-version 5 \
		-target "${arch}-apple-macosx${MIN_MACOS}" \
		-sdk "$(xcrun --show-sdk-path)" \
		-O \
		"${CACHE_FLAGS[@]}" \
		-o "$BIN" \
		"${sources[@]}" 2> build/build.log || {
		grep -E "error:" build/build.log || true
		echo "编译失败，完整日志：build/build.log" >&2
		return 1
	}
	if grep -q "warning:" build/build.log; then
		grep -E "warning:" build/build.log | head -20 || true
	fi
}

test() {
	"$BIN" --selftest
}

sign() {
	codesign --force --sign - --timestamp=none "$APP"
}

dist() {
	build
	sign
	rm -f build/PrivacyWindow.zip
	ditto -c -k --keepParent "$APP" build/PrivacyWindow.zip
	echo "已生成 build/PrivacyWindow.zip"
}

case "${1:-build}" in
build)
	build
	echo "已生成 $APP"
	;;
test)
	build && test
	;;
run)
	build && open "$APP"
	;;
dist)
	dist
	;;
clean)
	rm -rf build
	;;
*)
	echo "用法: $0 [build|test|run|dist|clean]" >&2
	exit 2
	;;
esac
