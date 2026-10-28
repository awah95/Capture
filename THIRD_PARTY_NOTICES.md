# Third-party notices

## Phonon-2 Core ML

Capture optionally uses [Phonon-2 Core ML](https://huggingface.co/FermionResearch/Phonon-2-CoreML)
by Fermion Research for English batch transcription on the Mac's Neural Engine.
The unmodified [Swift runtime and static decoder](https://github.com/fermionresearch/phonon-coreml)
are pinned to tag `1.1.2` (commit `bf59e574639b060e30ee1a3f9c0e003fed5744c8`), under Apache-2.0.
The separately downloaded weights are pinned to revision
`48af304c8db8bcc25307c206c199612f48479954`, under CC-BY-4.0.

Phonon-2 is copyright 2026 Fermion Research and derives from NVIDIA's Parakeet
TDT 0.6B v3, copyright NVIDIA Corporation, under CC-BY-4.0. Fermion trained,
quantized, and converted the model as described in its retained NOTICE. Capture
does not modify the source weights; Core ML compiles a derived cache locally.
See [provenance, full licenses and notices](Vendor/Phonon/README.md). These files
are also included in the app bundle's Phonon resources folder.

## FluidAudio

Captur uses [FluidAudio](https://github.com/FluidInference/FluidAudio),
copyright Fluid Inference and contributors, under the Apache License 2.0.

License: https://www.apache.org/licenses/LICENSE-2.0

## Parakeet Unified 0.6B Core ML

When on-device transcription is enabled, Captur downloads the
[Parakeet Unified English 0.6B Core ML model](https://huggingface.co/FluidInference/parakeet-unified-en-0.6b-coreml)
prepared by Fluid Inference from NVIDIA's Parakeet Unified model. The model is
made available under the Creative Commons Attribution 4.0 International license.

License: https://creativecommons.org/licenses/by/4.0/

## Moonshine Voice

Captur optionally uses [Moonshine Voice](https://github.com/moonshine-ai/moonshine-swift)
and its English Medium Streaming model for low-latency on-device transcription.
The Moonshine native library is not committed to this source repository. The
source build downloads the official `0.1.5` XCFramework and verifies its pinned
SHA-256 checksum before extracting the macOS library and public header; see the
[artifact provenance and setup instructions](Vendor/Moonshine/README.md).

Moonshine's own code and English streaming models are copyright Useful Sensors,
Inc. and contributors under the MIT License. The native release archive also
contains third-party components and does not include a combined notice file.
Anyone distributing a prebuilt app must collect and retain the notices required
by those components.

Moonshine license: [Moonshine-LICENSE](Vendor/Moonshine/Moonshine-LICENSE), retained in app resources.
Upstream: https://github.com/moonshine-ai/moonshine/blob/main/LICENSE

## MediaRemote Adapter

Captur includes the get/metadata portion of
[mediaremote-adapter](https://github.com/ungive/mediaremote-adapter), pinned to
commit `73f14ab1568371e6e3c44063f21c34c5e2712c4d`, under the BSD 3-Clause License.
Captur modifies `src/adapter/get.m` so a query timeout exits unsuccessfully.
See the [full license](Vendor/MediaRemoteAdapter/LICENSE) and
[source provenance](Vendor/MediaRemoteAdapter/README.md). The license is also
included in the app bundle resources.

## S1-mini by Superwhisper

Captur optionally downloads **S1-mini** by **Superwhisper** for on-device English
Clean-mode text normalization. It is based on Qwen3-0.6B and distributed under
Apache License 2.0 plus an additional term requiring identification as
"S1-mini" by "Superwhisper" with that exact capitalization. The unmodified
Q4_K_M weights are pinned to revision
`34add00a48a2e5d24e5a4ee5405a99620a3a240c` and are downloaded directly from upstream.

Full license: [S1-mini-LICENSE](Vendor/Llama/S1-mini-LICENSE).
Attribution: [S1-mini-NOTICE](Vendor/Llama/S1-mini-NOTICE).
Both files are also included in the app bundle resources. Redistribution must
retain them; modified distributions must identify significant changes.

## llama.cpp

Captur embeds the unmodified macOS native framework from llama.cpp `b11275`,
under the MIT License. See [llama-LICENSE](Vendor/Llama/llama-LICENSE) and
[artifact provenance](Vendor/Llama/README.md). The license is included in app resources.

## Gemma 4 and MLX

Captur optionally downloads Gemma 4 E2B instruction-tuned QAT 4-bit weights from
[mlx-community](https://huggingface.co/mlx-community/gemma-4-E2B-it-qat-4bit),
pinned to revision `42f62737af7a9fd8c1d55d79666c1a217be4e2e2`. Gemma 4 is
provided by Google DeepMind under [Apache 2.0](https://ai.google.dev/gemma/apache_2).
No weights are embedded in the application.

Native text inference uses Apple's [MLX Swift](https://github.com/ml-explore/mlx-swift)
0.31.6 and [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm) 3.31.4
(MIT), with Hugging Face Swift Transformers 1.3.0 for local tokenization.
Dependency license texts are retained in
[THIRD_PARTY_LICENSES.txt](Vendor/MLX/THIRD_PARTY_LICENSES.txt) and included in app resources.

## Qwen3.5 4B

Captur optionally downloads the unmodified MLX 6-bit conversion of Alibaba's
[Qwen3.5-4B](https://huggingface.co/Qwen/Qwen3.5-4B) from
[mlx-community/Qwen3.5-4B-6bit](https://huggingface.co/mlx-community/Qwen3.5-4B-6bit),
pinned to revision `fbb1092aa9daef007603ea9273cd24c225a409f1`. The model is licensed
under Apache License 2.0. No weights are bundled with Captur.

The full [license](Vendor/MLX/Qwen3.5-LICENSE) is retained in source and app resources,
from upstream model revision `851bf6e806efd8d0a36b00ddf55e13ccb7b8cd0a`.
