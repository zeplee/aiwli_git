#!/bin/sh
# install_apk.sh —— 装机 + 补回「所有文件访问」权限（需 root）
#
# 背景 1：`pm install -r` 更新安装会把 MANAGE_EXTERNAL_STORAGE 的 app-op
# 重置为 default，应用随即无法读 /storage/emulated/0 下的仓库
# （表现：读取 HEAD 失败: ... Permission denied; code=Locked (-14)）。
# 本脚本装机后自动补授权，避免每次更新都要手动去系统设置点一遍。
#
# 背景 2（2026-10-07 实测踩到，必读）：**不能直接从 /storage/emulated/0 装**。
# 那下面是 FUSE，system_server 读不了，pm install 会直接失败：
#   avc: denied { read } for scontext=u:r:system_server:s0
#        tcontext=u:object_r:fuse:s0 tclass=file permissive=0
#   Error: Can't open file: /storage/emulated/0/.../aiwli_vX.Y.Z-release.apk
# 系统自己给的提示就是 "Consider using a file under /data/local/tmp/"。
# 所以这里先把 APK 拷到 /data/local/tmp 再装（装完即删）。
#
# 用法：su -c 'sh scripts/install_apk.sh [apk路径]'
set -eu
PKG=com.aiwli.git
APK="${1:-$(ls -t /storage/emulated/0/Projects/apks/aiwli_v*-release.apk | head -1)}"

echo "安装: $APK"
# FUSE 上的 APK 过不了 system_server 的 SELinux 检查，先落到 /data/local/tmp
STAGE="/data/local/tmp/$(basename "$APK")"
cp "$APK" "$STAGE"
chmod 644 "$STAGE"
pm install -r --user 0 "$STAGE" >/dev/null
rm -f "$STAGE"

# 更新安装重置了 app-op，这里补回「所有文件访问」
appops set "$PKG" MANAGE_EXTERNAL_STORAGE allow
echo -n "MANAGE_EXTERNAL_STORAGE: "
appops get "$PKG" MANAGE_EXTERNAL_STORAGE

echo -n "版本: "
dumpsys package "$PKG" 2>/dev/null | grep -m1 versionName | tr -d ' '

am force-stop "$PKG"
sleep 1
monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 3
echo "完成（进程: $(pidof "$PKG" || echo 未启动)）"
