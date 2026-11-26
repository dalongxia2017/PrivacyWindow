#!/bin/bash
# 构建 PrivacyWindow.app。只依赖 Xcode Command Line Tools（swiftc），不需要 Xcode。
#
#   ./build.sh            构建
#   ./build.sh test       构建并运行自检
#   ./build.sh run        构建并启动
#   ./build.sh dist       构建 + ad-hoc 签名 + 打包 zip
#   ./build.sh dmg        构建 + ad-hoc 签名 + 打包 dmg（带「应用程序」快捷方式）
#   ./build.sh clean
set -euo pipefail

cd "$(dirname "$0")"

APP="build/PrivacyWindow.app"
DMG="build/PrivacyWindow.dmg"
VOL="PrivacyWindow"
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

dmg() {
	build
	sign
	# 这台机器的沙盒里 `hdiutil create` 一律报“目錄不是空的”，也不能写 /Volumes，`diskutil image` 可以用。
	# 所以走：空白可读写镜像 → 挂到项目目录内 → 拷入 App 和「应用程序」快捷方式 → 卸载 → 转成压缩只读镜像。
	local rw mnt
	rw="build/PrivacyWindow-rw.dmg"
	mnt="$PWD/build/dmg-mount"
	rm -f "$DMG" "$rw"
	mkdir -p "$mnt"
	diskutil image create blank "$rw" --size 40m --fs APFS --volname "$VOL" >/dev/null
	# 挂上以后无论成败都要卸载，否则会留下一个 40 MB 的空盘
	trap 'hdiutil detach "$mnt" >/dev/null 2>&1 || true; rm -rf "$mnt"' RETURN
	diskutil image attach "$rw" --mountPoint "$mnt" >/dev/null
	ditto "$APP" "$mnt/PrivacyWindow.app"
	ln -s /Applications "$mnt/Applications"
	hdiutil detach "$mnt" >/dev/null
	trap - RETURN
	rmdir "$mnt"
	diskutil image create from "$rw" "$DMG" --format UDZO >/dev/null
	rm -f "$rw"
	# hdiutil verify 会把镜像挂在 /Volumes/<卷名> 下不弹出，验完要自己卸掉，否则留一个盘在桌面上
	trap 'hdiutil detach "/Volumes/$VOL" >/dev/null 2>&1 || true' RETURN
	hdiutil verify -quiet "$DMG"
	trap - RETURN
	echo "已生成 $DMG"
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
dmg)
	dmg
	;;
clean)
	rm -rf build
	;;
*)
	echo "用法: $0 [build|test|run|dist|dmg|clean]" >&2
	exit 2
	;;
esac
