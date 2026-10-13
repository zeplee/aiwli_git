use git2::{PushOptions, Repository, Signature};
use std::path::Path;

#[test]
fn push_to_local_bare() {
    let tmp = std::env::temp_dir().join("gd_push_test");
    let _ = std::fs::remove_dir_all(&tmp);
    std::fs::create_dir_all(tmp.join("src")).unwrap();
    let src = Repository::init(tmp.join("src")).unwrap();
    let sig = Signature::now("t", "t@t").unwrap();
    std::fs::write(tmp.join("src/hello.md"), b"hello").unwrap();
    let mut idx = src.index().unwrap();
    idx.add_path(Path::new("hello.md")).unwrap();
    idx.write().unwrap();
    let tree = src.find_tree(idx.write_tree().unwrap()).unwrap();
    let c = src.commit(Some("HEAD"), &sig, &sig, "init", &tree, &[]).unwrap();

    // bare dest: fuse-mounted path (like the app's remotes) or same-fs fallback
    let bare_path = std::env::var("GD_PUSH_DEST")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| tmp.join("dest.git"));
    if !bare_path.join("HEAD").exists() {
        let _ = Repository::init_bare(&bare_path).unwrap();
    }
    let bare_probe = Repository::open_bare(&bare_path).unwrap();
    drop(bare_probe);

    // add remote as PLAIN PATH (like the app does)
    let mut r = src.remote("origin", bare_path.to_str().unwrap()).unwrap();
    let mut opts = PushOptions::new();
    match r.push(&[&format!("refs/heads/master:refs/heads/master")], Some(&mut opts)) {
        Ok(()) => println!("PUSH OK to plain path"),
        Err(e) => println!("RAW PUSH ERROR (plain path): class={:?} code={:?} msg={}", e.class(), e.code(), e.message()),
    }
    let bare = Repository::open_bare(&bare_path).unwrap();
    let ok = bare.refname_to_id("refs/heads/master") == Ok(c);
    println!("bare master == pushed commit: {}", ok);
}
