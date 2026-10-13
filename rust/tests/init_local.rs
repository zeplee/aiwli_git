//! initRepo:收编现有文件夹为 Git 仓库(10-03「选择本地仓库可初始化」)。

use git2::Repository;

#[test]
fn init_repo_adopts_existing_folder() {
    let tmp = std::env::temp_dir().join("gd_init_test");
    let _ = std::fs::remove_dir_all(&tmp);
    std::fs::create_dir_all(tmp.join("nested")).unwrap();
    std::fs::write(tmp.join("a.txt"), b"hello").unwrap();

    let v = serde_json::json!({"path": tmp.to_str().unwrap()});

    // initRepo 成功并返回 workdir
    let out = rust_lib_gitdeck::api::dispatch::call("initRepo", &v).unwrap();
    assert!(out.as_str().unwrap().starts_with(tmp.to_str().unwrap()));

    // 收编后可正常 openRepo(dispatch 链路),初始分支为 main(未出生 HEAD)
    let opened = rust_lib_gitdeck::api::dispatch::call("openRepo", &v).unwrap();
    assert!(opened.as_str().unwrap().contains('['));
    let repo = Repository::open(&tmp).unwrap();
    let head = repo.find_reference("HEAD").unwrap();
    assert_eq!(head.symbolic_target(), Some("refs/heads/main"));

    // 幂等:对已是仓库的目录再 init 不应报错(git init 语义)
    let again = rust_lib_gitdeck::api::dispatch::call("initRepo", &v);
    assert!(again.is_ok());

    assert!(tmp.join(".git").exists());
    std::fs::remove_dir_all(&tmp).ok();
}
