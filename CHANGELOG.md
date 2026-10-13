# Changelog

All notable changes to this project are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.0.0] — 首个公开版本

> 1.0.0.0+1。Flutter + Rust(libgit2) 跨平台 Git 客户端，Android / iOS / Windows / macOS / Linux 五端一个代码库。
>
> 版本策略：正式发布用前三位（major.minor.patch，按功能大中小递增）；开发构建在第四位递增（`v1.0.0.1`、`v1.0.0.2`…），发布资产名与 App 内显示版本跟随 tag（Android 除外，见工程化备注）。Android versionCode 由 pubspec 的 `+N` 单调递增，与显示版本解耦。

### 核心（本地仓库）

- 状态 / 暂存 / 提交 / 撤销，逐 hunk 暂存与丢弃
- 分支 / 合并 / rebase / cherry-pick / 标签 / stash，冲突标记与解决
- 历史检索、blame 逐行追溯、提交详情与差异
- 仓库发现三入口：本地扫描（按平台解析标准目录）/ 全平台目录选择（file_picker，五端一个 API）/ 远程导入克隆

### 远程与托管平台

- fetch / pull / push（含 force），多远程管理
- HTTPS 凭据与 SSH 密钥管理，TLS 自定义 CA 导入
- GitHub / GitLab / 云效 Codeup 账号绑定：OAuth 设备流 + 内嵌网页登录自动绑定
- issue / PR 读写、release 列表与删除、仓库设置（可见性/描述/主页）

### AI 集成

- 本机 MCP 服务器（localhost）：把 git 引擎与托管平台能力以工具形式暴露给 AI 客户端（如 Kelivo），含仓库读写、GitHub/GitLab/Codeup 全套操作

### 打包与多架构

- **Android 三架构发版**：Rust 引擎（libgit2/openssl/libssh2/icu 链）交叉编译出
  armeabi-v7a（6.7MB）与 x86_64（8.9MB）预编译 `.so` 补入 jniLibs，与 arm64
  同源可复现；CI `--split-per-abi` 出三个 APK，资产命名
  `android-arm64 / android-armv7 / android-x86_64`。v7a 包已在 arm64 真机冒烟
  验证（Rust 引擎启动加载 + 运行正常）；x86_64 包过 AOT 配对闸门（模拟器 /
  Chromebook 场景待实测反馈）。
- **Linux arm64 发版**：linux job 矩阵化（x64 + arm64），arm64 跑 GitHub 免费
  `ubuntu-24.04-arm` runner；Flutter 官方无 linux-arm64 SDK archive（releases
  清单实证为零），arm64 侧改 git tag 引导（3.47.1，与 x64 同版本）；产物
  tar.gz + deb（AppImage 工具链不成熟，仍仅 x64）。
- **Windows 安装器**：Inno Setup 打包 `aiwli-git-windows-setup.exe`（开始菜单 +
  桌面快捷方式、卸载支持），与裸 zip 并存，对标 Kelivo/ProxyPin/Karing 的
  setup.exe。
- **Linux rpm**：fpm 从 deb 同一套 staging 树打 rpm（x64→x86_64 / arm64→aarch64），
  覆盖 Fedora/openSUSE 用户。
- **macOS universal**：`flutter build macos --release` 默认 ARCHS_STANDARD 产出
  已含双架构的 universal 二进制；CI 先 `lipo -info` 验证，已是 universal 直接
  打包，仅 arm64 时才降级双构建合并（x64 切片经 Rosetta 自举 + lipo 合并全部
  Mach-O + 重签 ad-hoc）。资产 `macos-universal`（dmg+zip），老 Intel Mac 也可
  运行；体积约 +60-90%（代码段双份，资源不变）。

### 修复

- 错误提示：macOS 隐私授权（TCC）拒绝文件夹访问时，libgit2 会把 EPERM 吞进
  "could not find repository" 被误报成「找不到仓库或文件」——新增权限拒绝桶
  （排在 not-found 之前），提示到系统设置授权。
- rpm 打包：fpm 输出文件名带 release 号后缀（`aiwli-git-1.0.0.0-1.x86_64.rpm`），
  mv 改 glob 匹配；`--after-install` 要脚本文件路径，内联命令被当文件读 →
  改写 /tmp 脚本再传路径。
- macOS 产物上传路径残留 /tmp（Package 已改产在 build/ 下）→ 修正路径。
- Windows setup.exe：Inno 的 OutputDir 相对于 .iss 所在目录（windows/）而非
  工作区根 → ISCC 后定位归位。
- `android/app/build.gradle.kts` 移除写死的 `ndk.abiFilters += arm64-v8a`
  （与 `--split-per-abi` 的 splits 配置冲突）。

### 工程化

- Flutter AOT + Rust FFI：cargokit 现场编译 libgit2 / openssl / libssh2，无预编译二进制入库
- CI 五端产物：android 三架构 apk / ios-arm64.ipa（未签名）/ windows
  setup.exe+zip / macos-universal dmg+zip / linux-x64（tar.gz+deb+rpm+AppImage）
  + linux-arm64（tar.gz+deb）
- 静态分析零告警 + 141 项测试
- **Android 暂不跟随 tag 版本**：`--build-name` 与 `flutter build apk
  --split-per-abi` 组合会导致 assembleRelease 失败（其余平台无此问题，gradle
  插件源码未见解析点，待上游排查）；Android 包内显示版本暂为 pubspec 的
  1.0.0，资产名与发布号仍跟随 tag。
