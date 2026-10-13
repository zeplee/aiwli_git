//! Shared engine utilities: repo open (owner-check bypass), status mapping,
//! commit info, signatures, diff→patch emission, and a byte-safe unified-diff
//! hunk apply engine (powers hunk-level stage / unstage / discard).

use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, Once};

use git2::{DiffFormat, Repository, Status};

/// libgit2 >= 1.5 validates that .git/config is owned by the current uid
/// (GIT_EOWNER / code -36). On Android, /storage files are owned by
/// root/media_rw through FUSE, so EVERY repo on shared storage trips it.
/// Equivalent of git CLI's `safe.directory`; disabled inside the app sandbox.
static OWNER_CHECK: Once = Once::new();

pub fn open(path: &str) -> Result<Repository, String> {
    OWNER_CHECK.call_once(|| unsafe {
        let _ = git2::opts::set_verify_owner_validation(false);
    });
    Repository::open(Path::new(path)).map_err(|e| format!("打开仓库失败: {e}"))
}

/// Android 上的 HTTPS 信任锚：**必须用 PEM bundle，不能用 CA 目录**。
///
/// vendored OpenSSL 编译进的默认 CA 路径（`/usr/local/ssl/cert.pem`、
/// `/usr/local/ssl/certs`、`/etc/ssl/…`）在 Android 上**一个都不存在** →
/// 信任锚为 0，任何 HTTPS 远程都失败：`the SSL certificate is invalid`
/// （GIT_ERROR_SSL / class=Ssl 16）。
///
/// ⚠️ 曾经的做法是把 CA **目录**（`/system/etc/security/cacerts`）交给
/// `set_ssl_cert_dir`，**这条路在 Android 上是死的**：
///   - Android 系统库的文件名是 `MD5(subject)`（实测 130/130 命中
///     `subject_hash_old`），而 OpenSSL >= 1.0 的哈希目录查找器按
///     `SHA1(subject)` 取 `<hash>.0`（实测 0/130 命中）
///     → 查找时永远找不到任何证书。
///   - 更糟的是 `SSL_CTX_load_verify_locations` 带目录时是**惰性**的：只登记
///     一个哈希目录查找器就返回 1，**不检查目录里有没有证书**。所以
///     `set_ssl_cert_dir(..).is_ok()` 恒为真 —— 看起来"加载成功"，实际信任锚
///     是 0，失败被推迟到握手阶段。这就是这个 bug 一直静默的原因。
///
/// ✅ 现在改成：把系统库里的 PEM 证书**拼成一个 bundle 文件**，用
/// `set_ssl_cert_file()` 加载 —— 完全绕开哈希命名。实测同一台设备：
/// 原样目录 `Verify return code: 20 (unable to get local issuer certificate)`，
/// 拼成 bundle 后 `Verify return code: 0 (ok)`。
static CA_DIR: Mutex<Option<String>> = Mutex::new(None);
/// 已成功应用的 bundle 路径。`None` = 尚未成功，下次调用会重试
/// （**刻意不用 `Once`**：首次失败会把整个进程永久锁在"信任锚为 0"的状态）。
static TLS_APPLIED: Mutex<Option<String>> = Mutex::new(None);
/// 上次信任库扫描的逐目录明细（诊断用）。App 内「设置 → 网络安全」与
/// `<appFilesDir>/gitdeck_ca_diag.txt` 都读它 —— 存在的意义是让
/// 「系统库有 N 个文件、bundle 只有 M 张」这类差异能被**事后解释**，
/// 而不是让一张读不到的 CA 静默消失。
static LAST_SCAN: Mutex<Vec<String>> = Mutex::new(Vec::new());
/// 最近一次「信任锚应用」的逐步诊断（回读 / 一次性加载 / 逐文件回退）。
/// 存在意义：`set_ssl_cert_file` 失败时**必须能看出是哪一层失败**，
/// 否则只能拿到一句 `BIO lib`，无从下手（见 docs/14）。
static LAST_APPLY: Mutex<Vec<String>> = Mutex::new(Vec::new());

/// 逃生口：跳过 TLS 证书校验，等价 GitSync 的
/// `certificate_check(|_, _| Ok(CertificateCheckStatus::CertificateOk))`。
/// **默认关闭**；开启后任何中间人（含 VPN/代理 TLS 拦截）都无法被发现。
static SKIP_TLS_VERIFY: AtomicBool = AtomicBool::new(false);

pub fn set_skip_tls_verify(skip: bool) {
    SKIP_TLS_VERIFY.store(skip, Ordering::SeqCst);
}

pub fn skip_tls_verify() -> bool {
    SKIP_TLS_VERIFY.load(Ordering::SeqCst)
}

/// Dart 侧启动时把 app 私有目录（`getFilesDir()`）交进来，bundle 落在那里。
/// 必须显式传入：App 进程的 `TMPDIR` / `HOME` 都是空的，
/// `std::env::temp_dir()` 会退到并不存在的 `/tmp`，不能靠它落文件。
pub fn set_ca_dir(dir: String) {
    let dir = dir.trim().to_string();
    if dir.is_empty() {
        return;
    }
    let mut g = CA_DIR.lock().unwrap_or_else(|e| e.into_inner());
    if g.as_deref() != Some(dir.as_str()) {
        *g = Some(dir);
        // 换了目录 → bundle 需要重新生成
        *TLS_APPLIED.lock().unwrap_or_else(|e| e.into_inner()) = None;
    }
}

/// 目录身份（用于去重）。
/// unix 上用 dev:inode —— 这是唯一能识别 bind mount 的判据（路径不同、inode 相同）；
/// 非 unix 退化为规范化路径的 FNV-1a 哈希（够用，本工程引擎以 Android 为主）。
#[cfg(unix)]
fn dir_key(p: &Path) -> Option<(u64, u64)> {
    use std::os::unix::fs::MetadataExt;
    let md = std::fs::metadata(p).ok()?;
    Some((md.dev(), md.ino()))
}

#[cfg(not(unix))]
fn dir_key(p: &Path) -> Option<(u64, u64)> {
    let c = std::fs::canonicalize(p).ok()?;
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in c.to_string_lossy().as_bytes() {
        h ^= *b as u64;
        h = h.wrapping_mul(0x100_0000_01b3);
    }
    Some((0, h))
}

/// 系统信任库候选目录：Android 14+ 在 Conscrypt APEX，更早的版本在 /system。
///
/// ⚠️ **必须按 dev:inode 去重**：同一份库常通过多个路径可见
/// （本机实测 `/etc/security/cacerts` 与 `/system/etc/security/cacerts` 就是
/// 同一 `dev:inode` 的 bind mount），不去重会把整个信任库收集两遍，
/// bundle 直接翻倍（实测 400KB / 258 张 vs 应有的 200KB / 129 张）。
fn system_ca_dirs() -> Vec<&'static str> {
    let mut seen: Vec<(u64, u64)> = Vec::new();
    let mut out: Vec<&'static str> = Vec::new();
    for d in [
        "/apex/com.android.conscrypt/cacerts",
        "/system/etc/security/cacerts",
        "/etc/security/cacerts",
    ] {
        let Ok(md) = std::fs::metadata(d) else { continue };
        if !md.is_dir() {
            continue;
        }
        let Some(key) = dir_key(Path::new(d)) else { continue };
        if seen.contains(&key) {
            continue;
        }
        seen.push(key);
        out.push(d);
    }
    out
}

/// 从一段文本里抽出所有 PEM 证书块（多余的文字会被丢弃）。
fn pem_blocks(text: &str) -> String {
    const BEGIN: &str = "-----BEGIN CERTIFICATE-----";
    const END: &str = "-----END CERTIFICATE-----";
    let mut out = String::new();
    let mut rest = text;
    while let Some(b) = rest.find(BEGIN) {
        let Some(e) = rest[b..].find(END) else { break };
        out.push_str(rest[b..b + e + END.len()].trim_end());
        out.push('\n');
        rest = &rest[b + e + END.len()..];
    }
    out
}

/// 单个 CA 目录的扫描统计。存在的意义：**读不到的文件不能被静默丢掉** ——
/// 「系统 130 个文件、bundle 只有 129 张」这类差异必须能在 App 内自证
/// （实测踩过：一张用户装的 MITM 代理 CA 不在 App 的视图里，若无计数则无法区分
/// 「没列出来」和「列出来但读失败」）。
pub struct CaScan {
    pub dir: String,
    pub entries: usize,
    pub files: usize,
    pub read_fail: usize,
    pub no_pem: usize,
    pub blocks: usize,
}

impl CaScan {
    pub fn line(&self) -> String {
        format!(
            "{}: 条目={} 文件={} 读取失败={} 无证书={} 证书={}",
            self.dir, self.entries, self.files, self.read_fail, self.no_pem, self.blocks
        )
    }
}

/// 扫描一个目录，返回 (拼接后的 PEM 正文, 统计)。
fn scan_pem(dir: &str) -> (String, CaScan) {
    let mut st = CaScan {
        dir: dir.to_string(),
        entries: 0,
        files: 0,
        read_fail: 0,
        no_pem: 0,
        blocks: 0,
    };
    let mut out = String::new();
    let Ok(entries) = std::fs::read_dir(dir) else {
        return (out, st);
    };
    for entry in entries.flatten() {
        st.entries += 1;
        let path = entry.path();
        if !path.is_file() {
            continue;
        }
        st.files += 1;
        // ⚠️ 按**字节**读、再 lossy 转字符串：系统库里确实存在不是合法 UTF-8 的文件，
        // 用 read_to_string 会让**整份**证书被静默跳过；PEM 本体是纯 ASCII，
        // 一个无关的非法字节不该毁掉它。
        let Ok(bytes) = std::fs::read(&path) else {
            st.read_fail += 1;
            continue;
        };
        let blocks = pem_blocks(&String::from_utf8_lossy(&bytes));
        if !blocks.contains("BEGIN CERTIFICATE") {
            st.no_pem += 1; // 二进制 DER 或非证书文件
            continue;
        }
        st.blocks += blocks.matches("BEGIN CERTIFICATE").count();
        out.push_str(&blocks);
    }
    (out, st)
}

/// 只要 PEM 正文（其余调用点用）。
#[allow(dead_code)]
fn collect_pem(dir: &str) -> String {
    scan_pem(dir).0
}

/// bundle 的落盘目录：优先 Dart 交进来的 app 私有目录；否则从
/// `/proc/self/cmdline` 反推 `/data/data/<pkg>/files`（Dart 侧还没来得及时的兜底）。
fn bundle_dir() -> Option<String> {
    if let Some(d) = CA_DIR.lock().unwrap_or_else(|e| e.into_inner()).clone() {
        if Path::new(&d).is_dir() {
            return Some(d);
        }
    }
    if let Ok(home) = std::env::var("HOME") {
        let home = home.trim();
        if !home.is_empty() && Path::new(home).is_dir() {
            return Some(home.to_string());
        }
    }
    if let Ok(raw) = std::fs::read("/proc/self/cmdline") {
        let pkg = String::from_utf8_lossy(&raw)
            .split('\0')
            .next()
            .unwrap_or("")
            .trim()
            .to_string();
        if !pkg.is_empty() && pkg.contains('.') {
            for base in ["/data/data", "/data/user/0"] {
                let d = format!("{base}/{pkg}/files");
                if Path::new(&d).is_dir() {
                    return Some(d);
                }
            }
        }
    }
    None
}

/// 幂等：成功应用过就直接返回（bundle 已生效）；失败**不缓存**，下次重试。
fn init_tls_inner() -> Result<String, String> {
    if let Some(p) = TLS_APPLIED.lock().unwrap_or_else(|e| e.into_inner()).clone() {
        return Ok(p);
    }
    let dirs = system_ca_dirs();
    if dirs.is_empty() {
        return Err("找不到 Android 系统信任库目录".into());
    }
    let mut scans: Vec<CaScan> = Vec::new();
    let mut system_pem = String::new();
    for d in &dirs {
        let (pem, st) = scan_pem(d);
        system_pem.push_str(&pem);
        scans.push(st);
    }
    if !system_pem.contains("BEGIN CERTIFICATE") {
        return Err(format!("系统信任库为空或不是 PEM 文本: {dirs:?}"));
    }
    let dir = bundle_dir()
        .ok_or("没有可写目录存放 CA bundle（Dart 侧未传 appFilesDir）")?;
    // 用户导入的自签 / 内网 CA 拼在系统 CA 之后（见 §导入自签 CA）。
    // bundle = 系统信任库 + 用户 CA，一次 set_ssl_cert_file 两者都进去。
    let (user_pem, user_scan) = scan_pem(&user_ca_dir_in(&dir));
    scans.push(user_scan);
    let pem = format!("{system_pem}{user_pem}");
    let path = format!("{dir}/gitdeck_ca_bundle.pem");
    std::fs::write(&path, pem.as_bytes()).map_err(|e| format!("写入 CA bundle 失败: {e}"))?;
    // 诊断落盘（排障用；见 LAST_SCAN 注释）。
    let total: usize = scans.iter().map(|s| s.blocks).sum();
    let skipped: usize = scans.iter().map(|s| s.read_fail + s.no_pem).sum();
    let mut diag = format!("bundle={path}\n证书总数={total} 跳过={skipped}\n");
    for s in &scans {
        diag.push_str(&s.line());
        diag.push('\n');
    }
    diag.push_str(&format!("跳过校验={}\n", skip_tls_verify()));
    *LAST_SCAN.lock().unwrap_or_else(|e| e.into_inner()) =
        scans.iter().map(|s| s.line()).collect();
    // ⚠️ bundle 文件写成功 ≠ libgit2 用上了它。上一版只把"文件已写好"当验收，
    // 于是"bundle 有效"被误当成"信任锚已就位"，出现验收缺口（见 docs/14）。
    // 这里把每一层的真实结果都记下来，并在失败时**回退**。
    // 另注：libgit2 的 SSL_CTX 在首次 TLS 操作时按第一次的配置建好，
    // 之后 `set_ssl_cert_file` 是**追加**到同一个 store（中途换 bundle 也能生效，
    // 但移除证书要重启进程）。
    let mut notes: Vec<String> = Vec::new();

    // ① 回读自检：这一步就失败 ⇒ 问题在文件/权限/标签，而不在 OpenSSL。
    match std::fs::read(&path) {
        Ok(b) => notes.push(format!("回读 bundle: {} 字节 ok", b.len())),
        Err(e) => notes.push(format!(
            "回读 bundle 失败: {e} (errno={:?})",
            e.raw_os_error()
        )),
    }

    // ② 主路径：**内存注入** —— no-stdio 构建下唯一可行的方式
    //    （见上方「内存方式装载信任锚」）。
    let mut applied = match add_certs_from_pem(&pem) {
        Ok((added, parsed)) => {
            notes.push(format!("内存注入 X509: 加入 {added}/{parsed} 张"));
            if added > 0 {
                Ok(())
            } else {
                Err("内存注入没有加入任何证书".to_string())
            }
        }
        Err(e) => {
            notes.push(format!("内存注入 X509 失败: {e}"));
            Err(e)
        }
    };

    // ③ 兜底：文件方式。在本构建下**预期必然失败**（OpenSSL 为 no-stdio，
    //    `BIO_new_file` 不存在 → ERR_R_BIO_LIB）；保留它只为在别的构建配置下
    //    仍能用文件路径，并留下对照证据。逐文件方式已证明无效（129/129 全失败），
    //    故不再使用。
    if applied.is_err() {
        match unsafe { git2::opts::set_ssl_cert_file(&path) } {
            Ok(()) => {
                notes.push("文件方式加载 = ok（与本构建 no-stdio 的预期不符，供对照）".into());
                applied = Ok(());
            }
            Err(e) => notes.push(format!("文件方式加载失败（预期）: {e}")),
        }
    }

    for n in &notes {
        diag.push_str("· ");
        diag.push_str(n);
        diag.push('\n');
    }
    let _ = std::fs::write(format!("{dir}/gitdeck_ca_diag.txt"), diag.as_bytes());
    *LAST_APPLY.lock().unwrap_or_else(|e| e.into_inner()) = notes.clone();

    if let Err(e) = &applied {
        // 逐步诊断一并抛出：UI 只显示这一句，必须自带定位信息。
        return Err(format!("加载信任锚失败: {e}\n{}", notes.join("\n")));
    }
    *TLS_APPLIED.lock().unwrap_or_else(|e| e.into_inner()) = Some(path.clone());
    Ok(path)
}

// ---------- 内存方式装载信任锚（no-stdio 构建下唯一可行的路）----------
//
// ⚠️ 实测结论（docs/14）：vendored OpenSSL（openssl-src）是 **no-stdio** 构建 ——
// 它生成的 `configuration.h` 里 `#define OPENSSL_NO_STDIO`。后果是 OpenSSL 内部
// 根本没有 `BIO_new_file`/`fopen`，于是**任何**"从文件加载 CA"都必然失败：
//   - `set_ssl_cert_dir`（1.5.12）：目录查找器同样基于文件 → 静默无效
//   - `set_ssl_cert_file`（1.5.13）：`SSL_CTX_load_verify_locations(file)`
//     → `BIO_new_file` 返回 NULL → `ERR_R_BIO_LIB`，就是那句 "BIO lib"
//   - 逐文件回退（本轮实测）：把 129 个系统证书逐个喂进去 → **129/129 全失败**
// 而 libgit2 提供了不碰文件的入口：
//   `GIT_OPT_ADD_SSL_X509_CERT` → `X509_STORE_add_cert(get_cert_store(git__ssl_ctx), cert)`
// 所以信任锚必须走**内存**：PEM → `BIO_new_mem_buf` → `PEM_read_bio_X509` → 注入。
mod lg2_ffi {
    use std::os::raw::c_int;

    extern "C" {
        /// libgit2 的 `git_libgit2_opts` 是 variadic，bindgen 不会为它生成绑定；
        /// 符号由 libgit2 静态链进本 .so，链接期可见，故直接声明。
        pub fn git_libgit2_opts(option: c_int, ...) -> c_int;

        /// **必须先调用它**。`GIT_OPT_ADD_SSL_X509_CERT` 会访问 libgit2 内部的
        /// `git__ssl_ctx`，而该对象由 `git_openssl_stream_global_init()` 在
        /// `git_libgit2_init()` 时才创建。跳过这一步 → `SSL_CTX_get_cert_store(NULL)`
        /// → NULL 解引用崩溃（实测 SIGSEGV / fault addr 0x28）。
        /// 注意 `git2::opts::*` 内部会先 `crate::init()`，所以走 git2 封装是安全的
        /// —— 这也正是文件方式当初"只是失败、没有崩"的原因。
        pub fn git_libgit2_init() -> c_int;
    }

    /// `GIT_OPT_ADD_SSL_X509_CERT`：libgit2 1.9 `git2/common.h` 里的枚举序号。
    /// 钉成常量而非依赖绑定 —— 该枚举新增项只追加在尾部，序号稳定。
    pub const GIT_OPT_ADD_SSL_X509_CERT: c_int = 45;
}

/// 把一段 PEM 里的**所有**证书经内存路径加进 libgit2 的信任库。
///
/// 返回 `(成功加入数, 解析出的证书数)`。重复证书会被 `X509_STORE_add_cert` 拒绝，
/// 所以多次调用时 `added` 变小是正常的、幂等的表现。
fn add_certs_from_pem(pem: &str) -> Result<(usize, usize), String> {
    use std::os::raw::{c_int, c_void};

    unsafe {
        // 幂等：确保 libgit2 已初始化。否则 git__ssl_ctx 仍是 NULL，
        // 下面的 GIT_OPT_ADD_SSL_X509_CERT 会空指针解引用崩溃。
        lg2_ffi::git_libgit2_init();

        // 内存 BIO：不涉及文件系统，因此在 no-stdio 构建下依然可用。
        let bio = openssl_sys::BIO_new_mem_buf(pem.as_ptr() as *const c_void, pem.len() as c_int);
        if bio.is_null() {
            return Err("BIO_new_mem_buf 失败".into());
        }
        let mut parsed = 0usize;
        let mut added = 0usize;
        loop {
            let x = openssl_sys::PEM_read_bio_X509(
                bio,
                std::ptr::null_mut(),
                None,
                std::ptr::null_mut(),
            );
            if x.is_null() {
                break; // PEM 用尽
            }
            parsed += 1;
            if lg2_ffi::git_libgit2_opts(lg2_ffi::GIT_OPT_ADD_SSL_X509_CERT, x) == 0 {
                added += 1;
            }
            openssl_sys::X509_free(x);
        }
        openssl_sys::BIO_free_all(bio);
        if parsed == 0 {
            return Err("PEM 里没有解析出任何证书".into());
        }
        Ok((added, parsed))
    }
}

/// 把引擎错误追加落盘（`<appFilesDir>/gitdeck_error.log`），供事后排障。
///
/// 为什么必须落盘：UI 只显示 `friendlyError` 分类后的**一句话**，原始错误
/// （含 libgit2 的 `class=…; code=…`、OpenSSL 的具体原因）一旦被分类文案
/// 覆盖就再也拿不到 —— 这次"网络连接失败"的定位成本全花在这上面（见 docs/14）。
pub fn record_error(method: &str, err: &str) {
    let Some(dir) = bundle_dir() else {
        return;
    };
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let applied = TLS_APPLIED
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
        .unwrap_or_else(|| "(未应用)".into());
    let line = format!(
        "[{ts}] {method}\n{err}\n[tls] bundle={applied} 跳过校验={}\n---\n",
        skip_tls_verify()
    );
    let path = format!("{dir}/gitdeck_error.log");
    // 超过 128KB 只留尾部，避免无限增长。
    if let Ok(md) = std::fs::metadata(&path) {
        if md.len() > 128 * 1024 {
            if let Ok(txt) = std::fs::read_to_string(&path) {
                let n = txt.chars().count();
                let tail: String = txt.chars().skip(n.saturating_sub(32 * 1024)).collect();
                let _ = std::fs::write(&path, tail);
            }
        }
    }
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
    {
        use std::io::Write;
        let _ = f.write_all(line.as_bytes());
    }
}

/// 调用点保持无返回值，避免每个远程操作都要处理 Result。
/// 失败时错误由 `transport_hint` / 设置页的诊断项暴露，**并落盘一份** ——
/// 静默吞掉正是"信任锚为 0"能长期不可见的原因。
pub fn init_tls() {
    if let Err(e) = init_tls_inner() {
        record_error("initTls", &e);
    }
}

/// 诊断/排障用（设置页与 dispatch 的 `tlsStatus`）。
pub fn init_tls_status() -> Result<String, String> {
    init_tls_inner()
}

/// 多行诊断文本（设置页「网络安全」显示的内容；与落盘的
/// `gitdeck_ca_diag.txt` 同源）。逐目录给出条目/文件/读取失败/无证书/证书数 ——
/// 这样「系统库 130 个文件、bundle 只有 129 张」能一眼看出是哪一类。
pub fn tls_status() -> String {
    let applied = TLS_APPLIED
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
        .unwrap_or_else(|| "(未应用)".into());
    let scans = LAST_SCAN.lock().unwrap_or_else(|e| e.into_inner()).clone();
    let mut out = format!("bundle={applied} 跳过校验={}\n", skip_tls_verify());
    if scans.is_empty() {
        out.push_str("（尚未扫描：还没有远程操作触达信任库）");
    } else {
        for l in &scans {
            out.push_str(l);
            out.push('\n');
        }
    }
    let apply = LAST_APPLY.lock().unwrap_or_else(|e| e.into_inner()).clone();
    for l in &apply {
        out.push_str("· ");
        out.push_str(l);
        out.push('\n');
    }
    out.trim_end().to_string()
}

// ---------- 导入自签 / 内网 CA ----------
//
// 自签名证书不在 Android 系统信任库里，所以「校验开启」时被拒是**正确行为**。
// 要让自签仓库在**校验保持开启**的前提下可用，只有一条正路：
// **握手之前**把它的 CA 变成信任锚。bundle 管道已经有了，所以这只是在拼 bundle 时
// 多拼一段 PEM —— 不需要任何新机制。
//
// 为什么不能在 certificate_check 回调里"补链"：libgit2 的 streams/openssl.c 用
// `X509_get_peer_certificate` + `i2d_X509` 交给回调，回调**只拿得到叶子证书**、
// 没有中间证书，重建不了链。回调只能"放行 / 拒绝"，而"放行"就是 GitSync
// 那条无校验的路（见 x509_verdict）。

/// 用户 CA 目录（在 app 私有目录下，与 bundle 同级）。
fn user_ca_dir_in(base: &str) -> String {
    format!("{base}/gitdeck_user_ca")
}

/// 已存在的用户 CA 目录；不存在返回 None（不在这里创建，避免只读场景报错）。
fn user_ca_dir() -> Option<String> {
    let d = user_ca_dir_in(&bundle_dir()?);
    if Path::new(&d).is_dir() {
        Some(d)
    } else {
        None
    }
}

/// 一个已导入的 CA。
/// 单文件格式 = `# label: 名称` + 若干 PEM 块
/// （PEM 解析器只看 BEGIN/END 之间的内容，标签行不影响校验）。
pub struct UserCa {
    pub id: String,
    pub label: String,
    pub count: usize,
}

/// 用户 CA 目录的展示路径（设置页要显示）。
pub fn ca_dir_path() -> String {
    match user_ca_dir() {
        Some(d) => d,
        None => bundle_dir()
            .map(|b| user_ca_dir_in(&b))
            .unwrap_or_else(|| "(未确定)".into()),
    }
}

/// 列出已导入的 CA（按 id 排序）。
pub fn ca_list() -> Vec<UserCa> {
    let Some(dir) = user_ca_dir() else {
        return Vec::new();
    };
    let Ok(entries) = std::fs::read_dir(&dir) else {
        return Vec::new();
    };
    let mut out: Vec<UserCa> = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_file() {
            continue;
        }
        let Some(id) = path.file_name().and_then(|s| s.to_str()).map(|s| s.to_string()) else {
            continue;
        };
        let Ok(text) = std::fs::read_to_string(&path) else {
            continue;
        };
        let label = text
            .lines()
            .find_map(|l| l.trim().strip_prefix("# label:"))
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| id.trim_end_matches(".pem").to_string());
        out.push(UserCa {
            id,
            label,
            count: text.matches("BEGIN CERTIFICATE").count(),
        });
    }
    out.sort_by(|a, b| a.id.cmp(&b.id));
    out
}

/// 导入一份 PEM（可含多张证书），返回证书张数。
///
/// 导入后立刻重建 bundle 并重新 apply：`set_ssl_cert_file` 是**追加**语义
/// （往同一个 SSL_CTX store 里加），所以**当场生效、不需要重启**。
pub fn ca_import(label: &str, pem: &str) -> Result<usize, String> {
    let blocks = pem_blocks(pem);
    let count = blocks.matches("BEGIN CERTIFICATE").count();
    if count == 0 {
        return Err("没有找到 PEM 证书块（应包含 -----BEGIN CERTIFICATE-----）".into());
    }
    let base = bundle_dir().ok_or("没有可写目录（Dart 侧未传 appFilesDir）")?;
    let dir = user_ca_dir_in(&base);
    std::fs::create_dir_all(&dir).map_err(|e| format!("创建目录失败: {e}"))?;
    let label = label.trim().replace(['\n', '\r'], " ");
    let label = if label.is_empty() { "未命名 CA".to_string() } else { label };
    let id = format!(
        "{}.pem",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0)
    );
    std::fs::write(format!("{dir}/{id}"), format!("# label: {label}\n{blocks}").as_bytes())
        .map_err(|e| format!("写入失败: {e}"))?;
    reload_tls()?;
    Ok(count)
}

/// 删除一个已导入的 CA。
///
/// ⚠️ 删除**不会**在当次进程内撤销信任：OpenSSL 的证书 store 只能加不能减，
/// 必须重启应用才彻底生效 —— UI 上要写清（否则用户以为删掉了其实还在信任）。
pub fn ca_remove(id: &str) -> Result<(), String> {
    if id.is_empty()
        || !id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '_' || c == '-')
    {
        return Err("非法 id".into());
    }
    let dir = user_ca_dir().ok_or("没有已导入的 CA")?;
    let path = format!("{dir}/{id}");
    if !Path::new(&path).is_file() {
        return Err(format!("不存在: {id}"));
    }
    std::fs::remove_file(&path).map_err(|e| format!("删除失败: {e}"))?;
    // 重建 bundle（本次不生效，但下次启动会读到不含它的一份）
    let _ = reload_tls();
    Ok(())
}

/// 强制重建 bundle 并重新 apply（导入 CA 后调用）。
fn reload_tls() -> Result<String, String> {
    *TLS_APPLIED.lock().unwrap_or_else(|e| e.into_inner()) = None;
    init_tls_inner()
}

pub fn status_code_to_char(s: Status, index_side: bool) -> Option<String> {
    let picked = if index_side {
        s.intersects(
            Status::INDEX_NEW | Status::INDEX_MODIFIED | Status::INDEX_DELETED
                | Status::INDEX_RENAMED | Status::INDEX_TYPECHANGE,
        )
    } else {
        s.intersects(
            Status::WT_MODIFIED | Status::WT_DELETED | Status::WT_RENAMED | Status::WT_TYPECHANGE,
        )
    };
    if !picked {
        return None;
    }
    let c = if index_side {
        if s.contains(Status::INDEX_NEW) {
            'A'
        } else if s.contains(Status::INDEX_DELETED) {
            'D'
        } else if s.contains(Status::INDEX_RENAMED) {
            'R'
        } else if s.contains(Status::INDEX_TYPECHANGE) {
            'T'
        } else {
            'M'
        }
    } else if s.contains(Status::WT_DELETED) {
        'D'
    } else if s.contains(Status::WT_RENAMED) {
        'R'
    } else if s.contains(Status::WT_TYPECHANGE) {
        'T'
    } else {
        'M'
    };
    Some(c.to_string())
}

pub fn commit_info(c: &git2::Commit) -> crate::api::git_engine::CommitInfo {
    crate::api::git_engine::CommitInfo {
        id: c.id().to_string(),
        short_id: c.id().to_string()[..7.min(c.id().to_string().len())].to_string(),
        summary: c.summary().unwrap_or("(no message)").to_string(),
        message: c.message().unwrap_or("").to_string(),
        author: c.author().name().unwrap_or("").to_string(),
        email: c.author().email().unwrap_or("").to_string(),
        time_unix: c.time().seconds(),
    }
}

pub fn signature(repo: &Repository) -> Result<git2::Signature<'static>, String> {
    let sig = repo
        .signature()
        .or_else(|_| git2::Signature::now("AiwliGit", "aiwligit@local"))
        .map_err(|e| format!("签名失败: {e}"))?;
    let name = sig.name().unwrap_or("AiwliGit").to_string();
    let email = sig.email().unwrap_or("aiwligit@local").to_string();
    git2::Signature::now(&name, &email).map_err(|e| format!("签名失败: {e}"))
}

/// Unified patch text (file + hunk headers included, body lines only).
pub fn diff_to_patch(diff: &mut git2::Diff) -> Vec<u8> {
    let mut out: Vec<u8> = Vec::new();
    let _ = diff.print(DiffFormat::Patch, |_delta, _hunk, line| {
        match line.origin() {
            '+' | '-' | ' ' | 'F' | 'H' => out.push(line.origin() as u8),
            _ => {}
        }
        out.extend_from_slice(line.content());
        true
    });
    out
}

/// Diff rendered as plain text (no headers), for display.
pub fn diff_to_text(diff: &mut git2::Diff) -> String {
    let mut out = String::new();
    let _ = diff.print(DiffFormat::Patch, |_delta, _hunk, line| {
        match line.origin() {
            '+' | '-' | ' ' => out.push(line.origin()),
            _ => {}
        }
        out.push_str(&String::from_utf8_lossy(line.content()));
        true
    });
    out
}

pub fn diff_stats_nums(diff: &git2::Diff) -> (i32, i32) {
    match diff.stats() {
        Ok(s) => (s.insertions() as i32, s.deletions() as i32),
        Err(_) => (0, 0),
    }
}

// ---------- blob / file content helpers ----------

pub fn head_blob(repo: &Repository, path: &str) -> Result<Option<Vec<u8>>, String> {
    let Ok(head) = repo.head() else { return Ok(None) };
    let tree = head.peel_to_tree().map_err(|e| e.to_string())?;
    let Some(entry) = tree.get_path(Path::new(path)).ok() else {
        return Ok(None);
    };
    let blob = repo.find_blob(entry.id()).map_err(|e| e.to_string())?;
    Ok(Some(blob.content().to_vec()))
}

pub fn read_index_blob(repo: &Repository, index: &mut git2::Index, path: &str) -> Option<Vec<u8>> {
    let entry = index.get_path(Path::new(path), 0)?;
    let blob = repo.find_blob(entry.id).ok()?;
    Some(blob.content().to_vec())
}

pub fn workdir_path(repo: &Repository, rel: &str) -> Result<std::path::PathBuf, String> {
    let wd = repo.workdir().ok_or("裸仓库没有工作树")?;
    Ok(wd.join(rel))
}

pub fn read_workdir(repo: &Repository, rel: &str) -> Result<Option<Vec<u8>>, String> {
    let p = workdir_path(repo, rel)?;
    if !p.exists() {
        return Ok(None);
    }
    std::fs::read(&p).map(Some).map_err(|e| format!("读取文件失败: {e}"))
}

pub fn is_binary(b: &[u8]) -> bool {
    b.iter().take(8000).any(|&c| c == 0)
}

// ---------- hunk engine (all byte-level, no lossy text round-trips) ----------

#[derive(Debug, Clone)]
pub struct Hunk {
    pub old_start: usize,
    pub old_count: usize,
    pub new_start: usize,
    pub new_count: usize,
    /// (origin char b' '/b'+'/b'-', content incl. trailing newline if present)
    pub lines: Vec<(u8, Vec<u8>)>,
}

fn parse_hunk_header(l: &[u8]) -> Option<(usize, usize, usize, usize)> {
    let s = String::from_utf8_lossy(l);
    let core = s.split("@@").nth(1)?;
    let mut parts = core.trim().split_whitespace();
    let old = parts.next()?.trim_start_matches('-');
    let new = parts.next()?.trim_start_matches('+');
    let parse = |x: &str| -> (usize, usize) {
        match x.split_once(',') {
            Some((a, b)) => (a.parse().unwrap_or(1), b.parse().unwrap_or(1)),
            None => (x.parse().unwrap_or(1), 1),
        }
    };
    let (os, oc) = parse(old);
    let (ns, nc) = parse(new);
    Some((os, oc, ns, nc))
}

/// Extract hunks (in order) from a unified patch produced by diff_to_patch.
pub fn parse_hunks(patch: &[u8]) -> Vec<Hunk> {
    let lines = split_lines(patch);
    let mut hunks: Vec<Hunk> = Vec::new();
    let mut in_body = false;
    for l in &lines {
        if l.starts_with(b"@@") {
            if let Some((os, oc, ns, nc)) = parse_hunk_header(l) {
                hunks.push(Hunk { old_start: os, old_count: oc, new_start: ns, new_count: nc, lines: Vec::new() });
                in_body = true;
                continue;
            }
        }
        if !in_body || hunks.is_empty() {
            continue;
        }
        let c = l[0];
        match c {
            b' ' | b'+' | b'-' => {
                if l.starts_with(b"--- ") || l.starts_with(b"+++ ") {
                    // next file's header — stop (single-file patches won't hit this)
                    continue;
                }
                hunks.last_mut().unwrap().lines.push((c, l.clone()));
            }
            b'\\' => { /* "\ No newline at end of file" */ }
            _ => { in_body = false; }
        }
    }
    hunks.retain(|h| !h.lines.is_empty());
    hunks
}

pub fn split_lines(b: &[u8]) -> Vec<Vec<u8>> {
    let mut out = Vec::new();
    let mut start = 0usize;
    for i in 0..b.len() {
        if b[i] == b'\n' {
            out.push(b[start..=i].to_vec());
            start = i + 1;
        }
    }
    if start < b.len() {
        out.push(b[start..].to_vec());
    }
    out
}

fn join_lines(lines: &[Vec<u8>]) -> Vec<u8> {
    let mut out = Vec::with_capacity(lines.iter().map(|l| l.len()).sum());
    for l in lines {
        out.extend_from_slice(l);
    }
    out
}

/// Apply hunks onto `base`. forward=true replaces old-range with new-range
/// (stage); forward=false applies in reverse (unstage/discard).
/// Context and removed lines are verified against base — mismatch is an error,
/// never silent corruption.
pub fn apply_hunks(base: &[u8], hunks: &[Hunk], forward: bool) -> Result<Vec<u8>, String> {
    let blines = split_lines(base);
    let mut out: Vec<Vec<u8>> = Vec::new();
    let mut cur = 0usize;
    for h in hunks {
        let (os, _oc) = if forward { (h.old_start, h.old_count) } else { (h.new_start, h.new_count) };
        let start0 = if os == 0 { 0 } else { os.saturating_sub(1) };
        if start0 > blines.len() || start0 < cur {
            return Err("补丁与目标内容不匹配（文件已变化？）请刷新后重试".into());
        }
        for i in cur..start0 {
            out.push(blines[i].clone());
        }
        cur = start0;
        for (c, l) in &h.lines {
            let removes = if forward { *c == b'-' } else { *c == b'+' };
            let adds = if forward { *c == b'+' } else { *c == b'-' };
            if *c == b' ' {
                if cur >= blines.len() || &blines[cur] != l {
                    return Err("上下文不匹配（文件已变化？）请刷新后重试".into());
                }
                out.push(blines[cur].clone());
                cur += 1;
            } else if removes {
                if cur >= blines.len() || &blines[cur] != l {
                    return Err("删除行不匹配（文件已变化？）请刷新后重试".into());
                }
                cur += 1;
            } else if adds {
                out.push(l.clone());
            }
        }
    }
    while cur < blines.len() {
        out.push(blines[cur].clone());
        cur += 1;
    }
    Ok(join_lines(&out))
}

/// Resolve a short rev (branch / tag / short hash / "HEAD~1") to a commit.
pub fn rev_to_commit<'r>(repo: &'r Repository, rev: &str) -> Result<git2::Commit<'r>, String> {
    let obj = repo
        .revparse_single(rev.trim())
        .map_err(|e| format!("无法解析 {rev}: {e}"))?;
    obj.peel_to_commit().map_err(|e| format!("{rev} 不是提交: {e}"))
}
