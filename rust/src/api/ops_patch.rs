//! Hunk-level staging: stage / unstage / discard selected hunks of one file.
//!
//! Byte-safe pipeline:
//!   1. build the single-file diff (index→workdir or HEAD→index)
//!   2. emit a unified patch (headers preserved)
//!   3. parse hunks, select requested indexes
//!   4. textual-apply (forward or reverse) onto the proper base content
//!   5. write back to index (blob + entry) or workdir file
//! Every context/removed line is verified — mismatch aborts, no silent merge.

use std::path::Path;

use super::util::{apply_hunks, diff_to_patch, is_binary, open, parse_hunks, read_workdir};

fn single_file_patch(
    repo: &git2::Repository,
    file: &str,
    staged: bool,
    include_untracked: bool,
) -> Result<Vec<u8>, String> {
    let mut opts = git2::DiffOptions::new();
    opts.pathspec(file);
    opts.include_untracked(include_untracked);
    opts.show_untracked_content(true);
    let mut diff = if staged {
        let tree = repo
            .head()
            .ok()
            .and_then(|h| h.peel_to_tree().ok())
            .ok_or("空仓库（无 HEAD），无已暂存内容")?;
        repo.diff_tree_to_index(Some(&tree), None, Some(&mut opts))
    } else {
        repo.diff_index_to_workdir(None, Some(&mut opts))
    }
    .map_err(|e| format!("生成 diff 失败: {e}"))?;
    Ok(diff_to_patch(&mut diff))
}

fn index_entry_mode(index: &git2::Index, file: &str) -> u32 {
    index
        .get_path(Path::new(file), 0)
        .map(|e| e.mode)
        .unwrap_or(0o100644)
}

/// op: "stage" | "unstage" | "discard"
pub fn hunk_op(path: String, file: String, indexes: Vec<i32>, op: String) -> Result<(), String> {
    let repo = open(&path)?;
    let mut index = repo.index().map_err(|e| format!("读取索引失败: {e}"))?;

    let (base, patch, forward): (Vec<u8>, Vec<u8>, bool) = match op.as_str() {
        // stage: apply workdir hunks onto the index
        "stage" => {
            let base = super::util::read_index_blob(&repo, &mut index, &file).unwrap_or_default();
            let patch = single_file_patch(&repo, &file, false, true)?;
            (base, patch, true)
        }
        // unstage: reverse-apply HEAD→index hunks onto the index
        "unstage" => {
            let base = super::util::read_index_blob(&repo, &mut index, &file)
                .ok_or("该文件不在暂存区")?;
            let has_head = repo.head().is_ok();
            if !has_head {
                // no HEAD → everything staged is new: remove entry entirely
                index.remove_path(Path::new(&file)).map_err(|e| e.to_string())?;
                index.write().map_err(|e| e.to_string())?;
                return Ok(());
            }
            let patch = single_file_patch(&repo, &file, true, false)?;
            (base, patch, false)
        }
        // discard: reverse-apply index→workdir hunks onto the workdir file
        "discard" => {
            let base = read_workdir(&repo, &file)?.ok_or("工作树中不存在该文件")?;
            let patch = single_file_patch(&repo, &file, false, true)?;
            (base, patch, false)
        }
        _ => return Err(format!("未知操作 {op}")),
    };

    if is_binary(&base) {
        return Err("二进制文件只支持整文件操作".into());
    }

    let hunks = parse_hunks(&patch);
    if hunks.is_empty() {
        return Err("该文件没有可按块操作的差异".into());
    }
    let mut selected: Vec<super::util::Hunk> = Vec::new();
    for i in &indexes {
        let i = *i;
        if i < 0 || i as usize >= hunks.len() {
            return Err(format!("块序号 {i} 超出范围（共 {} 块）", hunks.len()));
        }
        selected.push(hunks[i as usize].clone());
    }
    selected.sort_by_key(|h| if forward { h.old_start } else { h.new_start });

    let new_content = apply_hunks(&base, &selected, forward)?;

    match op.as_str() {
        "stage" | "unstage" => {
            if new_content.is_empty() {
                index.remove_path(Path::new(&file)).map_err(|e| format!("更新索引失败: {e}"))?;
            } else {
                let mode = index_entry_mode(&index, &file);
                let entry = git2::IndexEntry {
                    ctime: git2::IndexTime::new(0, 0),
                    mtime: git2::IndexTime::new(0, 0),
                    dev: 0,
                    ino: 0,
                    mode,
                    uid: 0,
                    gid: 0,
                    file_size: new_content.len() as u32,
                    id: git2::Oid::zero(),
                    flags: 0,
                    flags_extended: 0,
                    path: file.clone().into_bytes(),
                };
                index
                    .add_frombuffer(&entry, &new_content)
                    .map_err(|e| format!("写入索引失败: {e}"))?;
            }
            index.write().map_err(|e| format!("保存索引失败: {e}"))?;
        }
        "discard" => {
            let wp = super::util::workdir_path(&repo, &file)?;
            if new_content.is_empty() {
                if wp.exists() {
                    std::fs::remove_file(&wp).map_err(|e| format!("删除文件失败: {e}"))?;
                }
            } else {
                std::fs::write(&wp, &new_content).map_err(|e| format!("写入文件失败: {e}"))?;
            }
        }
        _ => unreachable!(),
    }
    Ok(())
}

/// Hunk headers + boundaries for the diff page UI.
pub struct HunkInfo {
    pub index: i32,
    pub header: String,
    pub old_start: i32,
    pub old_count: i32,
}

pub fn hunk_list(path: String, file: String, staged: bool) -> Result<Vec<HunkInfo>, String> {
    let repo = open(&path)?;
    let patch = single_file_patch(&repo, &file, staged, true)?;
    let hunks = parse_hunks(&patch);
    Ok(hunks
        .iter()
        .enumerate()
        .map(|(i, h)| HunkInfo {
            index: i as i32,
            header: format!("@@ -{},{} +{},{} @@", h.old_start, h.old_count, h.new_start, h.new_count),
            old_start: h.old_start as i32,
            old_count: h.old_count as i32,
        })
        .collect())
}
