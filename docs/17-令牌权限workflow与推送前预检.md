# 17 · 令牌 `workflow` 权限：推送失败的真正根因与「授权自动化」的落点

> 结论先行：**推送失败不在网络、不在 libgit2、不在 App 的推送判定**，而在
> **授权申请时少声明了一个 scope**。1.5.23 让 push 如实报错（这是必要的诊断能力），
> 1.5.24 治本：**在申请时就带上 `workflow`**，并把预检做进推送流程。

## 1. 现场证据链

自建库（远端 2026-10-05 建立）以来，App 一直显示「推送成功」，方法有两种：

1. 本地跟踪引用 `refs/remotes/origin/main` 被更新；
2. 错误日志零新增。

两者都**不是服务端事实**。用 GitHub REST 做权威核对后：

| 探针 | 结果 |
|---|---|
| `GET /repos/{owner}/{repo}` | 仓库存在、私有、默认分支 `main`，**`updated_at` 停在 2026-10-05** |
| `GET /repos/{owner}/{repo}/git/trees/HEAD` | **HTTP 409 `Git Repository is empty.`** |
| `git_fetch`（App 自己） | 1.5.22 的修复如实报出「空引用广告」 |

即**远端从未收到过任何推送**。1.5.23 挂上 `push_update_reference` 回调 + 服务端
二次核对后，真因浮出：

```
refusing to allow a Personal Access Token to create or update workflow
`.github/workflows/ci.yml` without `workflow` scope
```

## 2. 机制：为什么这个拒绝会被吞掉

GitHub 对 workflow 文件的限制**发生在服务端报告层**，不是传输层：

- 传输（pack 上传）成功 → libgit2 `push()` 返回 `Ok`；
- 服务端在 report-status 里对 `refs/heads/main` 回 `ng`（拒绝），并给出上面那句原因；
- 未挂 `push_update_reference` 回调 → 这个 `ng` **无人接收**；
- 后续 `finish_push()` 照写 `refs/remotes/origin/main`，日志零新增。

于是「本地显示已同步、远端空空如也」这个假象可以稳定维持数天。
**这与 fetch 的「空引用广告假成功」是同构的洞**：都源于「只看传输层、不看服务端事实」。

## 3. 治本：把 scope 声明在申请处

关键观察：**App 早就内置了 OAuth 设备流**（`startDeviceFlow` /
`pollDeviceFlowOnce` / `awaitDeviceFlow`，设置页 `_DeviceFlowDialog`），
而申请那一行写的是：

```dart
body: {'client_id': clientId, 'scope': 'repo'},
```

设备流的 scope 由**客户端声明**，用户在浏览器里看到的就是全部所需权限。
所以「自动化授权」根本不需要新造通道 —— 改一行：

```dart
const ghOauthScopes = 'repo workflow';
// → body: {'client_id': clientId, 'scope': scopes}
```

### 为什么这是"自动化"而不是"绕过"

GitHub 的 scope 是**服务端授权边界**，客户端无法自授；经典 PAT 的 scope 创建后
不可修改（只能重建）。所以「完全不碰 GitHub」不可能。能自动化的是**摩擦**：

| 旧路径 | 新路径（1.5.24） |
|---|---|
| 自己去设置页 → 找复选框 → 勾 repo + workflow → 生成 → 复制 → 粘贴 | App 内点按钮 → 浏览器确认（scope 已由 App 声明好） |
| 记不清该勾哪些，勾漏了 → 表现为「推送成功」但远端没有 | 预检 + 权限自检当场说明白 |

一次性前提：一个自己的 OAuth App 的 `client_id`（勾 Enable Device Flow）。
没有时 App 给两条路，都是一键跳转：建 OAuth App，或**预勾选令牌页**
（`/settings/tokens/new?scopes=repo,workflow`，点开即勾好）。

## 4. 判定边界（诚实声明）

`ghTokenInfo()` 读 `GET /user` 的 `X-OAuth-Scopes` 响应头。**该头只对
OAuth 令牌 / 经典 PAT 存在**：

- 有该头 → `scopes` 可用，`canPushWorkflow` = 是否含 `workflow`；
- **细粒度 PAT 与 GitHub App 安装令牌不返回该头** → `scopes == null`、
  `canPushWorkflow == null`，语义是**「无法自动判定」**，UI 必须照此措辞，
  不得渲染成「你没有权限」。这是本类型设计的硬约束。

推送前预检 `preflightWorkflowPush()` 同样保守，**四条同时成立才拦**：

1. 远端 host 是 `github.com`；
2. 凭据是 HTTP 令牌（**SSH 不走 scope 体系，直接放行**）；
3. `canPushWorkflow == false`（服务端明确缺）；
4. 待推提交确实动了 `.github/workflows/`。

任何一步拿不到确定答案（问不到 scope、diff 失败、网络抖动）→ **放行**。
预检是提示，不是门禁；权威判定仍是 Rust 侧的服务端核对。

第 4 条的实现：先 `diffRevs(from: '<remote>/<branch>', to: 'HEAD')`（最准）；
远端还没有该分支时（空远端 / 首次推送），「要推的就是全部历史」，退化为检查
工作区 `.github/workflows/` 是否存在文件。

## 5. 回归验证清单

- [ ] `flutter analyze` 无 issue（注意 FUSE 的 symlink 老坑：原样重跑即过）。
- [ ] 设备流请求体里 `scope` = `repo workflow`（可用测试断言守住）。
- [ ] 缺 workflow 的令牌 + 含 workflow 文件的提交 → 推送**前**弹预检；
      「仍然尝试」后由 Rust 侧如实报错、且**不写**跟踪引用。
- [ ] 细粒度令牌（无 `X-OAuth-Scopes`）→ 预检**放行**，不误报。
- [ ] SSH 远端 → 预检放行（无 scope 概念）。
- [ ] 空仓库浏览远端树 → 文案为「远端仓库还是空的」，不再是「合并冲突」。
- [ ] Overview 的「最近推送落地」显示 `pushed_at`（与 `updated_at` 区分）。

## 6. 未做 / 下一步

- **SSH 密钥生成 UI**：引擎已具备 SSH 能力（`git2` 编入 `ssh` feature，
  `make_callbacks` 里有 `CredentialType::SSH_KEY` 分支，`CredInput.key_path` +
  `SshPolicy`/known_hosts 都已就绪），但目前只有「私钥路径」输入框，缺
  生成/展示公钥/一键跳转。补完即获得一条**完全不涉及 scope** 的推送通道。
- **验证 SSH 是否真的绕开 workflow 限制**：需实测（本机端到端推一次含 workflow
  的提交），在拿到证据前不写成结论。
