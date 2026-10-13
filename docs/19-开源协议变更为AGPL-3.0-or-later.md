# 19 · 开源协议变更为 AGPL-3.0-or-later（由 GPL-3.0-or-later 变更）

日期：2026-10-13　范围：仅许可证与相关文案，无代码改动

## 一、结论

- 自本版本起以 **AGPL-3.0-or-later** 分发，`LICENSE` = AGPLv3 官方全文
  （gnu.org `agpl-3.0.txt`，661 行，sha256 `0d96a4ff68ad6d4b…`）。
- 中间态 GPL-3.0-or-later（见 docs/18）**无任何公开发布**（无 Release、仓库私有），
  对外不存在"已接收的 GPL-3 版本"，故本次变更无第三方同意问题；docs/18 记录的
  MPL-2.0 旧版权利对已接收者继续有效、不可撤回的逻辑不变。
- 名称 "aiwli"、图标与品牌资产仍以 **README 商标声明**保护，不写进许可证——
  GitHub 徽章保持干净的 **AGPL-3.0**（Kelivo 同款做法）。

## 二、三个参照项目的协议对照（本次决策依据）

| 项目 | 协议 | GitHub 徽章 | Release 页平台覆盖 |
| --- | --- | --- | --- |
| **Kelivo**（对标） | **纯 AGPL-3.0** | 干净 AGPL-3.0 | 最全（11 资产：Android 3 ABI + iOS ipa + macOS + Windows 2 种 + Linux 4 种） |
| Karing | GPL-3.0-or-later + 名称条款 | Other/NOASSERTION | 无 iOS（走 TestFlight/商店） |
| ProxyPin | Apache-2.0 | 干净 Apache-2.0 | 有 iOS ipa |

结论：与最想对齐的 Kelivo 完全一致 = **纯 AGPL-3.0**；Karing 的名称保护诉求由
README 商标声明满足（比写进许可证更干净，徽章不受影响）；ProxyPin 的宽松路线与
本项目 copyleft 目标相反，排除。

## 三、为什么 AGPL-3 而不是留在 GPL-3

1. **纯客户端下实际保护力相同**：AGPL 比 GPL 多的 §13（网络交互须提供源码）针对
   "改造后仅作服务端运行"的场景；客户端 app 分发即触发源码义务，两者一致。
2. **未来服务端组件零成本覆盖**：若日后加同步服务/托管版，无需再走一次再许可。
3. **徽章干净**：纯 AGPL-3.0 是标准 SPDX；GPL+附加条款会像 Karing 一样显示 Other。
4. **变更成本为零**：唯一作者，且无公开发布历史；等有贡献者后再改需征得同意。
5. **生态顾虑不成立**：独立 app 无人将其作为依赖引入，"公司禁运 AGPL 依赖"的
   论据对库成立、对终端应用基本不成立。

## 四、兼容性核查（依赖链无需变动）

| 组件 | 许可 | 与 AGPL-3.0-or-later 组合 |
| --- | --- | --- |
| libgit2（vendored C） | GPLv2 + 链接例外 | ✅ 例外授予"无限链接许可，组合不受库本身许可约束"——与 app 用 GPL-3 还是 AGPL-3 无关（`THIRD-PARTY-NOTICES.md`） |
| git2-rs / serde 等 | MIT OR Apache-2.0 | ✅ 单向兼容 |
| OpenSSL（openssl-src） | Apache-2.0 | ✅ Apache-2.0 → GPLv3 → AGPL-3 单向兼容链 |

## 五、其他不变项

- **iOS/App Store 结论不变**：AGPL §13 与 Apple 分发条款的冲突同 GPL-3，社区版
  仍不提供 iOS 构建（侧载 ipa 待脚手架补齐后另行评估）。
- **copyleft 触发时机不变**：纯内部使用（不分发、不对外提供服务）无义务。
- 应用内"关于"页读取的是打包进二进制的 `LICENSE` 资产，随本次变更自动显示 AGPL 全文。
