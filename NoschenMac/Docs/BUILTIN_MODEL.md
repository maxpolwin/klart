# Built-in on-device model

The "Built-in (private, no setup)" provider runs a small instruct model
in-process via [llama.cpp](https://github.com/ggml-org/llama.cpp) — no
Ollama, no LM Studio, no server, no open port. Model weights are downloaded
on first use into `~/Library/Application Support/Noschen/Models/`,
SHA256-verified when pinned, and can be removed again from Settings.

Two artifacts are involved that are deliberately **not** checked into git:

1. the **llama.xcframework** (the inference engine, built once per pinned
   llama.cpp release), and
2. the **model weights** (downloaded by the app at runtime).

## 1. Vendoring the llama.xcframework

Upstream llama.cpp no longer ships a `Package.swift`; the supported Apple
path is its `build-xcframework.sh`. One-time, on a Mac with Xcode:

```bash
# Pick a recent release tag and pin it (record the tag in your PR).
git clone --depth 1 --branch <bXXXX> https://github.com/ggml-org/llama.cpp
cd llama.cpp
./build-xcframework.sh
```

Keep only the macOS slices (arm64 + x86_64) to cut size — the iOS/tvOS/
visionOS slices can be deleted from `build-apple/llama.xcframework` (edit
its `Info.plist` accordingly), then:

```bash
cp -R build-apple/llama.xcframework /path/to/Noschen/NoschenMac/Vendor/
```

Enable it for local builds (from `NoschenMac/`):

```bash
export NOSCHEN_LLAMA_XCFRAMEWORK=Vendor/llama.xcframework
swift build && swift run
```

Without the env var, `LlamaBridge` compiles a stub: the app builds and runs
everywhere (including CI, which never needs the binary artifact), and the
Built-in provider reports "runtime not bundled" if selected.

Verify the artifact before adopting it:

- `find Vendor/llama.xcframework -name '*.metallib'` — the Metal shader
  library must be embedded (ggml loads it from the framework bundle at
  runtime).
- If the macOS slice is a **dynamic** framework, `Scripts/make-app.sh` must
  additionally copy it into `Noschen.app/Contents/Frameworks/` and the
  executable needs an `@executable_path/../Frameworks` rpath (add to
  `linkerSettings` in Package.swift). The existing `codesign --force --deep`
  already signs embedded frameworks. If it is static, packaging is
  unchanged.
- Smoke-test immediately with `swift run`: select the Built-in provider,
  download the small model, and confirm a feedback round completes.

To distribute without every contributor building the framework, zip it,
publish it as a GitHub release asset on this repo, and switch
`Package.swift` to a checksum-pinned remote binary target:

```swift
.binaryTarget(
    name: "llama",
    url: "https://github.com/maxpolwin/Noschen/releases/download/llama-<bXXXX>/llama-macos.xcframework.zip",
    checksum: "<output of: swift package compute-checksum llama-macos.xcframework.zip>"
),
```

Upgrading llama.cpp is then one intentional PR: rebuild, re-upload, bump
URL + checksum.

## 2. Pinning the model downloads

`Sources/NoschenKit/LLM/ModelRegistry.swift` lists the downloadable models.
Every entry should be pinned (revision-commit URL + exact size + SHA256) so
the bytes can never change underneath the checksum:

```bash
curl -s 'https://huggingface.co/api/models/Qwen/Qwen2.5-1.5B-Instruct-GGUF?blobs=true'
```

- `sha` → the revision commit; use it in the URL:
  `…/resolve/<sha>/qwen2.5-1.5b-instruct-q4_k_m.gguf`
- `siblings[].size` → `sizeBytes`
- `siblings[].lfs.oid` → `sha256`

The 0.5B entry is fully pinned (values carried over from the legacy
Electron registry). **The 1.5B entry still needs pinning** — the
environment this feature was developed in couldn't reach huggingface.co.
Until pinned, the downloader verifies the 1.5B file against the
server-reported Content-Length only (over TLS). Pin it before shipping a
release; `ModelRegistryTests.testPinnedEntriesArePinnedConsistently`
enforces the invariants once the values are filled in.

## Developer-only integration test

Unit tests never touch the network or real weights. To run the real
inference smoke test:

```bash
export NOSCHEN_LLAMA_XCFRAMEWORK=Vendor/llama.xcframework
NOSCHEN_BUILTIN_MODEL_PATH=~/models/qwen2.5-0.5b-instruct-q4_k_m.gguf swift test \
  --filter BuiltinIntegrationTests
```

## Behavior notes

- Fresh installs default to the Built-in provider; existing users keep
  whatever provider their settings.json names.
- Weights load lazily on first request and stay resident; they unload after
  ~15 minutes idle, on memory pressure, or when the model is deleted in
  Settings.
- Inference is serialized (one generation at a time); a feedback round that
  arrives while a coach action streams simply queues.
- `jsonMode` uses grammar-constrained sampling (GBNF), so the feedback
  parser always receives syntactically valid JSON from the built-in model.
- On Intel Macs the model runs CPU-only (ggml's Metal backend requires an
  Apple GPU); on Apple Silicon all layers are offloaded to Metal.
