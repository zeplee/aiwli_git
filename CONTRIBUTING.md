# Contributing to aiwli

Contributions are welcome under the **AGPL-3.0-or-later** license (inbound = outbound, see [LICENSE](LICENSE)).

## Developer setup

- Flutter (stable) + Rust toolchain. Android builds need the NDK plus perl / cmake / make / gcc
  (git2 and openssl are built vendored from source).
- The Dart side lives in `lib/`, the Rust engine in `rust/`, the FFI bridge in `rust_builder/`.

## Gates (run before opening a PR)

```sh
dart format lib test
flutter analyze --fatal-infos    # 0 issues
flutter test --no-pub            # all green
cd rust && cargo test --release  # Rust unit tests
```

CI (`.github/workflows/ci.yml`) runs the same gates on every PR.

## Commit sign-off (DCO)

Every commit must include a `Signed-off-by` line asserting the
[Developer Certificate of Origin 1.1](https://developercertificate.org/):

```sh
git commit -s -m "feat: your change"
```

By signing off you certify:

> **Developer Certificate of Origin — Version 1.1**
>
> Copyright (C) 2004, 2006 The Linux Foundation and its contributors.
> Everyone is permitted to copy and distribute verbatim copies of this license document,
> but changing it is not allowed.
>
> By making a contribution to this project, I certify that:
>
> (a) The contribution was created in whole or in part by me and I have the right to submit it
>     under the open source license indicated in the file; or
>
> (b) The contribution is based upon previous work that, to the best of my knowledge, is covered
>     under an appropriate open source license and I have the right under that license to submit
>     that work with modifications, whether created in whole or in part by me, under the same
>     open source license (unless I am permitted to submit under a different license), as
>     indicated in the file; or
>
> (c) The contribution was provided directly to me by some other person who certified (a), (b)
>     or (c) and I have not modified it.
>
> (d) I understand and agree that this project and the contribution are public and that a record
>     of the contribution (including all personal information I submit with it, including my
>     sign-off) is maintained indefinitely and may be redistributed consistent with this project
>     or the open source license(s) involved.

## Relicensing grant

By submitting a contribution you additionally grant the maintainers a non-exclusive,
perpetual, worldwide, royalty-free license to relicense your contribution under
**other license terms** (including commercial terms) as part of this project.

Why: the project is copyleft by design -- anyone who redistributes a modified build must
open their source too. Copyleft only stays workable if the maintainers can still legally
place official builds wherever they ship them, and some channels' terms can conflict with
that requirement (VLC was removed from the App Store for exactly this reason). Keeping
relicensing possible lets the maintainers add distribution channels later, and lets them
sell a commercial licence to anyone who wants to ship this code without the copyleft
obligations -- without every contributor having to be asked again.

If you do not accept this, please do not submit code -- open an issue instead.

## Naming / branding

The name "aiwli", the logo, and related branding are **not** licensed under the AGPL-3.0
(the licence covers the code, not the brand). Forks and derivatives must rename the app
and replace its artwork (see README → License).
