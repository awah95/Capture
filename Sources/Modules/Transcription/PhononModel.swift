import Foundation

/// Immutable upstream Core ML export. No Python runtime or model weights are bundled.
/// SHA-256 values match the pinned repository's SHA256SUMS and LFS metadata.
enum PhononModel {
    static let manifest = CleanupModelManifest(
        repository: "FermionResearch/Phonon-2-CoreML",
        revision: "48af304c8db8bcc25307c206c199612f48479954",
        artifacts: [
        .init(name: "manifest.json", bytes: 1428,
              sha256: "ab3fb5dfd3fc07b1d8a24379d04418f458d0443ba6359d3a5ab2f098a7d64089"),
        .init(name: "Phonon-2.mlpackage/Manifest.json", bytes: 617,
              sha256: "6ebc9309aea0e16bda9c7558521fef6307fac0afba9a5b4959fea45ed7cd0429"),
        .init(name: "Phonon-2.mlpackage/Data/com.apple.CoreML/model.mlmodel", bytes: 2500482,
              sha256: "4f6790ec94fe4429b10397c013563d0a51119953ff6d3da466bbcb23a25dee2a"),
        .init(name: "Phonon-2.mlpackage/Data/com.apple.CoreML/weights/weight.bin", bytes: 329186560,
              sha256: "93aa991318a00ed492fdbb724e7bca4e6a69c6cf671ab4f14a14ef6101e7648b"),
        .init(name: "decoder.bin", bytes: 13301279,
              sha256: "36fa7202dda85c603af60d930ab88d7e9f0d2a619490aff46f5384db924cfa70"),
        .init(name: "LICENSE-WEIGHTS-CC-BY-4.0.txt", bytes: 18657,
              sha256: "9ba9550ad48438d0836ddab3da480b3b69ffa0aac7b7878b5a0039e7ab429411"),
        .init(name: "LICENSE-CODE-Apache-2.0.txt", bytes: 11358,
              sha256: "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30"),
        .init(name: "NOTICE", bytes: 3084,
              sha256: "b468a23a1ce2c5181ea4050432bb68713a6468ce2e452927228d24f3d56226be"),
    ])
}
