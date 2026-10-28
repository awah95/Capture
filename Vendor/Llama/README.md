# llama.cpp runtime and S1-mini model

Captur embeds the unmodified macOS universal framework from llama.cpp release
`b11275`, SHA-256 of `llama-b11275-xcframework.zip`:
`e8efdeb93773307d389cdfd247d10c0aa62c3014f92809c20de2741573c3a882`.
Source/release: https://github.com/ggml-org/llama.cpp/releases/tag/b11275
The runtime is MIT licensed; see `llama-LICENSE`. No helper server is launched.

S1-mini by Superwhisper is an optional, separately downloaded model. Captur pins
`superwhisper/s1-mini-GGUF` revision
`34add00a48a2e5d24e5a4ee5405a99620a3a240c`, file `s1-mini-q4_k_m.gguf`
(484219808 bytes), SHA-256
`3b41ebe2502cbd03e811d5d16b022f5ab551eda58d62597d152f89535003c634`.
The weights are not bundled in the repository or app. The full model license and
NOTICE are retained here and copied into app resources by `project.yml`.

To reproduce the framework:

```sh
curl -fL https://github.com/ggml-org/llama.cpp/releases/download/b11275/llama-b11275-xcframework.zip -o /tmp/captur-llama.zip
shasum -a 256 /tmp/captur-llama.zip
# Verify the digest above before extracting.
unzip /tmp/captur-llama.zip 'build-apple/llama.xcframework/macos-arm64_x86_64/*' -d /tmp/captur-llama
cp -R /tmp/captur-llama/build-apple/llama.xcframework/macos-arm64_x86_64/llama.framework Vendor/Llama/
```

Model source: https://huggingface.co/superwhisper/s1-mini-GGUF/tree/34add00a48a2e5d24e5a4ee5405a99620a3a240c
Prompt contract: https://huggingface.co/superwhisper/s1-mini
