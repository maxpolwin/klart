# Vendored third-party code: Argon2 (PHC reference implementation)

This directory contains a frozen, minimal copy of the **Password Hashing
Competition winner Argon2 reference implementation** — the only third-party
code in Noschen. It is vendored (copied in-tree, never fetched at build
time), so there is no live supply-chain channel: these exact bytes were
reviewed and verified once and can only change via an auditable commit.

## Provenance

- Upstream project: https://github.com/P-H-C/phc-winner-argon2
- Obtained from: the `argon2-cffi-bindings` 25.1.0 source distribution on
  PyPI (maintained by Hynek Schlawack), which vendors the upstream repo as
  a git submodule under `extras/libargon2`.
  - sdist URL: https://files.pythonhosted.org/packages/5c/2d/db8af0df73c1cf454f71b2bbe5e356b8c1f8041c979f505b3d3186e520a9/argon2_cffi_bindings-25.1.0.tar.gz
  - sdist SHA-256 (matches the digest published by PyPI):
    `b957f3e6ea4d55d820e40ff76f450952807013d361a65d7f28acc0acbf29229d`
- License: CC0 1.0 / Apache 2.0 dual license (see `LICENSE`).

## Verification performed at vendoring time

The exact file set below was compiled with the upstream test harness
(`src/test.c`, not vendored) and **all 37 official Argon2 test vectors
passed** before the files were copied here.

## File inventory (SHA-256)

```
ac36638bcfcedb75441a5daeeaf4ef75b565911712583c272830e9fa7fddb590  LICENSE
25ed629feca91ca9d361441160c6fbc10318bb0fb3757555b418ed47b705b35b  include/argon2.h
b1289ec7134e8502e9113396fdac89402bf2575ee1b35e33fb7410f2fb63bb6d  src/argon2.c
d6ddc9e28c51d2c3b0d542c0c4678c4d9d788da048e4f557166030d0ef62618b  src/core.c
7b9a0c019abc6fca7e6e0a9abd2f7b22a885f8831827cfbd4bfd4502dd9f7806  src/encoding.c
9ac347fd8dc737af69bbb93d56ac8b4ab5488152f606880c8d7fc4592e207647  src/ref.c
af2ab481fcf5ef00f1b2deb346bda3642797b417fc0ed98bfb7ae80e716f90d1  src/thread.c
32f6ab8c0c313d9336d2731a001426b68d246bba5b362fabeaf593c333da7d37  src/core.h
a4e0681ef4b0eb229a35760b603b7a32e9019cfe98c31732f747f087e5e39828  src/encoding.h
650e713fb584de2e6aeb307e64228f95cef733ea667faa0bb111960aaace30ef  src/thread.h
ec9884fe834c30eb362f0cef3432a43a5c496b0d6d1d637a5a590a45bec4d79c  src/blake2/blake2-impl.h
196cd9adf0660474ea04cb686c122f3ca8c758445c5ff0806f438e6412ac8423  src/blake2/blake2.h
7eb2f3faac14c532fb75f645f518686f3ef0db4c7b9849a1ffc73d262b596281  src/blake2/blake2b.c
8d5fc886bbc0b55af10ac6f1e9a5995a4e8d4abace46642fb1832c84d38c3007  src/blake2/blamka-round-ref.h
```

Only the portable reference backend (`ref.c`) is vendored — not the SIMD
`opt.c` — for maximum auditability and portability. The CLI, benchmarks,
and KAT generators from upstream are intentionally omitted.

Verify at any time with: `cd Sources/CArgon2 && shasum -a 256 -c` against
the list above.
