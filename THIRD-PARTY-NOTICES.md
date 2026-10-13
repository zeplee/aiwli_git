# Third-party notices / 第三方组件声明

AiwliGit stands on the shoulders of the following open-source projects. This
file summarizes their licenses as shipped in the Android build. Full license
texts live in each project's repository.

## Application framework

| Component | License | Source |
| --- | --- | --- |
| Flutter engine & framework | BSD 3-Clause | https://github.com/flutter/flutter |
| Dart SDK | BSD 3-Clause | https://github.com/dart-lang/sdk |
| Material Icons font | Apache 2.0 | https://fonts.google.com/icons |

## Dart packages (pub.dev)

| Package | License | Source |
| --- | --- | --- |
| dynamic_color | MIT | https://pub.dev/packages/dynamic_color |
| cupertino_icons | MIT | https://pub.dev/packages/cupertino_icons |
| http | BSD 3-Clause | https://pub.dev/packages/http |
| ffi (dev tooling in rust_builder) | MIT OR Apache-2.0 | https://pub.dev/packages/ffi |

## Rust crates (bundled via Cargo, vendored builds)

| Crate | License | Source |
| --- | --- | --- |
| git2-rs | MIT OR Apache-2.0 | https://github.com/rust-lang/git2-rs |
| libgit2 (C, vendored) | GPLv2 with linking exception | https://github.com/libgit2/libgit2 |
| OpenSSL (vendored via openssl-src) | Apache-2.0 | https://www.openssl.org/ |
| serde / serde_json | MIT OR Apache-2.0 | https://serde.rs |
| libc, cc, cmake, other build deps | MIT OR Apache-2.0 | crates.io |

> Note on libgit2: its `COPYING` says "GPLv2", but the accompanying exception grants
> **unlimited permission to link** the compiled library into combinations with other programs,
> and to distribute those combinations without any restriction coming from the use of this
> library. The GPLv2 alternative in that same exception is explicitly pinned to v2 ("not
> v2.2 or v3.x"), so this project does not rely on it at all -- it relies on the linking
> permission, and that is what makes shipping an **AGPL-3.0-or-later** application on top of
> libgit2 lawful. Combined with the Apache-2.0 OpenSSL build, AiwliGit is distributable as a
> whole under **AGPL-3.0-or-later**.

## Vendored source (shipped with the repository)

| Component | License | Source |
| --- | --- | --- |
| Cargokit (rust_builder/cargokit) | MIT | https://github.com/irondash/cargokit |

## Build tooling (not shipped in the APK)

Gradle, Android Gradle Plugin, Kotlin — their licenses (Apache-2.0, MIT etc.)
apply to the build environment only.

## Trademarks

GitHub, GitLab, 云效/Codeup, Google Play and Android are trademarks of their
respective owners. AiwliGit is an independent client and is not affiliated
with, endorsed by, or sponsored by any of them.