//! AiwliGit engine — MVP git workbench operations via git2 (libgit2).
//!
//! Design notes:
//! - All functions take the repo path explicitly (stateless, FRB-friendly).
//! - All fallible functions return Result<_, String> for simple Dart-side handling.
//! - Diff output is unified patch text rendered by the Dart side.

use std::path::Path;

use git2::{IndexAddOption, Status, StatusOptions};
use git2::build::CheckoutBuilder;

use super::util::{
    commit_info, diff_stats_nums, diff_to_text, open, signature, status_code_to_char,
};

// ---------- data types ----------

pub struct FileStatus {
    pub path: String,
    /// 'M' modified, 'A' added, 'D' deleted, 'T' typechange, 'R' renamed, '?' untracked
    pub code: String,
}

pub struct CommitInfo {
    pub id: String,
    pub short_id: String,
    pub summary: String,
    pub message: String,
    pub author: String,
    pub email: String,
    pub time_unix: i64,
}

pub struct RepoSnapshot {
    pub branch: String,
    pub head_id: String,
    pub has_merge_head: bool,
    pub ahead: i32,
    pub behind: i32,
    pub staged: Vec<FileStatus>,
    pub unstaged: Vec<FileStatus>,
    pub untracked: Vec<String>,
    pub conflicted: Vec<String>,
    pub recent_commits: Vec<CommitInfo>,
}

pub struct CommitDiffEntry {
    pub path: String,
    /// 'M' | 'A' | 'D' | 'T' | 'R'
    pub code: String,
    pub additions: i32,
    pub deletions: i32,
    pub patch_text: String,
}

// ---------- public API ----------

/// Validate that a directory is a git repository.
pub fn open_repo(path: String) -> Result<String, String> {
    let repo = open(&path)?;
    let workdir = repo
        .workdir()
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_default();
    let head = repo.head().ok();
    let branch = head
        .and_then(|h| h.shorthand().map(|s| s.to_string()))
        .unwrap_or_else(|| "(detached)".into());
    Ok(format!("{workdir} [{branch}]"))
}

/// Initialize a new git repository at `path` (git init). An existing folder is
/// adopted in place — nothing inside is touched; its files simply show up as
/// untracked. Initial branch is `main` to match modern hosting defaults.
pub fn init_repo(path: String) -> Result<String, String> {
    let mut opts = git2::RepositoryInitOptions::new();
    opts.initial_head("main").mkpath(true);
    let repo = git2::Repository::init_opts(Path::new(&path), &opts)
        .map_err(|e| format!("初始化仓库失败: {e}"))?;
    let workdir = repo
        .workdir()
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or(path);
    Ok(workdir)
}

/// Full workbench snapshot: branch, ahead/behind, staged/unstaged/untracked, recent commits.
pub fn get_snapshot(path: String, commit_limit: i32) -> Result<RepoSnapshot, String> {
    let repo = open(&path)?;

    // branch name + head commit
    let head_ref = repo.head().map_err(|e| format!("读取 HEAD 失败: {e}"))?;
    let head_id = head_ref.peel_to_commit().map(|c| c.id().to_string()).unwrap_or_default();
    let has_merge_head = repo.state() == git2::RepositoryState::Merge;
    let conflicted: Vec<String> = repo
        .index()
        .ok()
        .and_then(|idx| {
            let mut v = Vec::new();
            for c in idx.conflicts().ok()? {
                if let Ok(c) = c {
                    if let Some(e) = c.our.or(c.their).or(c.ancestor) {
                        let p = String::from_utf8_lossy(&e.path).to_string();
                        if !v.contains(&p) {
                            v.push(p);
                        }
                    }
                }
            }
            Some(v)
        })
        .unwrap_or_default();
    let branch = head_ref
        .shorthand()
        .unwrap_or("(detached)")
        .to_string();

    // ahead / behind vs upstream
    let (mut ahead, mut behind) = (0, 0);
    if let Ok(short) = repo.branch_upstream_name(head_ref.name().unwrap_or("")) {
        if let (Ok(local), Ok(up)) = (
            repo.refname_to_id(&format!("refs/heads/{branch}")),
            repo.refname_to_id(String::from_utf8_lossy(&short).as_ref()),
        ) {
            if let Ok((a, b)) = repo.graph_ahead_behind(local, up) {
                ahead = a as i32;
                behind = b as i32;
            }
        }
    }

    // status scan
    let mut opts = StatusOptions::new();
    opts.include_untracked(true)
        .include_ignored(false)
        .exclude_submodules(true)
        .recurse_untracked_dirs(false);
    let statuses = repo
        .statuses(Some(&mut opts))
        .map_err(|e| format!("扫描工作树失败: {e}"))?;

    let mut staged: Vec<FileStatus> = Vec::new();
    let mut unstaged: Vec<FileStatus> = Vec::new();
    let mut untracked: Vec<String> = Vec::new();
    for entry in statuses.iter() {
        let s = entry.status();
        let path = entry
            .head_to_index()
            .or_else(|| entry.index_to_workdir())
            .and_then(|d| d.new_file().path().map(|p| p.to_string_lossy().to_string()))
            .unwrap_or_default();
        if path.is_empty() {
            continue;
        }
        if s.contains(Status::WT_NEW) {
            untracked.push(path.clone());
            continue;
        }
        if let Some(c) = status_code_to_char(s, true) {
            staged.push(FileStatus { path: path.clone(), code: c });
        }
        if let Some(c) = status_code_to_char(s, false) {
            unstaged.push(FileStatus { path: path.clone(), code: c });
        }
    }

    // recent commits
    let mut revwalk = repo.revwalk().map_err(|e| format!("历史遍历失败: {e}"))?;
    revwalk.push_head().map_err(|e| format!("历史遍历失败: {e}"))?;
    revwalk.set_sorting(git2::Sort::TIME).ok();
    let mut recent_commits = Vec::new();
    for oid in revwalk.take(commit_limit.max(1) as usize) {
        match oid.and_then(|id| repo.find_commit(id)) {
            Ok(c) => recent_commits.push(commit_info(&c)),
            Err(_) => continue,
        }
    }

    Ok(RepoSnapshot {
        branch,
        head_id,
        has_merge_head,
        ahead,
        behind,
        staged,
        unstaged,
        untracked,
        conflicted,
        recent_commits,
    })
}

/// Unified patch for one file: workdir-vs-index (staged=false) or index-vs-HEAD (staged=true).
pub fn get_workdir_diff(path: String, file: String, staged: bool) -> Result<String, String> {
    let repo = open(&path)?;
    let head_tree = repo
        .head()
        .ok()
        .and_then(|h| h.peel_to_tree().ok());

    let p = Path::new(&file);
    let mut opts = git2::DiffOptions::new();
    opts.pathspec(p.to_string_lossy().as_ref());

    let mut diff = if staged {
        let tree = head_tree.ok_or("空仓库（无 HEAD）")?;
        repo.diff_tree_to_index(Some(&tree), None, Some(&mut opts))
    } else {
        repo.diff_index_to_workdir(None, Some(&mut opts))
    }
    .map_err(|e| format!("生成 diff 失败: {e}"))?;

    Ok(diff_to_text(&mut diff))
}

/// All changed files of one commit as unified patches.
pub fn get_commit_diff(path: String, commit_id: String) -> Result<Vec<CommitDiffEntry>, String> {
    let repo = open(&path)?;
    let oid = git2::Oid::from_str(&commit_id).map_err(|e| format!("commit id 无效: {e}"))?;
    let commit = repo.find_commit(oid).map_err(|e| format!("找不到提交: {e}"))?;
    let tree = commit.tree().map_err(|e| e.to_string())?;
    let parent_tree = commit.parent(0).ok().map(|p| p.tree().ok()).flatten();

    let mut diff = repo
        .diff_tree_to_tree(parent_tree.as_ref(), Some(&tree), None)
        .map_err(|e| format!("生成 diff 失败: {e}"))?;
    let mut find_opts = git2::DiffFindOptions::new();
    find_opts.renames(true);
    diff.find_similar(Some(&mut find_opts)).ok();

    let mut out = Vec::new();
    let (total_add, total_del) = diff_stats_nums(&diff);
    let _ = (total_add, total_del);
    // per-file: iterate deltas, re-diff with pathspec for patch text
    for delta_idx in 0..diff.deltas().len() {
        let delta = diff.get_delta(delta_idx);
        let Some(d) = delta else { continue };
        let file_path = d
            .new_file()
            .path()
            .or_else(|| d.old_file().path())
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_default();
        if file_path.is_empty() {
            continue;
        }
        let code = match d.status() {
            git2::Delta::Added => 'A',
            git2::Delta::Deleted => 'D',
            git2::Delta::Renamed => 'R',
            git2::Delta::Typechange => 'T',
            _ => 'M',
        }
        .to_string();

        let mut po = git2::DiffOptions::new();
        po.pathspec(file_path.as_str());
        if let Ok(mut sub) = repo.diff_tree_to_tree(parent_tree.as_ref(), Some(&tree), Some(&mut po)) {
            let text = diff_to_text(&mut sub);
            let (a, d2) = diff_stats_nums(&sub);
            out.push(CommitDiffEntry {
                path: file_path,
                code,
                additions: a,
                deletions: d2,
                patch_text: text,
            });
        }
    }
    Ok(out)
}

/// Stage files (supports untracked — they get added).
pub fn stage_paths(path: String, files: Vec<String>) -> Result<(), String> {
    let repo = open(&path)?;
    let mut index = repo.index().map_err(|e| format!("读取索引失败: {e}"))?;
    let paths: Vec<&str> = files.iter().map(|s| s.as_str()).collect();
    index
        .add_all(paths.iter(), IndexAddOption::DEFAULT, None)
        .map_err(|e| format!("暂存失败: {e}"))?;
    index.write().map_err(|e| format!("写入索引失败: {e}"))?;
    Ok(())
}

/// Unstage files (reset index entries to HEAD; untracked-ify new files).
pub fn unstage_paths(path: String, files: Vec<String>) -> Result<(), String> {
    let repo = open(&path)?;
    let head_commit = repo.head().ok().and_then(|h| h.peel_to_commit().ok());
    let mut index = repo.index().map_err(|e| format!("读取索引失败: {e}"))?;
    for f in &files {
        match head_commit.as_ref() {
            Some(c) => {
                let te = c.tree().ok().and_then(|t| t.get_path(Path::new(f)).ok());
                match te {
                    Some(te) => {
                        let oid = te.id();
                        let mode = te.filemode() as u32;
                        index
                            .remove_path(Path::new(f))
                            .map_err(|e| format!("unstage 失败: {e}"))?;
                        // re-add HEAD version to index
                        let blob = repo.find_blob(oid).map_err(|e| e.to_string())?;
                        let entry = git2::IndexEntry {
                            ctime: git2::IndexTime::new(0, 0),
                            mtime: git2::IndexTime::new(0, 0),
                            dev: 0,
                            ino: 0,
                            mode,
                            uid: 0,
                            gid: 0,
                            file_size: blob.size() as u32,
                            id: oid,
                            flags: 0,
                            flags_extended: 0,
                            path: f.clone().into(),
                        };
                        index.add(&entry).map_err(|e| format!("unstage 失败: {e}"))?;
                    }
                    None => {
                        // not in HEAD → this is a newly added file: remove from index
                        index
                            .remove_path(Path::new(f))
                            .map_err(|e| format!("unstage 失败: {e}"))?;
                    }
                }
            }
            None => {
                index
                    .remove_path(Path::new(f))
                    .map_err(|e| format!("unstage 失败: {e}"))?;
            }
        }
    }
    index.write().map_err(|e| format!("写入索引失败: {e}"))?;
    Ok(())
}

/// Discard workdir changes for files (checkout index version over workdir; untracked → delete).
pub fn discard_paths(path: String, files: Vec<String>) -> Result<(), String> {
    let repo = open(&path)?;
    let mut cb = CheckoutBuilder::new();
    cb.force();
    let mut has_tracked = false;
    for f in &files {
        cb.path(f.as_str());
        has_tracked = true;
    }
    if has_tracked {
        let mut index = repo.index().map_err(|e| e.to_string())?;
        repo.checkout_index(Some(&mut index), Some(&mut cb))
            .map_err(|e| format!("还原失败: {e}"))?;
    }
    // untracked files are simply removed
    for f in &files {
        let p = Path::new(&repo.workdir().map(|w| w.to_path_buf()).unwrap_or_default()).join(f);
        if p.is_file() {
            let still_untracked = repo
                .status_file(Path::new(f))
                .map(|s| s.contains(Status::WT_NEW))
                .unwrap_or(false);
            if still_untracked {
                std::fs::remove_file(&p).map_err(|e| format!("删除失败: {e}"))?;
            }
        }
    }
    Ok(())
}

/// Commit staged changes. amend=true amends HEAD (keeps original author).
pub fn commit_staged(path: String, message: String, amend: bool) -> Result<String, String> {
    let repo = open(&path)?;
    let sig = signature(&repo)?;
    let mut index = repo.index().map_err(|e| format!("读取索引失败: {e}"))?;
    if index.has_conflicts() {
        return Err("存在未解决的冲突，先处理冲突再提交".into());
    }
    let tree_oid = index.write_tree().map_err(|e| format!("构建 tree 失败: {e}"))?;
    let tree = repo.find_tree(tree_oid).map_err(|e| e.to_string())?;

    if amend {
        let head = repo
            .head()
            .map_err(|_| "空仓库无法 amend".to_string())?
            .peel_to_commit()
            .map_err(|e| e.to_string())?;
        let parents: Vec<git2::Commit> = (0..head.parent_count()).filter_map(|i| head.parent(i).ok()).collect();
        let parent_refs: Vec<&git2::Commit> = parents.iter().collect();
        let author = head.author();
        let oid = repo
            .commit(Some("HEAD"), &author, &sig, &message, &tree, &parent_refs)
            .map_err(|e| format!("amend 失败: {e}"))?;
        Ok(oid.to_string())
    } else {
        let head = repo.head().ok().and_then(|h| h.peel_to_commit().ok());
        let parents: Vec<git2::Commit> = head.iter().cloned().collect();
        let parent_refs: Vec<&git2::Commit> = parents.iter().collect();
        let oid = repo
            .commit(Some("HEAD"), &sig, &sig, &message, &tree, &parent_refs)
            .map_err(|e| format!("提交失败: {e}"))?;
        Ok(oid.to_string())
    }
}

// branch operations live in ops_branch.rs
