#!/bin/sh
# build_apk.sh —— aiwli 工程构建入口（arm64 debug）
#
# 关键环境（这台设备实测沉淀）：
#  - rust 引擎由 cargokit 编译（aarch64-linux-android，git2 vendored libgit2）
#  - CARGO_NET_OFFLINE=true：124 个 crate 已在本地 registry——这台设备对 crates.io
#    间歇性 SSL reset（cargo 客户端被掐、curl 官方 API 能过），离线模式是唯一稳定路径
#  - CARGO_TARGET_DIR / CARGOKIT_TARGET_TEMP_DIR 指向 /tmp：FUSE 不支持 cargo
#    硬链接（failed to link or copy），构建产物必须落 rootfs
#  - gradlew 拷 /tmp 加执行位再 bind 回来（FUSE chmod 假成功，技能已载）
set -eu
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
NAME=$(basename "$PROJ")
GRADLEW_SRC="/root/${NAME}_gradlew"

. /opt/taixu-flutter-env.sh

# JDK21（AGP 8.11.1 + Kotlin 2.2.x 配置，taixu 默认 17 不够）
JDK21=/opt/jdk21/usr/lib/jvm/java-21-openjdk-arm64
if [ -x "$JDK21/bin/javac" ]; then export JAVA_HOME="$JDK21"; export PATH="$JAVA_HOME/bin:$PATH"; fi
export PATH="$HOME/.cargo/bin:$PATH"
export CARGO_NET_OFFLINE=true
export CARGO_TARGET_DIR=/tmp/gitdeck-target
export CARGOKIT_TARGET_TEMP_DIR=/tmp/gitdeck-cargokit-target

is_mounted() { grep -qs " $1 " /proc/mounts; }
if ! is_mounted "$PROJ/android/gradlew"; then
    cp "$PROJ/android/gradlew" "$GRADLEW_SRC"
    chmod +x "$GRADLEW_SRC"
    mount --bind "$GRADLEW_SRC" "$PROJ/android/gradlew"
fi

# cargokit 的 run_build_tool.sh 同样 FUSE x 位假成功 → bind 回来
RBT_SRC="/root/${NAME}_run_build_tool.sh"
if ! is_mounted "$PROJ/rust_builder/cargokit/run_build_tool.sh"; then
    cp "$PROJ/rust_builder/cargokit/run_build_tool.sh" "$RBT_SRC"
    chmod +x "$RBT_SRC"
    mount --bind "$RBT_SRC" "$PROJ/rust_builder/cargokit/run_build_tool.sh"
fi

cd "$PROJ"
flutter pub get >/dev/null 2>&1 || flutter pub get

# release 构建（2026-09-30 qemu 死刑后改走 box64 透传 x64 gen_snapshot——见 skill 第 7 条；
# gen_snapshot shim 在 /opt/flutter/.../linux-arm64/gen_snapshot，exec box64 + x64 原版。
# abiFilters=arm64-v8a 已限，gradle 已配 debug 签名可直接装）
flutter build apk --release --target-platform android-arm64

APK="$PROJ/build/app/outputs/flutter-apk/app-release.apk"
VER=$(grep -oP '^version:\s*\K[0-9.]+' "$PROJ/pubspec.yaml" 2>/dev/null | cut -d+ -f1 || echo rel)
mkdir -p /mounts/Projects/apks
cp "$APK" "/mounts/Projects/apks/aiwli_v${VER}-release.apk"
echo "OK -> /mounts/Projects/apks/aiwli_v${VER}-release.apk"
sha256sum "$APK"
