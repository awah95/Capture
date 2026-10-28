# Phonon-2 Core ML provenance

Capture links the unmodified `PhononCoreML` Swift package, including its static
`PhononTDT` decoder XCFramework, through Swift Package Manager:

- Upstream: https://github.com/fermionresearch/phonon-coreml
- Exact tag: `1.1.2`
- Commit: `bf59e574639b060e30ee1a3f9c0e003fed5744c8`
- Runtime license: Apache-2.0; full license and NOTICE retained here and in app resources.

Model weights download separately from
https://huggingface.co/FermionResearch/Phonon-2-CoreML at immutable revision
`48af304c8db8bcc25307c206c199612f48479954`. They are not included in Git or the app
bundle. All eight downloaded files have fixed byte sizes and SHA-256 digests in
`Sources/Modules/Transcription/PhononModel.swift`, checked against upstream
`SHA256SUMS` and Git LFS metadata. The model license and NOTICE are also downloaded
and verified with the weights.

Weights are CC-BY-4.0, copyright 2026 Fermion Research, derived from NVIDIA's
Parakeet TDT 0.6B v3. Preserve both attribution chains and the supplied model NOTICE.
Fermion's NOTICE describes its training/quantization and Core ML conversion.
Capture does not alter the downloaded source weights. It compiles the Core ML
package on the user's Mac and stores that derived cache beside the original
weights, under `~/Library/Application Support/Captur/Models/Phonon2/`.

The full runtime and weight licenses and their notices are retained in this
directory and copied into the app's `Phonon` resources folder. The Settings model
card links to the model attribution and CC-BY-4.0 license.
