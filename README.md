# aiwli

A complete Git client for your phone — desktop-grade, comparable to SourceTree / IDEA.
Built with Flutter + Rust (libgit2) on a single-dispatcher FFI architecture: one Rust engine
(`gitdeck_call(method, json)`) drives the entire UI. Android / macOS / Windows / Linux from
one codebase (iOS code path ready; no community iOS build under AGPL-3.0).

## Features

- **Workbench** — 3-way changes (staged / unstaged / untracked), file-level **and block-level** staging / discard, commit + amend, conflict resolution (ours / theirs / manual)
- **Diff** — unified view and **side-by-side** split (auto on wide screens, one-tap toggle)
- **Repo sidebar** — a pure repo directory: all repos in one column, long-press drag to reorder (persisted), one-tap auto-detect rescan, add repo via local scan or cloud import; docked on wide screens, edge drawer on phones
- **History** — colored commit tree (lane rendering), branch/tag decorations, search, infinite scroll, per-commit actions (tag / branch / checkout / cherry-pick / revert / reset)
- **Branches** — local / remote / tags, ahead-behind, switch / merge / rename / delete, checkout remote branch as local
- **Stash** — pop / apply / drop, one-tap stash including untracked files
- **Remotes** — fetch / push (multi-remote) / force-push with confirmation / pull, remote CRUD, credentials (HTTPS tokens / SSH key paths), user.name/email, .gitignore
- **SSH known_hosts** — first-connect trust dialog with fingerprint comparison, key-change alerts
- **Hosting accounts** — GitHub / GitLab / Alibaba Cloud Codeup binding with encrypted tokens, connection test, GitHub OAuth device flow, automatic credential matching by remote URL
- **Cloud repo import** — list your account's repos and clone in one tap
- **MCP server** — AI tools drive the same engine over HTTP (git_accounts / git_cloud_repos included)
- **Clone & multi-repo** — clone by URL (branch, credentials), persisted repo list with instant switching

## Quality & release

- `flutter analyze`: 0 issues; 41 Dart tests (URL/hosting API parsing, diff split, prefs, navigation, sidebar contracts)
- Rust unit tests: known_hosts parsing, host key comparison, base64 (`cd rust && cargo test`)
- CI: `.github/workflows/ci.yml` (analyze + test / cargo test / release APK artifacts)
- Release signing: `android/key.properties` (gitignored) points to `gitdeck-release.jks` outside the repo; falls back to debug signing when absent

## Architecture

```
lib/
  engine/ffi.dart      platform-aware loader (.so/.dylib/.dll + iOS static) + typed helpers
  core/prefs.dart      JSON preferences (recent repos, credentials)
  pages/               workbench / history / branches / stash / remotes / launcher
  widgets/             diff views (block ops) / commit details / dialogs
rust/
  src/api/dispatch.rs  single FFI entry gitdeck_call(method, json)
  src/api/*.rs         git_engine / ops_branch / ops_history / ops_stash / ops_remote / ops_patch / util
```

Adding an engine operation = one match arm in `dispatch.rs` + one Dart helper.

## Building

Rust uses git2 with default features (https + ssh) + vendored-libgit2 + vendored-openssl
(built statically from source; artifacts only depend on the system libc).
Requires NDK, perl, cmake, make, gcc.

```sh
flutter pub get
flutter test
cd rust && cargo test --release && cd ..
flutter build apk --release   # Android
```

Same source builds on all platforms — `ffi.dart` picks the library name per platform; iOS is
statically linked (`DynamicLibrary.process()`). Platform notes in the Chinese section below.

## License

Copyright © 2026 Aiwli.

This program is free software: you can redistribute it and/or modify it under the terms of
the **GNU Affero General Public License, either version 3 of the License, or (at your option) any
later version** (AGPL-3.0-or-later), as published by the Free Software Foundation — see
[LICENSE](LICENSE).

This program is distributed in the hope that it will be useful, but **WITHOUT ANY WARRANTY**;
without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
See the GNU General Public License for more details.

**Copyleft — what it means for forks**: if you distribute this app, or anything derived from
or embedding it, you must release the whole combination under the same licence and give
recipients the **complete corresponding source**. Shipping it as closed source is not an option.
Private, internal use without distribution triggers no obligation at all.

**Trademark notice**: the name "aiwli", its logo, and related branding are **not** covered by
the AGPL-3.0 licence. Forks and redistributions must rename the app and replace its artwork.

Third-party components: [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

---

# aiwli（中文）

手机上的完整 Git 客户端（对标桌面 SourceTree / IDEA），Flutter + Rust（libgit2）单调度器架构。

## 功能

- **工作台**：变更三分区（暂存/未暂存/未跟踪）、文件级与**块级**暂存/取消/丢弃、提交 + amend、冲突解决（我方/对方/手工）、合并完成/中止
- **Diff**：统一视图 / **左右对照分栏**（行号 + 增删底色，宽屏自动可用，一键切换）
- **仓库侧边栏**：纯仓库目录——全部仓库平铺一列、**长按拖动手动排序**（持久化）、头部「自动检测」一键重扫标准目录、＋添加仓库（扫描本地/云端导入）；宽屏常驻，手机为抽屉
- **导航**：工作台即唯一主页；无仓库时空态自带扫描/云端导入；无底部 tab
- **历史**：彩色提交树（lane 渲染）、分支/标签装饰、搜索、无限加载、提交详情 + ⋮ 菜单（打标签/建分支/检出/cherry-pick/revert/reset）
- **分支页**：本地/远程/标签、ahead/behind、切换/合并/重命名/删除、远程分支检出为本地
- **Stash**：Pop/Apply/Drop、一键 stash（含未跟踪开关）
- **远程**：fetch / push（多远程选择）/ 强制推送（二次确认）/ pull、远程增删改、凭据管理（HTTPS 令牌 / SSH 私钥路径）、user.name/email、.gitignore
- **SSH 主机密钥**：known_hosts 比对（首次连接弹窗信任并记住；密钥变更告警 + 显式更新）
- **代码托管账号**：GitHub / GitLab / 云效 Codeup 绑定（令牌加密存储）、连接测试、GitHub OAuth 设备码登录、按远程 URL 自动匹配凭据
- **云端仓库导入**：直接列出账号名下仓库并一键克隆
- **MCP 服务**：AI 工具经 HTTP 调用同一套 Git 引擎
- **克隆**：从 URL 克隆到本机（可指定分支，可带凭据）
- **多仓库**：持久化最近列表、一键切换仓库

## 构建依赖

rust 侧 git2 默认特性（https + ssh）+ vendored-libgit2 + vendored-openssl（全源码静态编译，产物只依赖 bionic 系统库）。需 NDK + perl + cmake + make + gcc。

## 多平台

- Android：`flutter build apk --release`（gradle 打包 rust_builder 里预编译的 arm64 .so，不编 rust）
- Windows/Linux：`flutter build windows/linux --release`（cargokit 现编 vendored libgit2/openssl，需 Rust + CMake）
- macOS：**CI 已产出**（arm64，ad-hoc 签名，Actions artifact `aiwli-git-macos`）；未公证，首次打开需右键→打开或 `xattr -cr` 过 Gatekeeper
- iOS：rust_builder 侧 podspec 就绪，但 app 侧无 `ios/` 脚手架，需先补齐再接 CI
- CI（GitHub Actions）：`analyze --fatal-infos` + `test` 门禁 → Android arm64 APK + Linux/Windows 包（Actions artifact 下载；Android 为 debug 签名验证包）；结果汇报到 `ci-status` 分支（`CI_STATUS.md`）
- 凭据/最近仓库存本机 JSON（Prefs），各平台一致

## 许可

AGPL-3.0-or-later（`LICENSE`）。本程序是自由软件：可自由使用、修改、再分发；**分发衍生版本（含修改版与嵌入本程序的整包）必须同样以 AGPL-3.0-or-later 开源，并向接收者提供完整对应源码**；通过网络提供服务（含托管/改造后仅作服务端运行）同样触发开源义务。闭源分发不允许；不对外分发的内部使用不产生义务。名称 "aiwli"、图标与品牌资产**不在** AGPL-3.0 授权范围内，fork 与二次分发须更名换图。第三方声明：`THIRD-PARTY-NOTICES.md`。
