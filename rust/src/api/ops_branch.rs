//! Branch / tag management, merge, reset, revert, cherry-pick, conflict ops.

use std::path::Path;

use git2::build::CheckoutBuilder;
use git2::{BranchType, ResetType};

use super::util::{open, rev_to_commit, signature, workdir_path};

pub struct BranchInfo {
    pub name: String,
    pub is_current: bool,
    pub upstream: Option<String>,
    pub ahead: i32,
    pub behind: i32,
    pub target_short: String,
}

pub struct TagInfo {
    pub name: String,
    pub target_short: String,
}

pub struct BranchesResult {
    pub current: String,
    pub detached: bool,
    pub local: Vec<BranchInfo>,
    pub remote: Vec<String>,
    pub tags: Vec<TagInfo>,
}

pub struct MergeResult {
    pub fast_forward: bool,
    pub up_to_date: bool,
    pub commit_id: Option<String>,
    pub conflicts: Vec<String>,
}

fn is_repo_dirty(repo: &git2::Repository) -> bool {
    let mut opts = git2::StatusOptions::new();
    opts.include_untracked(true);
    repo.statuses(Some(&mut opts)).map(|s| !s.is_empty()).unwrap_or(true)
}

fn conflicted_files(index: &git2::Index) -> Vec<String> {
    let mut v = Vec::new();
    if let Ok(cs) = index.conflicts() {
        for c in cs.flatten() {
            if let Some(e) = c.our.or(c.their).or(c.ancestor) {
                let p = String::from_utf8_lossy(&e.path).to_string();
                if !v.contains(&p) {
                    v.push(p);
                }
            }
        }
    }
    v
}

pub fn branches(path: String) -> Result<BranchesResult, String> {
    let repo = open(&path)?;
    let head = repo.head().ok();
    let detached = head.as_ref().map(|h| h.is_branch()).map(|b| !b).unwrap_or(false);
    let current = head
        .as_ref()
        .filter(|h| h.is_branch())
        .and_then(|h| h.shorthand().map(|s| s.to_string()))
        .unwrap_or_default();

    let mut local = Vec::new();
    for item in repo.branches(Some(BranchType::Local)).map_err(|e| e.to_string())? {
        let (br, _) = item.map_err(|e| e.to_string())?;
        let name = br.name().ok().flatten().unwrap_or("").to_string();
        if name.is_empty() {
            continue;
        }
        let target = br.get().target().map(|t| t.to_string()).unwrap_or_default();
        let short = target.chars().take(7).collect();
        let (upstream, ahead, behind) = match br.upstream() {
            Ok(up) => {
                let upname = up.name().ok().flatten().unwrap_or("").to_string();
                let (mut a, mut b) = (0, 0);
                if let (Some(lid), Some(uid)) = (br.get().target(), up.get().target()) {
                    if let Ok((x, y)) = repo.graph_ahead_behind(lid, uid) {
                        a = x as i32;
                        b = y as i32;
                    }
                }
                (Some(upname), a, b)
            }
            Err(_) => (None, 0, 0),
        };
        let is_current = !detached && name == current;
        local.push(BranchInfo { name, is_current, upstream, ahead, behind, target_short: short });
    }

    let mut remote = Vec::new();
    for item in repo.branches(Some(BranchType::Remote)).map_err(|e| e.to_string())? {
        let (br, _) = item.map_err(|e| e.to_string())?;
        if let Ok(Some(n)) = br.name() {
            if !n.ends_with("/HEAD") {
                remote.push(n.to_string());
            }
        }
    }
    remote.sort();

    let mut tags = Vec::new();
    let names = repo.tag_names(None).map_err(|e| e.to_string())?;
    for n in names.iter().flatten() {
        let short = repo
            .refname_to_id(&format!("refs/tags/{n}"))
            .ok()
            .map(|id| id.to_string().chars().take(7).collect())
            .unwrap_or_default();
        tags.push(TagInfo { name: n.to_string(), target_short: short });
    }

    Ok(BranchesResult { current, detached, local, remote, tags })
}

/// Checkout a branch by short name. `origin/x` creates a local tracking branch.
pub fn checkout(path: String, branch: String) -> Result<(), String> {
    let repo = open(&path)?;
    if is_repo_dirty(&repo) {
        return Err("工作树有未提交变更，先提交、暂存或丢弃再切换".into());
    }
    let full = format!("refs/heads/{branch}");
    if repo.find_reference(&full).is_ok() {
        repo.set_head(&full).map_err(|e| format!("切换失败: {e}"))?;
        repo.checkout_head(Some(CheckoutBuilder::new().force()))
            .map_err(|e| format!("更新工作树失败: {e}"))?;
        return Ok(());
    }
    // remote branch → create local tracking branch
    let rfull = format!("refs/remotes/{branch}");
    let rref = repo
        .find_reference(&rfull)
        .map_err(|_| format!("找不到分支 {branch}"))?;
    let target = rref.target().ok_or("远程分支无目标")?;
    let local_name = branch.split_once('/').map(|(_, rest)| rest).unwrap_or(&branch).to_string();
    let commit = repo.find_commit(target).map_err(|e| e.to_string())?;
    let mut nb = repo.branch(&local_name, &commit, false).map_err(|e| format!("创建本地分支失败: {e}"))?;
    nb.set_upstream(Some(&branch)).ok();
    repo.set_head(&format!("refs/heads/{local_name}")).map_err(|e| e.to_string())?;
    repo.checkout_head(Some(CheckoutBuilder::new().force()))
        .map_err(|e| format!("更新工作树失败: {e}"))?;
    Ok(())
}

/// Detached-HEAD checkout of an arbitrary commit (NOT a branch reset).
/// `checkout` moves a branch ref; this one only detaches HEAD, so no
/// commit is lost — the safe "look at this commit" operation.
pub fn checkout_commit(path: String, commit_id: String) -> Result<(), String> {
    let repo = open(&path)?;
    if is_repo_dirty(&repo) {
        return Err("工作树有未提交变更，先提交、暂存或丢弃再检出".into());
    }
    let commit = rev_to_commit(&repo, &commit_id)?;
    repo.set_head_detached(commit.id())
        .map_err(|e| format!("检出失败: {e}"))?;
    repo.checkout_head(Some(CheckoutBuilder::new().force()))
        .map_err(|e| format!("更新工作树失败: {e}"))?;
    Ok(())
}

pub fn branch_create(path: String, name: String, from_commit: Option<String>) -> Result<(), String> {
    let repo = open(&path)?;
    let commit = match from_commit {
        Some(c) if !c.is_empty() => rev_to_commit(&repo, &c)?,
        _ => repo
            .head()
            .map_err(|_| "空仓库无法建分支")?
            .peel_to_commit()
            .map_err(|e| e.to_string())?,
    };
    repo.branch(&name, &commit, false).map_err(|e| format!("创建失败: {e}"))?;
    Ok(())
}

pub fn branch_delete(path: String, name: String) -> Result<(), String> {
    let repo = open(&path)?;
    let mut br = repo
        .find_branch(&name, BranchType::Local)
        .map_err(|e| format!("找不到本地分支 {name}: {e}"))?;
    if br.is_head() {
        return Err("不能删除当前所在分支".into());
    }
    br.delete().map_err(|e| format!("删除失败: {e}"))?;
    Ok(())
}

pub fn branch_rename(path: String, old_name: String, new_name: String) -> Result<(), String> {
    let repo = open(&path)?;
    let mut br = repo
        .find_branch(&old_name, BranchType::Local)
        .map_err(|e| format!("找不到分支: {e}"))?;
    br.rename(&new_name, false)
        .map_err(|e| format!("重命名失败: {e}"))?;
    Ok(())
}

/// Point a local branch's upstream at `upstream` (e.g. `origin/main`).
/// Completes the multi-remote story: remotes can be added freely and each
/// branch picks which one it tracks.
pub fn branch_set_upstream(path: String, branch: String, upstream: String) -> Result<(), String> {
    let repo = open(&path)?;
    let up = upstream.trim();
    if up.is_empty() {
        return Err("上游名称为空".into());
    }
    let mut br = repo
        .find_branch(&branch, BranchType::Local)
        .map_err(|e| format!("找不到本地分支 {branch}: {e}"))?;
    match br.set_upstream(Some(up)) {
        Ok(()) => Ok(()),
        Err(e) => {
            // 远程跟踪引用 refs/remotes/<remote>/<branch> 尚不存在时（绑定远程后
            // 还没 fetch 过），高层 API 会失败；退回 config 级设置跟踪，pull 内部
            // 的 fetch 会把引用补出来。
            let Some((remote, rb)) = up.split_once('/') else {
                return Err(format!("设置上游失败: {e}"));
            };
            let mut cfg = repo.config().map_err(|e2| format!("设置上游失败: {e2}"))?;
            cfg.set_str(&format!("branch.{branch}.remote"), remote)
                .map_err(|e2| format!("设置上游失败: {e2}"))?;
            cfg.set_str(&format!("branch.{branch}.merge"), &format!("refs/heads/{rb}"))
                .map_err(|e2| format!("设置上游失败: {e2}"))?;
            Ok(())
        }
    }
}

pub fn tag_create(path: String, name: String, commit_id: Option<String>) -> Result<(), String> {
    let repo = open(&path)?;
    let commit = match commit_id {
        Some(c) if !c.is_empty() => rev_to_commit(&repo, &c)?,
        _ => repo.head().map_err(|_| "空仓库无法打标签")?.peel_to_commit().map_err(|e| e.to_string())?,
    };
    repo.reference(
            &format!("refs/tags/{name}"),
            commit.id(),
            false,
            "AiwliGit: create tag",
        )
        .map_err(|e| format!("创建标签失败: {e}"))?;
    Ok(())
}

pub fn tag_delete(path: String, name: String) -> Result<(), String> {
    let repo = open(&path)?;
    repo.tag_delete(&name).map_err(|e| format!("删除标签失败: {e}"))?;
    Ok(())
}

/// Merge `branch` (short name of a local or remote branch) into HEAD.
pub fn merge(path: String, branch: String) -> Result<MergeResult, String> {
    let repo = open(&path)?;
    let rref = repo
        .resolve_reference_from_short_name(&branch)
        .map_err(|e| format!("找不到引用 {branch}: {e}"))?;
    let annotated = repo.reference_to_annotated_commit(&rref).map_err(|e| e.to_string())?;
    let target = rref.peel_to_commit().map_err(|e| e.to_string())?;
    let (analysis, _) = repo.merge_analysis(&[&annotated]).map_err(|e| e.to_string())?;

    if analysis.is_up_to_date() {
        return Ok(MergeResult { fast_forward: false, up_to_date: true, commit_id: None, conflicts: vec![] });
    }

    if analysis.is_fast_forward() {
        // move current branch ref then materialize workdir
        let mut head_ref = repo.head().map_err(|_| "空仓库（无 HEAD）无法合并")?;
        if !head_ref.is_branch() {
            return Err("分离 HEAD 状态下请先切换到分支".into());
        }
        head_ref
            .set_target(target.id(), &format!("merge: fast-forward {branch}"))
            .map_err(|e| format!("fast-forward 失败: {e}"))?;
        let mut cb = CheckoutBuilder::new();
        cb.force();
        repo.checkout_tree(target.as_object(), Some(&mut cb))
            .map_err(|e| format!("更新工作树失败: {e}"))?;
        let id = target.id().to_string();
        return Ok(MergeResult { fast_forward: true, up_to_date: false, commit_id: Some(id), conflicts: vec![] });
    }

    if is_repo_dirty(&repo) {
        return Err("工作树有未提交变更，先提交再合并".into());
    }

    repo.merge(&[&annotated], None, None).map_err(|e| format!("合并失败: {e}"))?;
    let mut index = repo.index().map_err(|e| e.to_string())?;
    if index.has_conflicts() {
        return Ok(MergeResult {
            fast_forward: false,
            up_to_date: false,
            commit_id: None,
            conflicts: conflicted_files(&index),
        });
    }
    let tree_oid = index.write_tree().map_err(|e| e.to_string())?;
    let tree = repo.find_tree(tree_oid).map_err(|e| e.to_string())?;
    let head = repo.head().map_err(|e| e.to_string())?.peel_to_commit().map_err(|e| e.to_string())?;
    let sig = signature(&repo)?;
    let msg = format!("Merge branch '{branch}'");
    let oid = repo
        .commit(Some("HEAD"), &sig, &sig, &msg, &tree, &[&head, &target])
        .map_err(|e| format!("生成合并提交失败: {e}"))?;
    Ok(MergeResult { fast_forward: false, up_to_date: false, commit_id: Some(oid.to_string()), conflicts: vec![] })
}

/// Reset current branch to commit (default HEAD). mode: soft|mixed|hard.
pub fn reset(path: String, commit_id: Option<String>, mode: String) -> Result<(), String> {
    let repo = open(&path)?;
    let commit = match commit_id {
        Some(c) if !c.is_empty() => rev_to_commit(&repo, &c)?,
        _ => repo.head().map_err(|_| "空仓库无 HEAD")?.peel_to_commit().map_err(|e| e.to_string())?,
    };
    let kind = match mode.as_str() {
        "soft" => ResetType::Soft,
        "hard" => ResetType::Hard,
        _ => ResetType::Mixed,
    };
    let obj = commit.as_object();
    repo.reset(obj, kind, None).map_err(|e| format!("重置失败: {e}"))?;
    Ok(())
}

/// Revert a commit (inverse patch applied; result auto-committed).
pub fn revert(path: String, commit_id: String) -> Result<String, String> {
    let repo = open(&path)?;
    if is_repo_dirty(&repo) {
        return Err("工作树有未提交变更，先提交再回退".into());
    }
    let commit = rev_to_commit(&repo, &commit_id)?;
    repo.revert(&commit, None).map_err(|e| format!("回退失败: {e}"))?;
    let mut index = repo.index().map_err(|e| e.to_string())?;
    if index.has_conflicts() {
        return Err("回退产生冲突，请手工处理".into());
    }
    let tree_oid = index.write_tree().map_err(|e| e.to_string())?;
    let tree = repo.find_tree(tree_oid).map_err(|e| e.to_string())?;
    let head = repo.head().map_err(|e| e.to_string())?.peel_to_commit().map_err(|e| e.to_string())?;
    let sig = signature(&repo)?;
    let summary = commit.summary().unwrap_or("");
    let msg = format!("Revert \"{summary}\"\n\nThis reverts commit {}.", commit.id());
    let oid = repo
        .commit(Some("HEAD"), &sig, &sig, &msg, &tree, &[&head])
        .map_err(|e| format!("提交回退失败: {e}"))?;
    Ok(oid.to_string())
}

/// Cherry-pick a commit onto current HEAD.
pub fn cherry_pick(path: String, commit_id: String) -> Result<String, String> {
    let repo = open(&path)?;
    let commit = rev_to_commit(&repo, &commit_id)?;
    repo.cherrypick(&commit, None).map_err(|e| format!("cherry-pick 失败: {e}"))?;
    let mut index = repo.index().map_err(|e| e.to_string())?;
    if index.has_conflicts() {
        return Err("cherry-pick 产生冲突，请手工处理后提交".into());
    }
    let tree_oid = index.write_tree().map_err(|e| e.to_string())?;
    let tree = repo.find_tree(tree_oid).map_err(|e| e.to_string())?;
    let head = repo.head().ok().and_then(|h| h.peel_to_commit().ok());
    let parents: Vec<git2::Commit> = head.into_iter().collect();
    let pr: Vec<&git2::Commit> = parents.iter().collect();
    let sig = signature(&repo)?;
    let summary = commit.summary().unwrap_or("");
    let msg = format!("{summary}\n\n(cherry picked from commit {})", commit.id());
    let oid = repo
        .commit(Some("HEAD"), &sig, &sig, &msg, &tree, &pr)
        .map_err(|e| format!("提交失败: {e}"))?;
    Ok(oid.to_string())
}

pub struct ConflictFile {
    pub path: String,
    pub has_ours: bool,
    pub has_theirs: bool,
}

pub fn conflicts(path: String) -> Result<Vec<ConflictFile>, String> {
    let repo = open(&path)?;
    let index = repo.index().map_err(|e| e.to_string())?;
    let mut out = Vec::new();
    for c in index.conflicts().map_err(|e| e.to_string())?.flatten() {
        let p = c
            .our
            .as_ref()
            .or(c.their.as_ref())
            .or(c.ancestor.as_ref())
            .map(|e| String::from_utf8_lossy(&e.path).to_string())
            .unwrap_or_default();
        if p.is_empty() || out.iter().any(|f: &ConflictFile| f.path == p) {
            continue;
        }
        out.push(ConflictFile { path: p, has_ours: c.our.is_some(), has_theirs: c.their.is_some() });
    }
    Ok(out)
}

/// Resolve one conflicted file by taking ours/theirs stage content.
pub fn resolve_conflict(path: String, file: String, side: String) -> Result<(), String> {
    let repo = open(&path)?;
    let mut index = repo.index().map_err(|e| e.to_string())?;
    let mut content: Option<Vec<u8>> = None;
    let mut mode: u32 = 0o100644;
    for c in index.conflicts().map_err(|e| e.to_string())?.flatten() {
        let p = c.our.as_ref().or(c.their.as_ref()).or(c.ancestor.as_ref()).map(|e| String::from_utf8_lossy(&e.path).to_string());
        if p.as_deref() == Some(file.as_str()) {
            let entry = if side == "theirs" { c.their } else { c.our };
            if let Some(e) = entry {
                let blob = repo.find_blob(e.id).map_err(|x| x.to_string())?;
                content = Some(blob.content().to_vec());
                mode = e.mode;
            }
            break;
        }
    }
    let content = content.ok_or("找不到冲突双方的版本")?;
    let wp = workdir_path(&repo, &file)?;
    if content.is_empty() {
        if wp.exists() {
            std::fs::remove_file(&wp).map_err(|e| format!("删除文件失败: {e}"))?;
        }
        index.remove_path(Path::new(&file)).map_err(|e| e.to_string())?;
    } else {
        std::fs::write(&wp, &content).map_err(|e| format!("写入文件失败: {e}"))?;
        index.add_path(Path::new(&file)).map_err(|e| format!("更新索引失败: {e}"))?;
    }
    let _ = mode;
    index.write().map_err(|e| e.to_string())?;
    Ok(())
}

/// Finalize an in-progress merge (MERGE_HEAD exists, conflicts resolved).
pub fn merge_commit(path: String, message: Option<String>) -> Result<String, String> {
    let repo = open(&path)?;
    if repo.state() != git2::RepositoryState::Merge {
        return Err("当前没有进行中的合并".into());
    }
    let merge_head_file = repo.path().join("MERGE_HEAD");
    let raw = std::fs::read_to_string(&merge_head_file).map_err(|e| format!("读取 MERGE_HEAD 失败: {e}"))?;
    let their_oid = git2::Oid::from_str(raw.trim()).map_err(|e| e.to_string())?;
    let their = repo.find_commit(their_oid).map_err(|e| e.to_string())?;

    let mut index = repo.index().map_err(|e| e.to_string())?;
    if index.has_conflicts() {
        return Err("仍有未解决的冲突".into());
    }
    let tree_oid = index.write_tree().map_err(|e| e.to_string())?;
    let tree = repo.find_tree(tree_oid).map_err(|e| e.to_string())?;
    let head = repo.head().map_err(|e| e.to_string())?.peel_to_commit().map_err(|e| e.to_string())?;
    let sig = signature(&repo)?;
    let msg = message.filter(|m: &String| !m.trim().is_empty())
        .unwrap_or_else(|| format!("Merge branch '{}'", their.id().to_string().chars().take(7).collect::<String>()));
    let oid = repo
        .commit(Some("HEAD"), &sig, &sig, &msg, &tree, &[&head, &their])
        .map_err(|e| format!("生成合并提交失败: {e}"))?;
    repo.cleanup_state().map_err(|e| format!("清理合并状态失败: {e}"))?;
    Ok(oid.to_string())
}

/// Abort an in-progress merge: back to pre-merge HEAD, clean index.
pub fn merge_abort(path: String) -> Result<(), String> {
    let repo = open(&path)?;
    if repo.state() != git2::RepositoryState::Merge {
        return Err("当前没有进行中的合并".into());
    }
    let head = repo.head().map_err(|e| e.to_string())?.peel_to_commit().map_err(|e| e.to_string())?;
    repo.reset(head.as_object(), ResetType::Hard, None).map_err(|e| format!("中止失败: {e}"))?;
    repo.cleanup_state().map_err(|e| format!("清理合并状态失败: {e}"))?;
    Ok(())
}
