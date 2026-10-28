# Install Capture from source

The public repository is named **Capture**. The current Xcode target and built application are still named **Captur**, so the commands and paths below use `Captur` where the source currently requires it.

## Requirements

- An Apple silicon Mac (`arm64`)
- macOS 26.2 or later to build from source (the app deployment target is macOS 26.0)
- Xcode 26.4.1 or later with Swift 6.3 or later, selected with `xcode-select`
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.46 or later
- Internet access for the pinned Swift package dependencies and Moonshine runtime
- The Xcode Metal compiler component, required by the MLX cleanup models

The pinned MLX package requires Swift 6.3; Xcode 26.3 and earlier cannot build it. Local verification used Xcode 27.1 and Swift 6.4. The GitHub CI workflow targets the Swift 6.3 toolchain on the macOS 26 runner; its first hosted run remains to be verified.

Install Xcode from Apple and open it once to accept its license. If a different Xcode installation is selected, prepare the command-line tools:

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
xcodebuild -runFirstLaunch
xcodebuild -downloadComponent MetalToolchain
```

Install XcodeGen with Homebrew if it is not already available:

```sh
brew install xcodegen
```

## Get the source

Clone this repository using its GitHub **Code** button, then open its `Capture` directory in Terminal.

The build helper downloads the pinned Moonshine runtime from its official upstream release and verifies the archive, library, and header checksums before use. The downloaded library stays outside Git. The llama runtime is included with its provenance and license in `Vendor/Llama/`.

The build helper generates `Captur.xcodeproj`, bootstraps the native runtime, and applies the checked-in package lock. The generated project is intentionally ignored by Git; use the helper again whenever `project.yml` changes.

## Build without installing

This command keeps all generated output inside the clone and does not change `/Applications`:

```sh
./scripts/build.sh debug
```

The unsigned result is at:

```text
build/public/Build/Products/Debug/Captur.app
```

For a Release compilation check, run `./scripts/build.sh release`. The helper uses two build jobs by default; set `CAPTURE_BUILD_JOBS` to adjust this. The scripts use the checked-in `Package.resolved` to keep transitive package versions fixed.

Use this path for compilation checks. For normal dictation use, install the application as described below so its path and signature remain stable across rebuilds.

## Run the tests

Run the test scheme through the same bootstrap and locked-dependency path:

```sh
./scripts/build.sh test
```

## Install for normal use

The included installer builds a Release application, signs and verifies a staged copy, then quits a running copy of Captur and **replaces `/Applications/Captur.app`**. It keeps the previous app as a same-filesystem backup until the verified replacement is in place and restores that backup if the final move fails. Review the destination before running it if Captur is already installed.

```sh
./scripts/install.sh
```

The installer uses an available Apple Development identity, or falls back to ad-hoc signing. To choose a signing identity explicitly:

```sh
CAPTUR_SIGN_IDENTITY='Apple Development: Your Name (TEAMID)' ./scripts/install.sh
```

An Apple Developer account is not required. If no signing identity is available, the script uses an ad-hoc signature. Ad-hoc signing works for a local source build, but macOS can treat each rebuilt binary as a different application and ask for its permissions and Keychain access again. A stable Apple Development identity avoids those repeated prompts.

This source build is not an Apple-notarized binary distribution. It is built and signed locally on the Mac that will run it.

## First launch

Launch `/Applications/Captur.app`. The setup screen guides you through the permissions needed for dictation:

- **Microphone** records speech.
- **Accessibility** inserts the result at the current cursor.
- **Input Monitoring** detects the default push-to-talk key while another application is active.

The default transcription provider is Groq, so a Groq API key is requested on a new installation and stored in the macOS Keychain. An OpenRouter key is requested only when a configured mode uses OpenRouter. You can select an on-device transcription provider in Settings and explicitly download its model instead of using Groq.

Local transcription and cleanup model weights are not stored in this repository. Downloads are initiated from Settings and stored under:

```text
~/Library/Application Support/Captur/Models/
```

Some optional cleanup models are several gigabytes. The current documented approximate sizes are 4.36 GB for Gemma 4 E2B and 4.1 GB for Qwen3.5 4B.

## Update a source installation

Pull the new source and run the same installer. The installer regenerates the Xcode project and applies the package lock. Keep the same signing identity so macOS continues to recognize the application:

```sh
git pull --ff-only
CAPTUR_SIGN_IDENTITY='Apple Development: Your Name (TEAMID)' ./scripts/install.sh
```


## License

Capture's original code is available under the [MIT License](LICENSE). Vendored runtimes and optional model weights retain their own licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
