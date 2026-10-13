#!/bin/sh
# rebuild_rust_so.sh —— 重编 librust_lib_gitdeck.so（B 路线：手动 cargokit build-gradle）
#
# 背景：gradle 侧的 cargokit 插件已摘除（见 rust_builder/android/build.gradle 注释），
# 改用预编译产物 rust_builder/android/src/main/jniLibs/arm64-v8a/librust_lib_gitdeck.so。
# 本脚本用与当初产出该 .so 相同的一套 CARGOKIT_* 环境，手工跑一次 cargokit
# 的 build-gradle，把 .so 落到指定目录（默认 /tmp/rbc-out/arm64-v8a/）。
#
# 用法：
#   sh scripts/rebuild_rust_so.sh                  # 编到 /tmp/rbc-out
#   sh scripts/rebuild_rust_so.sh /tmp/xyz         # 编到指定目录
#   INSTALL=1 sh scripts/rebuild_rust_so.sh        # 编完并落 jniLibs（打印前/后 sha256）
#
# 为什么是这套 env / 这些固定路径（本机实测踩过的坑，改任一项字节就变）：
#  1) CARGOKIT_TARGET_TEMP_DIR 固定 /tmp/gitdeck-cargokit-target
#     - 该路径会被写进产物（libssl 的 ENGINESDIR/MODULESDIR 等），换路径 = 换字节；
#     - openssl-sys / libgit2-sys / libssh2-sys 的已编译 C 依赖缓存在这里，
#       不重建 C 依赖，只重编 + 重链 rust 侧。
#  2) /tmp/cargokit-ndk-shim（cargokit 每次构建自建的确定性 shim）
#     - cargokit 把 CC_aarch64-linux-android 指到 shim 里的 clang，OpenSSL 的
#       `compiler:` 字符串嵌的就是这个路径；shim 符号链到 NDK 的 linux-x86_64 clang。
#  3) CARGO_NET_OFFLINE=true —— 本机对 crates.io 间歇 SSL reset，离线是唯一稳路径。
#  4) FUSE 上 run_build_tool.sh 的 x 位是假的，而 rustc 直接 exec 它当 linker
#     （cargokit 的 CARGO_TARGET_*_LINKER 指的就是该脚本）→ 拷到 rootfs 加执行位再
#     bind 回来，和 scripts/build_apk.sh 同一招。
#
#  5) CARGOKIT_TARGET_PLATFORMS 要写 Flutter 平台名 android-arm64，不是 ABI 名
#     arm64-v8a —— 后者会在 build_gradle.dart 的 Target.forFlutterName 直接抛异常
#     （异常信息还是误导人的 Missing environment variable CARGOKIT_DARWIN_PLATFORM_NAME）。
#
# 注意：rust/ 源码一改，产物 hash 必然变（这是对的）。脚本保证的是「同一份源码
# 能复现同一份字节」，以及把「重编 → 落 jniLibs」这条链路变成一条命令。
set -eu

PROJ="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-/tmp/rbc-out}"
INSTALL="${INSTALL:-0}"

NDK_VERSION=29.0.14206865          # /opt/android-sdk/ndk/ 下唯一版本，也是产物里嵌的那个
TARGET_TEMP=/tmp/gitdeck-cargokit-target
CARGOKIT_DIR="$PROJ/rust_builder/cargokit"
RBT="$CARGOKIT_DIR/run_build_tool.sh"
JNILIBS="$PROJ/rust_builder/android/src/main/jniLibs/arm64-v8a/librust_lib_gitdeck.so"
# 首次产出并已入库的那份（jniLibs 在 da8cef5 里；源码未改时应逐字节命中）
PINNED_SHA=7372dbfdada0e61e1a832c8d68d851db6eb40e7b3b36e09e4f9030657313f132

. /opt/taixu-flutter-env.sh
export FLUTTER_ROOT="${FLUTTER_HOME:-/opt/flutter}"   # run_build_tool.sh 用它取 dart-sdk
JDK21=/opt/jdk21/usr/lib/jvm/java-21-openjdk-arm64
if [ -x "$JDK21/bin/javac" ]; then export JAVA_HOME="$JDK21"; export PATH="$JAVA_HOME/bin:$PATH"; fi
export PATH="$HOME/.cargo/bin:$PATH"
export CARGO_NET_OFFLINE=true
# 冷编译（从零）要字节复现，必须钉住 OpenSSL 写进 buildinf 的 "built on" 时间戳：
# openssl 3.6.3 的 util/mkbuildinf.pl 优先取 SOURCE_DATE_EPOCH，缺省才用当前时间。
# 默认值 = 首次入库那次 C 编译的时间（Mon Oct  5 16:01:17 2026 UTC）。
# 缓存命中（C 层不重编）时它不影响任何字节；只在冷编译时有意义。
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1791216077}"

# --- FUSE x 位兜底：把 run_build_tool.sh 真执行位化 -------------------------
RBT_COPY="/root/$(basename "$PROJ")_rbt_exec.sh"
if [ ! -x "$RBT" ]; then
    cp "$RBT" "$RBT_COPY"
    chmod +x "$RBT_COPY"
    mount --bind "$RBT_COPY" "$RBT"
    echo "[i] run_build_tool.sh 不可执行 → 已 bind $RBT_COPY"
fi

mkdir -p "$OUT"
rm -f "$OUT/arm64-v8a/librust_lib_gitdeck.so"

echo "[i] out      : $OUT"
echo "[i] targetdir: $TARGET_TEMP"
T0=$(date +%s)

env \
  CARGOKIT_ROOT_PROJECT_DIR="$PROJ" \
  CARGOKIT_MANIFEST_DIR="$PROJ/rust" \
  CARGOKIT_CONFIGURATION=release \
  CARGOKIT_TARGET_TEMP_DIR="$TARGET_TEMP" \
  CARGOKIT_TOOL_TEMP_DIR="$TARGET_TEMP" \
  CARGOKIT_OUTPUT_DIR="$OUT" \
  CARGOKIT_NDK_VERSION="$NDK_VERSION" \
  CARGOKIT_SDK_DIR=/opt/android-sdk \
  CARGOKIT_COMPILE_SDK_VERSION=36 \
  CARGOKIT_MIN_SDK_VERSION=21 \
  CARGOKIT_TARGET_PLATFORMS=android-arm64 \
  CARGOKIT_JAVA_HOME="$JAVA_HOME" \
  "$RBT" build-gradle

SO="$OUT/arm64-v8a/librust_lib_gitdeck.so"
[ -f "$SO" ] || { echo "[!] 没产出 $SO"; exit 1; }
T1=$(date +%s)

SHA=$(sha256sum "$SO" | cut -d' ' -f1)
SZ=$(stat -c%s "$SO")
echo "[i] 耗时     : $((T1 - T0))s"
echo "[i] 产物     : $SO"
echo "[i] sha256   : $SHA"
echo "[i] size     : $SZ"
if [ "$SHA" = "$PINNED_SHA" ]; then
    echo "[✓] 与入库版逐字节一致（源码未改）"
else
    echo "[!] 与入库版不同 —— 若改过 rust/ 源码属正常；否则先查上面 4 条固定路径"
fi

if [ "$INSTALL" = "1" ]; then
    OLD=$( [ -f "$JNILIBS" ] && sha256sum "$JNILIBS" | cut -d' ' -f1 || echo none )
    cp "$SO" "$JNILIBS"
    echo "[i] jniLibs  : $OLD -> $SHA"
    echo "[i] 记得提交该二进制：git add rust_builder/android/src/main/jniLibs/arm64-v8a/librust_lib_gitdeck.so"
fi