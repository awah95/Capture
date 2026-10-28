# Moonshine native runtime

Captur links the official Moonshine Swift `0.1.5` macOS static library directly.
The library is downloaded during setup instead of being committed to this
repository. This avoids redistributing a large binary while keeping the exact
upstream artifact and checksum reproducible.

From the repository root, run:

```sh
./scripts/bootstrap-moonshine.sh
```

The script downloads the pinned XCFramework release, verifies the archive and
the extracted macOS library and header, then writes only:

- `Vendor/Moonshine/lib/libmoonshine.a`
- `Vendor/Moonshine/include/moonshine-c-api.h`

The custom `CapturMoonshineC` module map remains tracked. It prevents Xcode
from copying Moonshine's and FluidAudio's unrelated `module.modulemap` files to
the same build-product path.

Source release:
https://github.com/moonshine-ai/moonshine-swift/releases/tag/v0.1.5

Pinned SHA-256 values:

- `Moonshine.xcframework.zip`: `6bc7fb4b6d3a470a2ae2d681299975f3ba9d710753786d1cd7e8beabaad066e8`
- extracted macOS `libmoonshine.a`: `f35a8229c8c67ddb4982f1a5a8765ae93377d42f7ecaf4bbbc17547665abccbb`
- `include/moonshine-c-api.h`: `e5c9038c4987d87f40abd78f843bd6ab0bff96a5ffd1cc2557c5531b0cbab21f`

The upstream library contains both macOS `arm64` and `x86_64` slices. Captur is
currently Apple-Silicon-only because `ARCHS` is pinned to `arm64` in
`project.yml`.

Moonshine's own code and English streaming models are MIT-licensed. The
upstream static archive also contains third-party components. Before shipping
a prebuilt Captur app, collect and include the notices required by those
components; the upstream release archive does not include a combined notice
file.

Moonshine's MIT text is retained in [Moonshine-LICENSE](Moonshine-LICENSE) and included in app resources.
