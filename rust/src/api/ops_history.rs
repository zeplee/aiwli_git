//! History: paginated searchable log with graph topology (parents) and ref
//! decoration, commit detail, arbitrary-rev compare, and blame.

use std::collections::HashMap;
use std::path::Path;

use git2::Sort;

use super::git_engine::{CommitDiffEntry, CommitInfo};
use super::util::{commit_info, diff_stats_nums, diff_to_text, open, rev_to_commit};

pub struct LogEntry {
    pub info: CommitInfo,
    pub parents: Vec<String>,
    /// decorated ref short names (branches/tags) pointing at this commit
    pub refs: Vec<String>,
}

fn ref_decorations(repo: &git2::Repository) -> HashMap<git2::Oid, Vec<String>> {
    let mut map: HashMap<git2::Oid, Vec<String>> = HashMap::new();
    let refs = match repo.references() {
        Ok(r) => r,
        Err(_) => return map,
    };
    for r in refs.flatten() {
        let Some(name) = r.name().map(|s| s.to_string()) else { continue };
        let short = if let Some(n) = name.strip_prefix("refs/heads/") {
            n.to_string()
        } else if let Some(n) = name.strip_prefix("refs/tags/") {
            format!("tag:{n}")
        } else if let Some(n) = name.strip_prefix("refs/remotes/") {
            format!("{n}")
        } else {
            continue;
        };
        let target = match r.target() {
            Some(t) => t,
            None => continue,
        };
        // peeled target for tags
        let oid = r.peel(git2::ObjectType::Commit).map(|o| o.id()).unwrap_or(target);
        map.entry(oid).or_default().push(short);
    }
    map
}

/// Walk history from HEAD (or given start), filter by query, paginate.
pub fn log(path: String, skip: i32, limit: i32, query: Option<String>, start: Option<String>) -> Result<Vec<LogEntry>, String> {
    let repo = open(&path)?;
    let mut revwalk = repo.revwalk().map_err(|e| format!("历史遍历失败: {e}"))?;
    match start.as_deref().filter(|s| !s.is_empty()) {
        Some(s) => {
            let c = rev_to_commit(&repo, s)?;
            revwalk.push(c.id()).map_err(|e| e.to_string())?;
        }
        None => revwalk.push_head().map_err(|e| format!("历史遍历失败: {e}"))?,
    }
    revwalk.set_sorting(Sort::TIME | Sort::TOPOLOGICAL).ok();

    let q = query.unwrap_or_default().to_lowercase();
    let deco = ref_decorations(&repo);
    let skip = skip.max(0) as usize;
    let limit = limit.clamp(1, 500) as usize;

    let mut out = Vec::new();
    let mut matched = 0usize;
    let mut scanned = 0usize;
    for oid in revwalk {
        scanned += 1;
        if scanned > 30000 {
            break;
        }
        let Ok(oid) = oid else { continue };
        let Ok(commit) = repo.find_commit(oid) else { continue };
        if !q.is_empty() {
            let hay = format!(
                "{} {} {}",
                commit.summary().unwrap_or(""),
                commit.author().name().unwrap_or(""),
                commit.id()
            )
            .to_lowercase();
            if !hay.contains(&q) {
                continue;
            }
        }
        if matched < skip {
            matched += 1;
            continue;
        }
        let parents: Vec<String> = (0..commit.parent_count())
            .filter_map(|i| commit.parent_id(i).ok().map(|p| p.to_string()))
            .collect();
        let refs = deco.get(&oid).cloned().unwrap_or_default();
        out.push(LogEntry { info: commit_info(&commit), parents, refs });
        if out.len() >= limit {
            break;
        }
    }
    Ok(out)
}

/// Per-file diff between two revs (each may be branch/tag/hash/HEAD).
/// Empty `from` means empty tree (diff of `to` itself).
pub fn diff_revs(path: String, from: String, to: String) -> Result<Vec<CommitDiffEntry>, String> {
    let repo = open(&path)?;
    let to_commit = rev_to_commit(&repo, &to)?;
    let to_tree = to_commit.tree().map_err(|e| e.to_string())?;
    let from_tree = if from.is_empty() {
        None
    } else {
        Some(rev_to_commit(&repo, &from)?.tree().map_err(|e| e.to_string())?)
    };
    tree_diff_entries(&repo, from_tree.as_ref(), &to_tree)
}

pub(crate) fn tree_diff_entries(
    repo: &git2::Repository,
    from_tree: Option<&git2::Tree<'_>>,
    to_tree: &git2::Tree<'_>,
) -> Result<Vec<CommitDiffEntry>, String> {
    let mut diff = repo
        .diff_tree_to_tree(from_tree, Some(to_tree), None)
        .map_err(|e| format!("生成 diff 失败: {e}"))?;
    let mut find = git2::DiffFindOptions::new();
    find.renames(true);
    diff.find_similar(Some(&mut find)).ok();

    let mut out = Vec::new();
    for idx in 0..diff.deltas().len() {
        let Some(d) = diff.get_delta(idx) else { continue };
        let Some(file_path) = d
            .new_file()
            .path()
            .or_else(|| d.old_file().path())
            .map(|p| p.to_string_lossy().to_string())
            .filter(|p| !p.is_empty())
        else {
            continue;
        };
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
        if let Ok(mut sub) = repo.diff_tree_to_tree(from_tree, Some(to_tree), Some(&mut po)) {
            let text = diff_to_text(&mut sub);
            let (a, del) = diff_stats_nums(&sub);
            out.push(CommitDiffEntry { path: file_path, code, additions: a, deletions: del, patch_text: text });
        }
    }
    Ok(out)
}

pub struct BlameLine {
    pub line_no: i32,
    pub commit_id: String,
    pub short_id: String,
    pub author: String,
    pub time_unix: i64,
    pub summary: String,
    pub content: String,
}

/// Blame the workdir version of a file (uncommitted lines → empty commit id).
pub fn blame(path: String, file: String) -> Result<Vec<BlameLine>, String> {
    let repo = open(&path)?;
    let wd = repo.workdir().ok_or("裸仓库没有工作树")?;
    let full = wd.join(&file);
    let content = std::fs::read(&full).map_err(|e| format!("读取文件失败: {e}"))?;
    if content.is_empty() {
        return Ok(vec![]);
    }
    let lines = super::util::split_lines(&content);
    // base blame from committed version, then re-blame the workdir buffer
    let base = repo.blame_file(Path::new(&file), None).ok();
    let blame = match &base {
        Some(b) => b
            .blame_buffer(&content)
            .map_err(|e| format!("blame 失败: {e}"))?,
        None => {
            // file not in HEAD at all → every line uncommitted
            return Ok((0..lines.len())
                .map(|i| BlameLine {
                    line_no: (i + 1) as i32,
                    commit_id: String::new(),
                    short_id: "0000000".into(),
                    author: "(未提交)".into(),
                    time_unix: 0,
                    summary: String::new(),
                    content: String::from_utf8_lossy(&lines[i])
                        .trim_end_matches('\n')
                        .trim_end_matches('\r')
                        .to_string(),
                })
                .collect());
        }
    };

    let mut out = Vec::new();
    for (i, line) in lines.iter().enumerate() {
        let text = String::from_utf8_lossy(line).trim_end_matches('\n').trim_end_matches('\r').to_string();
        match blame.get_line(i + 1) {
            Some(h) => {
                let cid = h.final_commit_id();
                if cid.is_zero() {
                    out.push(BlameLine {
                        line_no: (i + 1) as i32,
                        commit_id: String::new(),
                        short_id: "0000000".into(),
                        author: "(未提交)".into(),
                        time_unix: 0,
                        summary: String::new(),
                        content: text,
                    });
                } else {
                    let c = repo.find_commit(cid).ok();
                    let info = c.as_ref().map(commit_info);
                    out.push(BlameLine {
                        line_no: (i + 1) as i32,
                        commit_id: cid.to_string(),
                        short_id: info.as_ref().map(|x| x.short_id.clone()).unwrap_or_default(),
                        author: info.as_ref().map(|x| x.author.clone()).unwrap_or_default(),
                        time_unix: info.as_ref().map(|x| x.time_unix).unwrap_or(0),
                        summary: info.as_ref().map(|x| x.summary.clone()).unwrap_or_default(),
                        content: text,
                    });
                }
            }
            None => out.push(BlameLine {
                line_no: (i + 1) as i32,
                commit_id: String::new(),
                short_id: String::new(),
                author: String::new(),
                time_unix: 0,
                summary: String::new(),
                content: text,
            }),
        }
    }
    Ok(out)
}

/// Commit detail: info + parents + per-file diffs (reuses tree_diff_entries).
pub fn commit_detail(path: String, commit_id: String) -> Result<(CommitInfo, Vec<String>, Vec<CommitDiffEntry>), String> {
    let repo = open(&path)?;
    let commit = rev_to_commit(&repo, &commit_id)?;
    let info = commit_info(&commit);
    let parents: Vec<String> = (0..commit.parent_count())
        .filter_map(|i| commit.parent_id(i).ok().map(|p| p.to_string()))
        .collect();
    let tree = commit.tree().map_err(|e| e.to_string())?;
    let parent_tree = commit.parent(0).ok().map(|p| p.tree().ok()).flatten();
    let files = tree_diff_entries(&repo, parent_tree.as_ref(), &tree)?;
    Ok((info, parents, files))
}
