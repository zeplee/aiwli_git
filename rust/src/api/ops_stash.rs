//! Stash: save (incl. untracked), list, apply / pop / drop.

use super::util::{open, signature};

pub struct StashEntry {
    pub index: usize,
    pub id: String,
    pub message: String,
    pub time_unix: i64,
}

pub fn stash_list(path: String) -> Result<Vec<StashEntry>, String> {
    let mut repo = open(&path)?;
    let mut raw: Vec<(usize, String, git2::Oid)> = Vec::new();
    repo.stash_foreach(|idx, message, oid| {
        raw.push((idx as usize, message.to_string(), *oid));
        true
    })
    .map_err(|e| format!("读取 stash 失败: {e}"))?;
    let out = raw
        .into_iter()
        .map(|(index, message, oid)| StashEntry {
            index,
            id: oid.to_string(),
            message,
            time_unix: repo.find_commit(oid).map(|c| c.time().seconds()).unwrap_or(0),
        })
        .collect();
    Ok(out)
}

pub fn stash_push(path: String, message: Option<String>, include_untracked: bool) -> Result<String, String> {
    let mut repo = open(&path)?;
    let sig = signature(&repo)?;
    let flags = if include_untracked {
        Some(git2::StashFlags::INCLUDE_UNTRACKED)
    } else {
        None
    };
    let msg = message.filter(|m| !m.trim().is_empty());
    let oid = repo
        .stash_save2(&sig, msg.as_deref(), flags)
        .map_err(|e| format!("stash 失败: {e}"))?;
    Ok(oid.to_string())
}

pub fn stash_apply(path: String, index: usize) -> Result<(), String> {
    let mut repo = open(&path)?;
    repo.stash_apply(index, None).map_err(|e| format!("应用 stash 失败: {e}"))?;
    Ok(())
}

pub fn stash_pop(path: String, index: usize) -> Result<(), String> {
    let mut repo = open(&path)?;
    repo.stash_pop(index, None).map_err(|e| format!("pop stash 失败: {e}"))?;
    Ok(())
}

pub fn stash_drop(path: String, index: usize) -> Result<(), String> {
    let mut repo = open(&path)?;
    repo.stash_drop(index).map_err(|e| format!("删除 stash 失败: {e}"))?;
    Ok(())
}
