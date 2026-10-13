//! Remotes: list / fetch / push / pull with credential support (HTTPS
//! user+token, SSH key file), plus repo config (user.name/email) and
//! .gitignore editing.
//!
//! Transport availability depends on build features (https/ssh); when the
//! build has them off, libgit2 reports "transport not supported" and we
//! surface a clear hint instead.

use git2::{CertificateCheckStatus, CredentialType, FetchOptions, Oid, PushOptions, RemoteCallbacks, Repository};

use super::ops_branch::MergeResult;
use super::util::{init_tls, open, rev_to_commit, signature, skip_tls_verify};

pub struct CredInput {
    pub user: Option<String>,
    pub pass: Option<String>,
    pub key_path: Option<String>,
    pub passphrase: Option<String>,
}

pub struct RemoteInfo {
    pub name: String,
    pub url: String,
}

pub struct ConfigInfo {
    pub user_name: String,
    pub user_email: String,
}

/// SSH host-key policy for remote transports: verify the presented host key
/// against an OpenSSH-style known_hosts file managed by the Dart side. When
/// the host is unknown we fail with a parseable marker (`SSH_HOST_UNKNOWN::`)
/// so the UI can ask the user and retry with `accept_unknown = true`, which
/// persists the key ("trust & remember"). A changed key for a known host is
/// always refused until the user explicitly accepts the update.
pub struct SshPolicy {
    pub known_hosts_path: Option<String>,
    pub accept_unknown: bool,
}

const ERR_HOST_UNKNOWN: &str = "SSH_HOST_UNKNOWN::";
const ERR_HOST_CHANGED: &str = "SSH_HOST_CHANGED::";

const B64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn b64(data: &[u8]) -> String {
    let mut out = String::new();
    for chunk in data.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = *chunk.get(1).unwrap_or(&0) as u32;
        let b2 = *chunk.get(2).unwrap_or(&0) as u32;
        let n = (b0 << 16) | (b1 << 8) | b2;
        out.push(B64[(n >> 18) as usize & 63] as char);
        out.push(B64[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 { B64[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if chunk.len() > 2 { B64[n as usize & 63] as char } else { '=' });
    }
    out
}

/// One known_hosts line: (host aliases, key type, base64 key).
type HostEntry = (String, String, String);

fn parse_known_hosts(text: &str) -> Vec<HostEntry> {
    let mut out = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let mut it = line.split_whitespace();
        let (Some(hosts), Some(ktype), Some(key)) = (it.next(), it.next(), it.next()) else {
            continue;
        };
        out.push((hosts.to_string(), ktype.to_string(), key.to_string()));
    }
    out
}

#[derive(PartialEq, Debug)]
enum HostKeyCheck {
    Match,
    Mismatch,
    Unknown,
}

fn check_host(entries: &[HostEntry], host: &str, ktype: &str, key: &str) -> HostKeyCheck {
    let mut seen = false;
    for (hosts, kt, k) in entries {
        if hosts.split(',').any(|h| h.trim() == host) {
            if kt == ktype && k == key {
                return HostKeyCheck::Match;
            }
            seen = true;
        }
    }
    if seen {
        HostKeyCheck::Mismatch
    } else {
        HostKeyCheck::Unknown
    }
}

fn remember_host(path: &str, entry: &str) {
    use std::io::Write;
    if let Some(parent) = std::path::Path::new(path).parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(f, "{entry}");
    }
}

/// HTTPS/X.509 的裁决：默认 `CertificatePassthrough`（把结果交回 libgit2，
/// 即正常的链校验），只有用户打开逃生口才 `CertificateOk`（无条件放行）。
///
/// 关于逃生口为什么"够用"：libgit2 的 `httpclient` 在
/// `git_stream_connect()` 返回 `GIT_ECERTIFICATE` 时**不会直接失败**，
/// 而是把这个错误交给 `certificate_check` 回调（`is_valid = 0`），
/// 由回调的返回值决定连接是否继续：
///   - `CertificateOk`        → 继续（即使证书无效）＝ GitSync 的做法
///   - `CertificatePassthrough` → `is_valid ? 0 : -1` → 失败
/// 详见 libgit2 `transports/httpclient.c` 的 `http_server_connect` /
/// `check_certificate`。
///
/// ⚠️ 不能靠回调做"真校验"来替代 CA bundle：回调只拿得到**叶子证书**
/// （libgit2 `streams/openssl.c` 用 `X509_get_peer_certificate` + `i2d_X509`，
/// 没有中间证书），重建不了链。信任锚必须在握手前备好。
fn x509_verdict() -> CertificateCheckStatus {
    if skip_tls_verify() {
        CertificateCheckStatus::CertificateOk
    } else {
        CertificateCheckStatus::CertificatePassthrough
    }
}

fn make_callbacks<'cb>(cred: &'cb Option<CredInput>, ssh: &'cb SshPolicy) -> RemoteCallbacks<'cb> {
    let mut cbs = RemoteCallbacks::new();
    let kh_path = ssh
        .known_hosts_path
        .as_deref()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    if let Some(kh_path) = kh_path {
        let accept_unknown = ssh.accept_unknown;
        cbs.certificate_check(move |cert, host| {
            let Some(hk) = cert.as_hostkey() else {
                // HTTPS / X.509 → 走 libgit2 的链校验（信任锚来自 util::init_tls
                // 加载的 Android 系统 CA bundle，走 set_ssl_cert_file）。
                // 只有开了逃生口才无条件放行 —— 此时中间人无法被发现。
                return Ok(x509_verdict());
            };
            let (Some(key), Some(ktype)) = (hk.hostkey(), hk.hostkey_type()) else {
                return Ok(CertificateCheckStatus::CertificatePassthrough);
            };
            let key_b64 = b64(key);
            let ktype = ktype.name();
            let entries =
                parse_known_hosts(&std::fs::read_to_string(&kh_path).unwrap_or_default());
            match check_host(&entries, host, ktype, &key_b64) {
                HostKeyCheck::Match => Ok(CertificateCheckStatus::CertificateOk),
                HostKeyCheck::Mismatch => Err(git2::Error::from_str(&format!(
                    "{ERR_HOST_CHANGED}{host}::{ktype} {key_b64}"
                ))),
                HostKeyCheck::Unknown => {
                    let entry = format!("{host} {ktype} {key_b64}");
                    if accept_unknown {
                        remember_host(&kh_path, &entry);
                        Ok(CertificateCheckStatus::CertificateOk)
                    } else {
                        Err(git2::Error::from_str(&format!(
                            "{ERR_HOST_UNKNOWN}{host}::{ktype} {key_b64}"
                        )))
                    }
                }
            }
        });
    } else {
        // 没有要求管理 known_hosts（例如旧的 MCP 调用方）。
        // 注意：这里**不再是"无条件放行"** —— X.509/HTTPS 仍然校验，
        // 只有用户显式打开逃生口才放行（见 x509_verdict）。
        cbs.certificate_check(|_cert, _host| Ok(x509_verdict()));
    }
    if let Some(c) = cred {
        let user = c.user.clone();
        let pass = c.pass.clone();
        let key = c.key_path.clone();
        let keypass = c.passphrase.clone();
        cbs.credentials(move |_url, user_from_url, allowed| {
            let uname = user_from_url
                .map(|s| s.to_string())
                .or_else(|| user.clone());
            if allowed.contains(CredentialType::USER_PASS_PLAINTEXT) {
                git2::Cred::userpass_plaintext(
                    uname.as_deref().unwrap_or(""),
                    pass.as_deref().unwrap_or(""),
                )
            } else if allowed.contains(CredentialType::SSH_KEY) {
                git2::Cred::ssh_key(
                    uname.as_deref().unwrap_or("git"),
                    None,
                    std::path::Path::new(key.as_deref().unwrap_or("")),
                    keypass.as_deref(),
                )
            } else if allowed.contains(CredentialType::DEFAULT) {
                git2::Cred::default()
            } else {
                Err(git2::Error::from_str(
                    "缺少凭据：HTTPS 需用户名+令牌，SSH 需私钥路径（设置页配置）",
                ))
            }
        });
    }
    cbs
}

/// 在 libgit2 的**原始错误**后面追加一条可操作的提示。
///
/// 旧实现用提示文案**整个替换**掉原始错误，于是真正的
/// `the SSL certificate is invalid`（以及 class=Ssl 16）永远看不到，
/// 排障只能靠猜 —— 这次定位问题的成本就花在这上面。原始错误必须保留。
fn transport_hint(e: &git2::Error) -> String {
    let base = format!("{e}");
    let msg = e.message();
    if msg.contains("transport not supported") || msg.contains("not supported") && (msg.contains("http") || msg.contains("ssh")) {
        format!("{base}\n提示：此构建未启用对应网络传输（https/ssh），需在 Cargo 启用网络特性后重新构建。")
    } else if e.class() == git2::ErrorClass::Ssl
        || msg.contains("SSL certificate")
        || msg.contains("certificate is invalid")
    {
        format!(
            "{base}\n提示：HTTPS 证书校验失败。已自动加载 Android 系统信任库（设置 → 网络安全 可查看状态）；\
             若仍失败，通常是自签证书，或 VPN / 代理做了 TLS 拦截。可依次尝试：\
             1) 关掉代理重试；2) 远程改用 SSH（git@主机:用户/仓库.git，不走证书校验）；\
             3) 确知风险时，到「设置 → 网络安全」临时打开「跳过证书校验」\
             —— （3）会让中间人无法被发现，能用 SSH 就别用它。"
        )
    } else {
        base
    }
}

/// Clone a remote repo into `path` (must be empty or absent).
pub fn clone_repo(
    url: String,
    path: String,
    branch: Option<String>,
    cred: Option<CredInput>,
    ssh: &SshPolicy,
) -> Result<String, String> {
    if url.trim().is_empty() {
        return Err("远程 URL 为空".into());
    }
    init_tls();
    let p = std::path::Path::new(&path);
    if p.exists() {
        let non_empty = std::fs::read_dir(p).map(|mut d| d.next().is_some()).unwrap_or(true);
        if non_empty {
            return Err(format!("目标目录已存在且非空: {path}"));
        }
    }
    let parent = p.parent().ok_or("无效目标路径")?;
    std::fs::create_dir_all(parent).map_err(|e| format!("创建目标目录失败: {e}"))?;
    let mut opts = git2::FetchOptions::new();
    opts.remote_callbacks(make_callbacks(&cred, ssh));
    let mut rb = git2::build::RepoBuilder::new();
    if let Some(b) = branch.as_deref().map(|s| s.trim()).filter(|s| !s.is_empty()) {
        rb.branch(b);
    }
    rb.fetch_options(opts);
    rb.clone(url.trim(), p).map_err(|e| format!("clone 失败: {}", transport_hint(&e)))?;
    Ok(format!("已克隆到 {path}"))
}

pub fn remote_add(path: String, name: String, url: String) -> Result<(), String> {
    if name.trim().is_empty() || url.trim().is_empty() {
        return Err("远程名称和 URL 不能为空".into());
    }
    let repo = open(&path)?;
    repo.remote(name.trim(), url.trim()).map_err(|e| format!("添加远程失败: {e}"))?;
    Ok(())
}

pub fn remote_set_url(path: String, name: String, url: String) -> Result<(), String> {
    if url.trim().is_empty() {
        return Err("URL 不能为空".into());
    }
    let repo = open(&path)?;
    repo.find_remote(&name).map_err(|e| format!("找不到远程 {name}: {e}"))?;
    repo.remote_set_url(&name, url.trim()).map_err(|e| format!("修改 URL 失败: {e}"))?;
    Ok(())
}

pub fn remote_delete(path: String, name: String) -> Result<(), String> {
    let repo = open(&path)?;
    repo.remote_delete(&name).map_err(|e| format!("删除远程失败: {e}"))?;
    Ok(())
}

pub fn remotes(path: String) -> Result<Vec<RemoteInfo>, String> {
    let repo = open(&path)?;
    let names = repo.remotes().map_err(|e| e.to_string())?;
    let mut out = Vec::new();
    for n in names.iter().flatten() {
        let url = repo
            .find_remote(n)
            .ok()
            .and_then(|r| r.url().map(|u| u.to_string()))
            .unwrap_or_default();
        out.push(RemoteInfo { name: n.to_string(), url });
    }
    Ok(out)
}

/// fetch「成功」但 FETCH_HEAD 为空 = 远端返回了 0 个引用（空引用广告）。
/// 实测 2026-10-08 19:22：链路被代理/VPN 拦截时返回空响应（TLS 连接成功、
/// 0 个引用），libgit2 把「0 引用」判成 fetch 成功——无报错、FETCH_HEAD 0 字节，
/// 操作条显示「拉取完成」，用户以为同步了实际什么都没拿到。健康 fetch 无论
/// 有无新对象都会往 FETCH_HEAD 写入引用行（10-01 实测 128 字节）——0 字节即
/// 空广告，必须显式报错。
/// 只用于网络远程；本地路径远程走 fetch_local_inprocess（不写 FETCH_HEAD）。
fn assert_fetch_got_refs(repo: &Repository, remote: &str) -> Result<(), String> {
    let fh = repo.path().join("FETCH_HEAD");
    let len = std::fs::metadata(&fh).map(|m| m.len()).unwrap_or(0);
    if len == 0 {
        return Err(format!(
            "fetch 失败: 远端 {remote} 未返回任何引用（空引用广告）——连接可能被代理 / VPN 拦截后返回了空响应，或远端是空仓库。请检查网络（VPN 分流规则）后重试。"
        ));
    }
    Ok(())
}

pub fn fetch(
    path: String,
    remote: String,
    cred: Option<CredInput>,
    ssh: &SshPolicy,
) -> Result<String, String> {
    init_tls();
    let repo = open(&path)?;
    let r = repo.find_remote(&remote).map_err(|e| format!("fetch 失败: 找不到远程 {remote}: {e}"))?;
    let url = r.url().unwrap_or("").to_string();
    drop(r);

    // 本地路径远程 → 进程内对象复制（FUSE 层会破坏传输路径的 pack I/O）
    if url.starts_with('/') || url.starts_with("file://") {
        fetch_local_inprocess(&repo, &url, &remote)?;
        return Ok(format!("已获取 {remote}"));
    }

    let mut r = repo.find_remote(&remote).map_err(|e| format!("fetch 失败: 找不到远程 {remote}: {e}"))?;
    let cbs = make_callbacks(&cred, ssh);
    let mut opts = FetchOptions::new();
    opts.remote_callbacks(cbs);
    // prune 必须关：链路抖动（VPN 分流）会让 fetch 拿到**空的 ref 广告**
    // （实测 2026-10-08：FETCH_HEAD 0 字节），libgit2 拿空表去 prune 会把
    // refs/remotes/* 连 reflog 一起剪光，随后 revspec 解析必然失败，且报出
    // 误导性的「找不到仓库或文件」。跟踪 ref 过期无害——下次成功 fetch 自然刷新。
    opts.prune(git2::FetchPrune::Off);
    r.fetch(&[] as &[&str], Some(&mut opts), None)
        .map_err(|e| format!("fetch 失败: {}", transport_hint(&e)))?;
    // 空引用广告检测：fetch 判「成功」但 FETCH_HEAD 为空 = 远端返回了 0 个引用
    assert_fetch_got_refs(&repo, &remote)?;
    Ok(format!("已获取 {remote}"))
}

/// 本地路径远程的进程内 fetch：逐对象复制远程缺失对象到本地 odb + 更新跟踪引用。
/// 与 push_local_inprocess 共用同一组 copy helper（odb 路径不受 FUSE pack 写入问题影响）。
fn fetch_local_inprocess(
    repo: &Repository,
    url: &str,
    remote: &str,
) -> Result<(), String> {
    let remote_path = url.trim_start_matches("file://").trim().to_string();
    let remote_repo = Repository::open(&remote_path)
        .map_err(|e| format!("fetch 失败: 打不开远程仓库 {remote_path}: {e}"))?;
    let mut remote_odb = remote_repo.odb().map_err(|e| format!("fetch 失败: {e}"))?;
    let mut local_odb = repo.odb().map_err(|e| format!("fetch 失败: {e}"))?;

    let refs = remote_repo
        .references()
        .map_err(|e| format!("fetch 失败: {e}"))?;
    for refr in refs {
        let refr = refr.map_err(|e| format!("fetch 失败: {e}"))?;
        let Some(name) = refr.name().map(|s| s.to_string()) else {
            continue;
        };
        let Some(oid) = refr.target() else {
            continue;
        };
        // 只处理分支引用（refs/heads/*）
        if !name.starts_with("refs/heads/") {
            continue;
        }
        let branch = name.trim_start_matches("refs/heads/").to_string();
        let mut walk = remote_repo.revwalk().map_err(|e| format!("fetch 失败: {e}"))?;
        walk.push(oid).map_err(|e| format!("fetch 失败: {e}"))?;
        for id in walk {
            let id = id.map_err(|e| format!("fetch 失败: {e}"))?;
            if local_odb.exists(id) {
                break; // 本地已有此提交 → 更早的历史必然已有
            }
            copy_object_tree(&remote_repo, &mut remote_odb, &mut local_odb, id)?;
        }
        // 更新本地远程跟踪引用 refs/remotes/<remote>/<branch>
        let tracking = format!("refs/remotes/{remote}/{branch}");
        let _ = repo.reference(&tracking, oid, true, "fetch: update remote tracking");
    }
    Ok(())
}

/// 推送单个标签（`refs/tags/<name>:refs/tags/<name>`）。
///
/// 与 [push] 同一套纪律：状态回调抓服务端逐引用拒绝 + 推完再连一次远端核对
/// 引用真的写上（libgit2 的 push 只保证传输层跑完，见 push() 内注释）。
/// 标签没有上游/跟踪引用概念，成功即返回。轻量与附注标签都支持：
/// `refname_to_id` 对两者都返回引用直接指向的 oid（附注=tag 对象），远端
/// 广告语义相同，核对可直接比对。
pub fn push_tag(
    path: String,
    remote: String,
    name: String,
    force: bool,
    cred: Option<CredInput>,
    ssh: &SshPolicy,
) -> Result<String, String> {
    init_tls();
    let repo = open(&path)?;
    let refname = format!("refs/tags/{name}");
    let local_oid = repo
        .refname_to_id(&refname)
        .map_err(|e| format!("push 失败: 找不到本地标签 {name}: {e}"))?;

    let r0 = repo
        .find_remote(&remote)
        .map_err(|e| format!("找不到远程 {remote}: {e}"))?;
    let url = r0.url().unwrap_or("").to_string();
    drop(r0);

    // 本地路径远程：与 push() 同因（FUSE 破坏 pack I/O）走进程内直推。
    if url.starts_with('/') || url.starts_with("file://") {
        return push_tag_local_inprocess(&repo, &url, &remote, &name, force);
    }

    let mut r = repo
        .find_remote(&remote)
        .map_err(|e| format!("找不到远程 {remote}: {e}"))?;
    let refspec = format!("{}{refname}:{refname}", if force { "+" } else { "" });
    let statuses: std::sync::Arc<std::sync::Mutex<Vec<(String, Option<String>)>>> =
        std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    {
        let sink = statuses.clone();
        let mut cbs = make_callbacks(&cred, ssh);
        cbs.push_update_reference(move |rf, status| {
            if let Ok(mut v) = sink.lock() {
                v.push((rf.to_string(), status.map(|s| s.to_string())));
            }
            Ok(())
        });
        let mut opts = PushOptions::new();
        opts.remote_callbacks(cbs);
        r.push(&[refspec.as_str()], Some(&mut opts))
            .map_err(|e| format!("push 失败: {}", transport_hint(&e)))?;
    }
    let mut rejected: Option<(String, Option<String>)> = None;
    if let Ok(v) = statuses.lock() {
        for (n, why) in v.iter() {
            if why.is_some() {
                rejected = Some((n.clone(), why.clone()));
                break;
            }
        }
    }
    if let Some((rf, Some(why))) = rejected {
        return Err(format!(
            "push 失败: 推送未被接受——远端拒绝 {rf}：{why}（常见原因：令牌缺写权限、远端已有同名标签且未加强制）"
        ));
    }
    verify_remote_ref(&repo, &remote, &cred, ssh, &refname, local_oid)?;
    Ok(format!("已推送标签 {name} → {remote}"))
}

/// 本地路径远程的标签进程内直推：复制标签指向的对象 + 更新远程引用。
/// 附注标签额外复制 tag 对象本身（odb.write 幂等）；轻量标签直接走提交历史。
fn push_tag_local_inprocess(
    repo: &Repository,
    url: &str,
    remote: &str,
    name: &str,
    force: bool,
) -> Result<String, String> {
    let remote_path = url.trim_start_matches("file://").trim().to_string();
    let remote_repo = Repository::open(&remote_path)
        .map_err(|e| format!("push 失败: 打不开远程仓库 {remote_path}: {e}"))?;
    let refname = format!("refs/tags/{name}");
    let oid = repo
        .refname_to_id(&refname)
        .map_err(|e| format!("push 失败: 找不到本地标签 {name}: {e}"))?;

    if !force {
        if let Ok(old) = remote_repo.refname_to_id(&refname) {
            if old != oid {
                return Err(format!(
                    "push 失败: 远端已有同名标签 {name} 且指向不同对象（用强制推送覆盖）"
                ));
            }
        }
    }

    // 剥到提交：轻量标签 oid 即提交；附注标签取 tag 目标（嵌套 tag 不支持，报错即可）。
    let obj = repo
        .find_object(oid, None)
        .map_err(|e| format!("push 失败: {e}"))?;
    let (tag_oid, commit_oid) = match obj.kind() {
        Some(git2::ObjectType::Tag) => {
            let t = obj
                .as_tag()
                .ok_or_else(|| "push 失败: 标签对象异常".to_string())?;
            (Some(oid), t.target_id())
        }
        Some(git2::ObjectType::Commit) => (None, oid),
        _ => {
            return Err(format!(
                "push 失败: 标签 {name} 未指向提交（暂不支持指向 tree/blob 的标签）"
            ))
        }
    };

    let mut local_odb = repo.odb().map_err(|e| format!("push 失败: {e}"))?;
    let mut remote_odb = remote_repo.odb().map_err(|e| format!("push 失败: {e}"))?;
    let mut walk = repo.revwalk().map_err(|e| format!("push 失败: {e}"))?;
    walk.push(commit_oid).map_err(|e| format!("push 失败: {e}"))?;
    walk.set_sorting(git2::Sort::TOPOLOGICAL)
        .map_err(|e| format!("push 失败: {e}"))?;
    for id in walk {
        let id = id.map_err(|e| format!("push 失败: {e}"))?;
        if remote_odb.exists(id) {
            break; // 远程已有此提交 → 更早的历史必然已有
        }
        copy_object_tree(repo, &mut local_odb, &mut remote_odb, id)?;
    }
    if let Some(toid) = tag_oid {
        if !remote_odb.exists(toid) {
            let o = local_odb.read(toid).map_err(|e| format!("push 失败: {e}"))?;
            remote_odb
                .write(o.kind(), o.data())
                .map_err(|e| format!("push 失败: {e}"))?;
        }
    }
    drop(remote_odb);

    remote_repo
        .reference(&refname, oid, true, &format!("push: update tag {name}"))
        .map_err(|e| format!("push 失败: 写远程引用失败: {e}"))?;
    drop(remote_repo);
    Ok(format!("已推送标签 {name} → {remote}"))
}

pub fn push(
    path: String,
    remote: String,
    branch: String,
    set_upstream: bool,
    force: bool,
    cred: Option<CredInput>,
    ssh: &SshPolicy,
) -> Result<String, String> {
    init_tls();
    let repo = open(&path)?;
    let r = repo.find_remote(&remote).map_err(|e| format!("找不到远程 {remote}: {e}"))?;
    let url = r.url().unwrap_or("").to_string();
    drop(r);

    // 本地路径远程（/path 或 file:///path）绕过传输层进程内直推：
    // 这台设备的 FUSE 层会破坏 libgit2 push 传输路径的 pack I/O
    // （zlib stream 错误 / lockfile rename ENOENT），而 odb 写入路径完全正常。
    if url.starts_with('/') || url.starts_with("file://") {
        return push_local_inprocess(&repo, &url, &remote, &branch, set_upstream, force);
    }

    let mut r = repo.find_remote(&remote).map_err(|e| format!("找不到远程 {remote}: {e}"))?;
    let refspec = format!("{}refs/heads/{branch}:refs/heads/{branch}", if force { "+" } else { "" });
    // 服务端逐引用状态回调：libgit2 的 push 只保证「传输层跑完」，服务端在报告里
    // 拒绝（`ng <ref> <reason>`）时 r.push() 照样返回 Ok —— 不挂这个回调就永远
    // 看不到拒绝原因。2026-10-10 实测：远端是空仓库 + 服务端拒绝，push 返回 Ok、
    // 跟踪引用被写、错误日志零新增，「推送成功」持续了四天而远端一个字节都没有。
    let statuses: std::sync::Arc<std::sync::Mutex<Vec<(String, Option<String>)>>> =
        std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    {
        let sink = statuses.clone();
        let mut cbs = make_callbacks(&cred, ssh);
        cbs.push_update_reference(move |refname, status| {
            if let Ok(mut v) = sink.lock() {
                v.push((refname.to_string(), status.map(|s| s.to_string())));
            }
            Ok(())
        });
        let mut opts = PushOptions::new();
        opts.remote_callbacks(cbs);
        r.push(&[refspec.as_str()], Some(&mut opts))
            .map_err(|e| format!("push 失败: {}", transport_hint(&e)))?;
    }
    let mut rejected: Option<(String, Option<String>)> = None;
    if let Ok(v) = statuses.lock() {
        for (name, why) in v.iter() {
            if why.is_some() {
                rejected = Some((name.clone(), why.clone()));
                break;
            }
        }
    }
    if let Some((refname, Some(why))) = rejected {
        return Err(format!(
            "push 失败: 推送未被接受——远端拒绝 {refname}：{why}（常见原因：令牌缺写权限、分支保护或权限不足）"
        ));
    }
    // 服务端核对：远端 refs/heads/<branch> 必须真的等于本地 HEAD 才算成功。
    // 服务端报告可能什么都不给（空报告），只能自己再问远端一次。
    let local_oid = repo
        .refname_to_id(&format!("refs/heads/{branch}"))
        .map_err(|e| format!("push 失败: 找不到本地分支 {branch}: {e}"))?;
    verify_remote_branch(&repo, &remote, &cred, ssh, &branch, local_oid)?;
    finish_push(&repo, &remote, &branch, set_upstream)?;
    Ok(format!("已推送 {branch} → {remote}"))
}

/// [verify_remote_ref] 的分支薄壳（保留原签名，push/finish_push 调用点不变）。
fn verify_remote_branch(
    repo: &Repository,
    remote: &str,
    cred: &Option<CredInput>,
    ssh: &SshPolicy,
    branch: &str,
    want: Oid,
) -> Result<(), String> {
    verify_remote_ref(
        repo,
        remote,
        cred,
        ssh,
        &format!("refs/heads/{branch}"),
        want,
    )
}

/// 推送后的服务端核对（引用名泛化版，分支与标签共用）：远端 `want_ref` 必须真的
/// 指向本地 `want`。libgit2 的 `push()` 只保证传输层跑完 —— 服务端拒绝时也能返回
/// Ok（见 push() 里的状态回调注释）。唯一可靠的判定是再连一次远端、把引用广告
/// 读回来比对：核对不通过就不报成功，否则「本地已同步、远端空空」会再次同时
/// 骗过用户和错误日志。与 1.5.22 的 FETCH_HEAD 校验是同一个教训。
fn verify_remote_ref(
    repo: &Repository,
    remote: &str,
    cred: &Option<CredInput>,
    ssh: &SshPolicy,
    want_ref: &str,
    want: Oid,
) -> Result<(), String> {
    let mut r = repo
        .find_remote(remote)
        .map_err(|e| format!("push 失败: 无法确认推送结果——找不到远程 {remote}: {e}"))?;
    let cbs = make_callbacks(cred, ssh);
    let conn = r
        .connect_auth(git2::Direction::Fetch, Some(cbs), None)
        .map_err(|e| {
            format!(
                "push 失败: 无法确认推送结果——{}；请重试（未写入远程跟踪引用）",
                transport_hint(&e)
            )
        })?;
    let heads = conn
        .list()
        .map_err(|e| format!("push 失败: 无法确认推送结果——{e}；请重试"))?;
    let got = heads
        .iter()
        .find(|h| h.name() == want_ref)
        .map(|h| h.oid());
    let short = |o: &Oid| o.to_string().chars().take(8).collect::<String>();
    match got {
        Some(oid) if oid == want => Ok(()),
        Some(oid) => Err(format!(
            "push 失败: 推送未被接受——远端 {want_ref} 仍指向 {}（本地 {}）；请检查令牌写权限后重试",
            short(&oid),
            short(&want)
        )),
        None => Err(format!(
            "push 失败: 推送未被接受——远端没有 {want_ref}；请检查令牌是否具备写权限（只读令牌只能拉不能推）"
        )),
    }
}

/// push 成功后的公共收尾：更新远程跟踪引用（git CLI 行为，libgit2 不自动做）+ 设上游。
fn finish_push(
    repo: &Repository,
    remote: &str,
    branch: &str,
    set_upstream: bool,
) -> Result<(), String> {
    let oid = repo
        .refname_to_id(&format!("refs/heads/{branch}"))
        .map_err(|e| format!("push 失败: 找不到本地分支 {branch}: {e}"))?;
    let _ = repo.reference(
        &format!("refs/remotes/{remote}/{branch}"),
        oid,
        true,
        "push: update remote tracking",
    );
    if set_upstream {
        if let Ok(mut b) = repo.find_branch(branch, git2::BranchType::Local) {
            b.set_upstream(Some(&format!("{remote}/{branch}"))).ok();
        }
    }
    Ok(())
}

/// 本地路径远程的进程内直推：odb 逐对象复制（幂等）+ 更新远程引用。
fn push_local_inprocess(
    repo: &Repository,
    url: &str,
    remote: &str,
    branch: &str,
    set_upstream: bool,
    force: bool,
) -> Result<String, String> {
    let remote_path = url.trim_start_matches("file://").trim().to_string();
    let remote_repo = Repository::open(&remote_path)
        .map_err(|e| format!("push 失败: 打不开远程仓库 {remote_path}: {e}"))?;
    let refname = format!("refs/heads/{branch}");
    let oid = repo
        .refname_to_id(&refname)
        .map_err(|e| format!("push 失败: 找不到本地分支 {branch}: {e}"))?;

    if !force {
        if let Ok(old) = remote_repo.refname_to_id(&refname) {
            if old != oid && !is_ancestor(repo, old, oid)? {
                return Err("push 失败: cannot push because a reference that you are trying to update on the remote contains commits that are not present locally.".into());
            }
        }
    }

    let mut local_odb = repo.odb().map_err(|e| format!("push 失败: {e}"))?;
    let mut remote_odb = remote_repo.odb().map_err(|e| format!("push 失败: {e}"))?;
    let mut walk = repo.revwalk().map_err(|e| format!("push 失败: {e}"))?;
    walk.push(oid).map_err(|e| format!("push 失败: {e}"))?;
    walk.set_sorting(git2::Sort::TOPOLOGICAL)
        .map_err(|e| format!("push 失败: {e}"))?;
    for id in walk {
        let id = id.map_err(|e| format!("push 失败: {e}"))?;
        if remote_odb.exists(id) {
            break; // 远程已有此提交 → 更早的历史必然已有
        }
        copy_object_tree(repo, &mut local_odb, &mut remote_odb, id)?;
    }
    drop(remote_odb);

    remote_repo
        .reference(&refname, oid, true, &format!("push: update {branch}"))
        .map_err(|e| format!("push 失败: 写远程引用失败: {e}"))?;
    drop(remote_repo);

    finish_push(repo, remote, branch, set_upstream)?;
    Ok(format!("已推送 {branch} → {remote}"))
}

/// 复制一个提交及其树/叶子对象到远程 odb（odb.write 幂等，同 sha 重复写无害）。
fn copy_object_tree(
    repo: &Repository,
    local_odb: &mut git2::Odb,
    remote_odb: &mut git2::Odb,
    commit_id: Oid,
) -> Result<(), String> {
    let obj = repo
        .find_object(commit_id, Some(git2::ObjectType::Commit))
        .map_err(|e| format!("push 失败: {e}"))?;
    let commit = obj
        .as_commit()
        .ok_or_else(|| "push 失败: 提交对象异常".to_string())?;
    copy_tree_recursive(repo, local_odb, remote_odb, commit.tree_id())?;
    if !remote_odb.exists(commit_id) {
        let obj = local_odb
            .read(commit_id)
            .map_err(|e| format!("push 失败: {e}"))?;
        remote_odb
            .write(obj.kind(), obj.data())
            .map_err(|e| format!("push 失败: {e}"))?;
    }
    Ok(())
}

fn copy_tree_recursive(
    repo: &Repository,
    local_odb: &mut git2::Odb,
    remote_odb: &mut git2::Odb,
    tree_id: Oid,
) -> Result<(), String> {
    if remote_odb.exists(tree_id) {
        return Ok(());
    }
    let tree = repo
        .find_tree(tree_id)
        .map_err(|e| format!("push 失败: {e}"))?;
    for entry in tree.iter() {
        match entry.kind() {
            Some(git2::ObjectType::Tree) => {
                copy_tree_recursive(repo, local_odb, remote_odb, entry.id())?
            }
            Some(git2::ObjectType::Blob) => {
                if !remote_odb.exists(entry.id()) {
                    let obj = local_odb
                        .read(entry.id())
                        .map_err(|e| format!("push 失败: {e}"))?;
                    remote_odb
                        .write(obj.kind(), obj.data())
                        .map_err(|e| format!("push 失败: {e}"))?;
                }
            }
            _ => {}
        }
    }
    let obj = local_odb
        .read(tree_id)
        .map_err(|e| format!("push 失败: {e}"))?;
    remote_odb
        .write(obj.kind(), obj.data())
        .map_err(|e| format!("push 失败: {e}"))?;
    Ok(())
}

fn is_ancestor(repo: &Repository, ancestor: Oid, descendant: Oid) -> Result<bool, String> {
    if ancestor == descendant {
        return Ok(true);
    }
    let mut walk = repo.revwalk().map_err(|e| format!("push 失败: {e}"))?;
    walk.push(descendant).map_err(|e| format!("push 失败: {e}"))?;
    for id in walk {
        if id.map_err(|e| format!("push 失败: {e}"))? == ancestor {
            return Ok(true);
        }
    }
    Ok(false)
}

/// fetch + merge upstream of the current branch.
pub fn pull(path: String, cred: Option<CredInput>, ssh: &SshPolicy) -> Result<MergeResult, String> {
    init_tls();
    let repo = open(&path)?;
    let head = repo.head().map_err(|_| "空仓库无 HEAD")?;
    let branch_name = head
        .shorthand()
        .ok_or("分离 HEAD 状态请先切换分支")?
        .to_string();
    let local = repo
        .find_branch(&branch_name, git2::BranchType::Local)
        .map_err(|e| format!("找不到当前分支: {e}"))?;
    let upstream = local
        .upstream()
        .map_err(|_| format!("分支 {branch_name} 没有设置上游，先 push -u 或在设置里指定"))?;
    let up_name = upstream.name().ok().flatten().ok_or("上游名称无效")?.to_string();
    let remote = up_name.split('/').next().unwrap_or("origin").to_string();
    let _ = repo.find_remote(&remote).map_err(|e| format!("找不到远程 {remote}: {e}"))?;

    // fetch with callbacks
    let r = repo.find_remote(&remote).map_err(|e| e.to_string())?;
    let url = r.url().unwrap_or("").to_string();
    drop(r);
    if url.starts_with('/') || url.starts_with("file://") {
        // 本地路径远程 → 进程内对象复制（FUSE 层会破坏传输路径的 pack I/O）
        fetch_local_inprocess(&repo, &url, &remote)?;
    } else {
        let cbs = make_callbacks(&cred, ssh);
        let mut opts = FetchOptions::new();
        opts.remote_callbacks(cbs);
        // 同上：prune 关闭，理由见 fetch() 里的注释（空广告 prune 会剪光跟踪 ref）。
        opts.prune(git2::FetchPrune::Off);
        let mut r = repo.find_remote(&remote).map_err(|e| e.to_string())?;
        r.fetch(&[] as &[&str], Some(&mut opts), None)
            .map_err(|e| format!("fetch 失败: {}", transport_hint(&e)))?;
        // 空引用广告检测（同 fetch()）：链路被劫持时远端返回 0 个引用仍判「成功」
        assert_fetch_got_refs(&repo, &remote)?;
    }

    // merge upstream commit
    let target = rev_to_commit(&repo, &up_name)?;
    let up_ref = repo
        .find_reference(&format!("refs/remotes/{up_name}"))
        .or_else(|_| repo.find_reference(&format!("refs/heads/{up_name}")))
        .map_err(|e| format!("找不到上游引用 {up_name}: {e}"))?;
    let annotated = repo.reference_to_annotated_commit(&up_ref).map_err(|e| e.to_string())?;
    let (analysis, _) = repo.merge_analysis(&[&annotated]).map_err(|e| e.to_string())?;
    if analysis.is_up_to_date() {
        return Ok(MergeResult { fast_forward: false, up_to_date: true, commit_id: None, conflicts: vec![] });
    }
    if analysis.is_fast_forward() {
        let mut head_ref = repo.head().map_err(|e| e.to_string())?;
        head_ref
            .set_target(target.id(), &format!("pull: fast-forward {up_name}"))
            .map_err(|e| e.to_string())?;
        let mut cb = git2::build::CheckoutBuilder::new();
        cb.force();
        repo.checkout_tree(target.as_object(), Some(&mut cb))
            .map_err(|e| format!("更新工作树失败: {e}"))?;
        let id = target.id().to_string();
        return Ok(MergeResult { fast_forward: true, up_to_date: false, commit_id: Some(id), conflicts: vec![] });
    }
    repo.merge(&[&annotated], None, None).map_err(|e| format!("合并失败: {e}"))?;
    let mut index = repo.index().map_err(|e| e.to_string())?;
    if index.has_conflicts() {
        let mut v = Vec::new();
        for c in index.conflicts().map_err(|e| e.to_string())?.flatten() {
            if let Some(e) = c.our.or(c.their).or(c.ancestor) {
                let p = String::from_utf8_lossy(&e.path).to_string();
                if !v.contains(&p) {
                    v.push(p);
                }
            }
        }
        return Ok(MergeResult { fast_forward: false, up_to_date: false, commit_id: None, conflicts: v });
    }
    let tree_oid = index.write_tree().map_err(|e| e.to_string())?;
    let tree = repo.find_tree(tree_oid).map_err(|e| e.to_string())?;
    let head_commit = repo.head().map_err(|e| e.to_string())?.peel_to_commit().map_err(|e| e.to_string())?;
    let sig = signature(&repo)?;
    let msg = format!("Merge branch '{up_name}'");
    let oid = repo
        .commit(Some("HEAD"), &sig, &sig, &msg, &tree, &[&head_commit, &target])
        .map_err(|e| format!("生成合并提交失败: {e}"))?;
    Ok(MergeResult { fast_forward: false, up_to_date: false, commit_id: Some(oid.to_string()), conflicts: vec![] })
}

pub fn config_get(path: String) -> Result<ConfigInfo, String> {
    let repo = open(&path)?;
    let cfg = repo.config().map_err(|e| e.to_string())?;
    let get = |k: &str| -> String {
        cfg.get_string(k)
            .ok()
            .or_else(|| git2::Config::open_default().ok().and_then(|c| c.get_string(k).ok()))
            .unwrap_or_default()
    };
    Ok(ConfigInfo { user_name: get("user.name"), user_email: get("user.email") })
}

pub fn config_set(path: String, user_name: Option<String>, user_email: Option<String>) -> Result<(), String> {
    let repo = open(&path)?;
    let mut cfg = repo.config().map_err(|e| e.to_string())?;
    if let Some(n) = user_name.filter(|s| !s.trim().is_empty()) {
        cfg.set_str("user.name", n.trim()).map_err(|e| e.to_string())?;
    }
    if let Some(e) = user_email.filter(|s| !s.trim().is_empty()) {
        cfg.set_str("user.email", e.trim()).map_err(|e| e.to_string())?;
    }
    Ok(())
}

pub fn ignore_get(path: String) -> Result<String, String> {
    let repo = open(&path)?;
    let p = super::util::workdir_path(&repo, ".gitignore")?;
    if !p.exists() {
        return Ok(String::new());
    }
    std::fs::read_to_string(&p).map_err(|e| format!("读取 .gitignore 失败: {e}"))
}

pub fn ignore_set(path: String, content: String) -> Result<(), String> {
    let repo = open(&path)?;
    let p = super::util::workdir_path(&repo, ".gitignore")?;
    std::fs::write(&p, content).map_err(|e| format!("写入 .gitignore 失败: {e}"))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn b64_matches_known_vectors() {
        assert_eq!(b64(b""), "");
        assert_eq!(b64(b"f"), "Zg==");
        assert_eq!(b64(b"fo"), "Zm8=");
        assert_eq!(b64(b"foo"), "Zm9v");
        assert_eq!(b64(b"foob"), "Zm9vYg==");
        assert_eq!(b64(b"fooba"), "Zm9vYmE=");
        assert_eq!(b64(b"foobar"), "Zm9vYmFy");
    }

    #[test]
    fn known_hosts_parsing_skips_comments_and_blanks() {
        let e = parse_known_hosts(
            "# comment\n\ngithub.com ssh-ed25519 AAAA\nexample.com,foo.com ssh-rsa BBBB\n",
        );
        assert_eq!(e.len(), 2);
        assert_eq!(e[0].0, "github.com");
        assert_eq!(e[0].1, "ssh-ed25519");
        assert_eq!(e[1].2, "BBBB");
    }

    #[test]
    fn host_key_check_match_mismatch_unknown() {
        let e = vec![
            ("github.com".to_string(), "ssh-ed25519".to_string(), "AAAA".to_string()),
            ("a.com,b.com".to_string(), "ssh-rsa".to_string(), "BBBB".to_string()),
        ];
        assert_eq!(check_host(&e, "github.com", "ssh-ed25519", "AAAA"), HostKeyCheck::Match);
        assert_eq!(check_host(&e, "github.com", "ssh-ed25519", "XXXX"), HostKeyCheck::Mismatch);
        assert_eq!(check_host(&e, "b.com", "ssh-rsa", "BBBB"), HostKeyCheck::Match);
        assert_eq!(check_host(&e, "gitlab.com", "ssh-ed25519", "AAAA"), HostKeyCheck::Unknown);
    }
}
