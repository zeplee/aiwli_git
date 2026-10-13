//! Single JSON dispatcher. The FFI surface is exactly two symbols:
//!   gitdeck_call(method, payloadJson) -> resultJson | {"__err": "..."}
//!   gitdeck_free(ptr)
//! Adding an engine operation = one match arm here + one typed Dart helper.

use serde_json::{json, Value};

use super::git_engine;
use super::ops_branch as ob;
use super::ops_history as oh;
use super::ops_patch as op;
use super::ops_remote as or;
use super::ops_stash as os;
use super::util as ut;

fn s<'a>(v: &'a Value, k: &str) -> Result<&'a str, String> {
    v.get(k).and_then(|x| x.as_str()).ok_or_else(|| format!("缺少参数 {k}"))
}

fn s_opt(v: &Value, k: &str) -> Option<String> {
    v.get(k).and_then(|x| x.as_str()).map(|s| s.to_string())
}

fn b_opt(v: &Value, k: &str, d: bool) -> bool {
    v.get(k).and_then(|x| x.as_bool()).unwrap_or(d)
}

fn i_opt(v: &Value, k: &str, d: i32) -> i32 {
    v.get(k).and_then(|x| x.as_i64()).map(|x| x as i32).unwrap_or(d)
}

fn arr_s(v: &Value, k: &str) -> Vec<String> {
    v.get(k)
        .and_then(|x| x.as_array())
        .map(|a| a.iter().filter_map(|x| x.as_str().map(|s| s.to_string())).collect())
        .unwrap_or_default()
}

fn arr_i(v: &Value, k: &str) -> Vec<i32> {
    v.get(k)
        .and_then(|x| x.as_array())
        .map(|a| a.iter().filter_map(|x| x.as_i64().map(|n| n as i32)).collect())
        .unwrap_or_default()
}

fn ssh_policy(v: &Value) -> or::SshPolicy {
    or::SshPolicy {
        known_hosts_path: s_opt(v, "knownHostsPath").filter(|s| !s.trim().is_empty()),
        accept_unknown: b_opt(v, "acceptUnknownHost", false),
    }
}

fn cred(v: &Value) -> Option<or::CredInput> {
    let c = v.get("cred")?;
    if !c.is_object() {
        return None;
    }
    Some(or::CredInput {
        user: s_opt(c, "user"),
        pass: s_opt(c, "pass"),
        key_path: s_opt(c, "keyPath"),
        passphrase: s_opt(c, "passphrase"),
    })
}

fn commit_entry(e: &git_engine::CommitDiffEntry) -> Value {
    json!({"path": e.path, "code": e.code, "additions": e.additions, "deletions": e.deletions, "patchText": e.patch_text})
}

fn file_status(f: &git_engine::FileStatus) -> Value {
    json!({"path": f.path, "code": f.code})
}

fn commit_info_json(c: &git_engine::CommitInfo) -> Value {
    json!({"id": c.id, "shortId": c.short_id, "summary": c.summary, "message": c.message,
           "author": c.author, "email": c.email, "timeUnix": c.time_unix})
}

/// 各 method 的实际分发。错误统一在 `call` 里落盘（见 util::record_error）。
fn call_inner(method: &str, v: &Value) -> Result<Value, String> {
    match method {
        // ---------- workbench ----------
        "snapshot" => {
            let r = git_engine::get_snapshot(s(v, "path")?.to_string(), i_opt(v, "commitLimit", 50))?;
            Ok(json!({
                "branch": r.branch, "headId": r.head_id, "hasMergeHead": r.has_merge_head,
                "ahead": r.ahead, "behind": r.behind,
                "staged": r.staged.iter().map(file_status).collect::<Vec<_>>(),
                "unstaged": r.unstaged.iter().map(file_status).collect::<Vec<_>>(),
                "untracked": r.untracked,
                "conflicted": r.conflicted,
                "recentCommits": r.recent_commits.iter().map(commit_info_json).collect::<Vec<_>>(),
            }))
        }
        "openRepo" => {
            let r = git_engine::open_repo(s(v, "path")?.to_string())?;
            Ok(json!(r))
        }
        "initRepo" => {
            let r = git_engine::init_repo(s(v, "path")?.to_string())?;
            Ok(json!(r))
        }
        "workdirDiff" => {
            let r = git_engine::get_workdir_diff(
                s(v, "path")?.to_string(),
                s(v, "file")?.to_string(),
                b_opt(v, "staged", false),
            )?;
            Ok(json!(r))
        }
        "commitDiff" => {
            let r = git_engine::get_commit_diff(s(v, "path")?.to_string(), s(v, "commitId")?.to_string())?;
            Ok(json!(r.iter().map(commit_entry).collect::<Vec<_>>()))
        }
        "stage" => {
            git_engine::stage_paths(s(v, "path")?.to_string(), arr_s(v, "files"))?;
            Ok(json!(null))
        }
        "unstage" => {
            git_engine::unstage_paths(s(v, "path")?.to_string(), arr_s(v, "files"))?;
            Ok(json!(null))
        }
        "discard" => {
            git_engine::discard_paths(s(v, "path")?.to_string(), arr_s(v, "files"))?;
            Ok(json!(null))
        }
        "commit" => {
            let r = git_engine::commit_staged(
                s(v, "path")?.to_string(),
                s(v, "message")?.to_string(),
                b_opt(v, "amend", false),
            )?;
            Ok(json!(r))
        }

        // ---------- hunk ops ----------
        "hunks" => {
            let r = op::hunk_list(s(v, "path")?.to_string(), s(v, "file")?.to_string(), b_opt(v, "staged", false))?;
            Ok(json!(r.iter().map(|h| json!({"index": h.index, "header": h.header,
                "oldStart": h.old_start, "oldCount": h.old_count})).collect::<Vec<_>>()))
        }
        "hunkOp" => {
            op::hunk_op(
                s(v, "path")?.to_string(),
                s(v, "file")?.to_string(),
                arr_i(v, "indexes"),
                s(v, "op")?.to_string(),
            )?;
            Ok(json!(null))
        }

        // ---------- branches / tags ----------
        "branches" => {
            let r = ob::branches(s(v, "path")?.to_string())?;
            Ok(json!({
                "current": r.current, "detached": r.detached,
                "local": r.local.iter().map(|b| json!({"name": b.name, "isCurrent": b.is_current,
                    "upstream": b.upstream, "ahead": b.ahead, "behind": b.behind,
                    "targetShort": b.target_short})).collect::<Vec<_>>(),
                "remote": r.remote,
                "tags": r.tags.iter().map(|t| json!({"name": t.name, "targetShort": t.target_short}))
                    .collect::<Vec<_>>(),
            }))
        }
        "checkout" => {
            ob::checkout(s(v, "path")?.to_string(), s(v, "branch")?.to_string())?;
            Ok(json!(null))
        }
        "checkoutCommit" => {
            ob::checkout_commit(s(v, "path")?.to_string(), s(v, "commitId")?.to_string())?;
            Ok(json!(null))
        }
        "branchCreate" => {
            ob::branch_create(s(v, "path")?.to_string(), s(v, "name")?.to_string(), s_opt(v, "fromCommit"))?;
            Ok(json!(null))
        }
        "branchDelete" => {
            ob::branch_delete(s(v, "path")?.to_string(), s(v, "name")?.to_string())?;
            Ok(json!(null))
        }
        "branchRename" => {
            ob::branch_rename(s(v, "path")?.to_string(), s(v, "oldName")?.to_string(), s(v, "newName")?.to_string())?;
            Ok(json!(null))
        }
        "branchSetUpstream" => {
            ob::branch_set_upstream(
                s(v, "path")?.to_string(),
                s(v, "branch")?.to_string(),
                s(v, "upstream")?.to_string(),
            )?;
            Ok(json!(null))
        }
        "tagCreate" => {
            ob::tag_create(s(v, "path")?.to_string(), s(v, "name")?.to_string(), s_opt(v, "commitId"))?;
            Ok(json!(null))
        }
        "tagDelete" => {
            ob::tag_delete(s(v, "path")?.to_string(), s(v, "name")?.to_string())?;
            Ok(json!(null))
        }

        // ---------- history ----------
        "log" => {
            let r = oh::log(
                s(v, "path")?.to_string(),
                i_opt(v, "skip", 0),
                i_opt(v, "limit", 60),
                s_opt(v, "query"),
                s_opt(v, "start"),
            )?;
            Ok(json!(r.iter().map(|e| {
                let mut o = commit_info_json(&e.info);
                o["parents"] = json!(e.parents);
                o["refs"] = json!(e.refs);
                o
            }).collect::<Vec<_>>()))
        }
        "commitDetail" => {
            let (info, parents, files) =
                oh::commit_detail(s(v, "path")?.to_string(), s(v, "commitId")?.to_string())?;
            Ok(json!({"info": commit_info_json(&info), "parents": parents,
                      "files": files.iter().map(commit_entry).collect::<Vec<_>>()}))
        }
        "diffRevs" => {
            let r = oh::diff_revs(
                s(v, "path")?.to_string(),
                s_opt(v, "from").unwrap_or_default(),
                s(v, "to")?.to_string(),
            )?;
            Ok(json!(r.iter().map(commit_entry).collect::<Vec<_>>()))
        }
        "blame" => {
            let r = oh::blame(s(v, "path")?.to_string(), s(v, "file")?.to_string())?;
            Ok(json!(r.iter().map(|l| json!({"lineNo": l.line_no, "commitId": l.commit_id,
                "shortId": l.short_id, "author": l.author, "timeUnix": l.time_unix,
                "summary": l.summary, "content": l.content})).collect::<Vec<_>>()))
        }

        // ---------- history actions ----------
        "reset" => {
            ob::reset(
                s(v, "path")?.to_string(),
                s_opt(v, "commitId"),
                s_opt(v, "mode").unwrap_or_else(|| "mixed".into()),
            )?;
            Ok(json!(null))
        }
        "revert" => {
            let r = ob::revert(s(v, "path")?.to_string(), s(v, "commitId")?.to_string())?;
            Ok(json!(r))
        }
        "cherryPick" => {
            let r = ob::cherry_pick(s(v, "path")?.to_string(), s(v, "commitId")?.to_string())?;
            Ok(json!(r))
        }
        "merge" => {
            let r = ob::merge(s(v, "path")?.to_string(), s(v, "branch")?.to_string())?;
            merge_result(r)
        }
        "mergeCommit" => {
            let r = ob::merge_commit(s(v, "path")?.to_string(), s_opt(v, "message"))?;
            Ok(json!(r))
        }
        "mergeAbort" => {
            ob::merge_abort(s(v, "path")?.to_string())?;
            Ok(json!(null))
        }
        "conflicts" => {
            let r = ob::conflicts(s(v, "path")?.to_string())?;
            Ok(json!(r.iter().map(|f| json!({"path": f.path, "hasOurs": f.has_ours,
                "hasTheirs": f.has_theirs})).collect::<Vec<_>>()))
        }
        "resolveConflict" => {
            ob::resolve_conflict(
                s(v, "path")?.to_string(),
                s(v, "file")?.to_string(),
                s(v, "side")?.to_string(),
            )?;
            Ok(json!(null))
        }

        // ---------- stash ----------
        "stashList" => {
            let r = os::stash_list(s(v, "path")?.to_string())?;
            Ok(json!(r.iter().map(|e| json!({"index": e.index, "id": e.id,
                "message": e.message, "timeUnix": e.time_unix})).collect::<Vec<_>>()))
        }
        "stashPush" => {
            let r = os::stash_push(
                s(v, "path")?.to_string(),
                s_opt(v, "message"),
                b_opt(v, "includeUntracked", true),
            )?;
            Ok(json!(r))
        }
        "stashApply" => {
            os::stash_apply(s(v, "path")?.to_string(), i_opt(v, "index", 0) as usize)?;
            Ok(json!(null))
        }
        "stashPop" => {
            os::stash_pop(s(v, "path")?.to_string(), i_opt(v, "index", 0) as usize)?;
            Ok(json!(null))
        }
        "stashDrop" => {
            os::stash_drop(s(v, "path")?.to_string(), i_opt(v, "index", 0) as usize)?;
            Ok(json!(null))
        }

        // ---------- remotes / sync ----------
        "remotes" => {
            let r = or::remotes(s(v, "path")?.to_string())?;
            Ok(json!(r.iter().map(|x| json!({"name": x.name, "url": x.url})).collect::<Vec<_>>()))
        }
        "fetch" => {
            let r = or::fetch(s(v, "path")?.to_string(), s(v, "remote")?.to_string(), cred(v), &ssh_policy(v))?;
            Ok(json!(r))
        }
        "push" => {
            let r = or::push(
                s(v, "path")?.to_string(),
                s(v, "remote")?.to_string(),
                s(v, "branch")?.to_string(),
                b_opt(v, "setUpstream", false),
                b_opt(v, "force", false),
                cred(v),
                &ssh_policy(v),
            )?;
            Ok(json!(r))
        }
        "tagPush" => {
            let r = or::push_tag(
                s(v, "path")?.to_string(),
                s(v, "remote")?.to_string(),
                s(v, "name")?.to_string(),
                b_opt(v, "force", false),
                cred(v),
                &ssh_policy(v),
            )?;
            Ok(json!(r))
        }
        "pull" => {
            let r = or::pull(s(v, "path")?.to_string(), cred(v), &ssh_policy(v))?;
            merge_result(r)
        }
        "clone" => {
            let r = or::clone_repo(
                s(v, "url")?.to_string(),
                s(v, "path")?.to_string(),
                s_opt(v, "branch"),
                cred(v),
                &ssh_policy(v),
            )?;
            Ok(json!(r))
        }
        "remoteAdd" => {
            or::remote_add(s(v, "path")?.to_string(), s(v, "name")?.to_string(), s(v, "url")?.to_string())?;
            Ok(json!(null))
        }
        "remoteSetUrl" => {
            or::remote_set_url(s(v, "path")?.to_string(), s(v, "name")?.to_string(), s(v, "url")?.to_string())?;
            Ok(json!(null))
        }
        "remoteDelete" => {
            or::remote_delete(s(v, "path")?.to_string(), s(v, "name")?.to_string())?;
            Ok(json!(null))
        }

        // ---------- config / ignore ----------
        "configGet" => {
            let r = or::config_get(s(v, "path")?.to_string())?;
            Ok(json!({"userName": r.user_name, "userEmail": r.user_email}))
        }
        "configSet" => {
            or::config_set(
                s(v, "path")?.to_string(),
                s_opt(v, "userName"),
                s_opt(v, "userEmail"),
            )?;
            Ok(json!(null))
        }
        "ignoreGet" => {
            let r = or::ignore_get(s(v, "path")?.to_string())?;
            Ok(json!(r))
        }
        "ignoreSet" => {
            or::ignore_set(s(v, "path")?.to_string(), s(v, "content")?.to_string())?;
            Ok(json!(null))
        }

        // ---------- TLS 信任库 / 证书校验逃生口 ----------
        // Dart 侧启动时用 setCaDir 把 app 私有目录交进来（CA bundle 落在那里），
        // 之后任何远程操作（clone/fetch/push/pull）都会经 util::init_tls 自动加载。
        "setCaDir" => {
            ut::set_ca_dir(s(v, "dir")?.to_string());
            Ok(tls_json())
        }
        "setSkipTlsVerify" => {
            ut::set_skip_tls_verify(b_opt(v, "skip", false));
            Ok(tls_json())
        }
        "tlsStatus" => Ok(tls_json()),

        // ---------- 导入自签 / 内网 CA ----------
        // 让自签证书的仓库在**校验保持开启**的前提下可用（区别于 setSkipTlsVerify）。
        "caList" => Ok(ca_json()),
        "caImport" => {
            let n = ut::ca_import(
                s_opt(v, "label").unwrap_or_default().as_str(),
                s(v, "pem")?,
            )?;
            let mut j = ca_json();
            j["imported"] = json!(n);
            Ok(j)
        }
        "caRemove" => {
            ut::ca_remove(s(v, "id")?)?;
            Ok(ca_json())
        }

        _ => Err(format!("未知操作 {method}")),
    }
}

/// 引擎唯一入口。所有错误在此**落盘一份原始文本** —— UI 只显示
/// `friendlyError` 分类后的**一句话**，真因（libgit2 的 `class=…; code=…`、
/// OpenSSL 的具体原因）必须留证，否则排障只能靠猜（见 docs/14）。
pub fn call(method: &str, v: &Value) -> Result<Value, String> {
    let r = call_inner(method, v);
    if let Err(e) = &r {
        ut::record_error(method, e);
    }
    r
}

/// 已导入 CA 列表（设置页展示 / 删除用）。
fn ca_json() -> Value {
    let items: Vec<Value> = ut::ca_list()
        .iter()
        .map(|c| {
            json!({
                "id": c.id,
                "label": c.label,
                "count": c.count,
            })
        })
        .collect();
    json!({
        "dir": ut::ca_dir_path(),
        "items": items,
    })
}

/// TLS 状态（设置页展示 / 排障）。
fn tls_json() -> Value {
    let r = ut::init_tls_status();
    let (ok, bundle, error) = match &r {
        Ok(p) => (true, p.clone(), String::new()),
        Err(e) => (false, String::new(), e.clone()),
    };
    json!({
        "ok": ok,
        "bundle": bundle,
        "error": error,
        "skipVerify": ut::skip_tls_verify(),
        "detail": ut::tls_status(),
    })
}

fn merge_result(r: ob::MergeResult) -> Result<Value, String> {
    Ok(json!({"fastForward": r.fast_forward, "upToDate": r.up_to_date,
              "commitId": r.commit_id, "conflicts": r.conflicts}))
}
