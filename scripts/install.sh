#!/bin/bash
#
# Build Captur and install it to /Applications — repeatably.
#
# Run this every time you want the installed app to catch up with the code. It is
# deliberately the ONLY supported way to install, because two details decide whether
# macOS treats a new build as the same app or as a stranger:
#
#   1. **A stable code signature.** An ad-hoc signature (`-s -`) is derived from the
#      binary's own hash, so every rebuild is a different identity: microphone,
#      accessibility and input-monitoring grants are dropped and the Keychain re-prompts
#      for the API key, EVERY time. Signing with your Apple Development certificate keeps
#      one identity across rebuilds, so permissions are granted once and then stay.
#
#   2. **A stable path.** TCC keys its answers to the bundle path as well. /Applications
#      is the path that will not change; a DerivedData path changes with every worktree.
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Captur"
APP_PARENT="/Applications"
DEST="${APP_PARENT}/${APP_NAME}.app"
BUILD_DIR="${REPO}/build/public"

STAGE_ROOT=""
STAGED_APP=""
BACKUP_ROOT=""
BACKUP_APP=""
INSTALL_COMPLETE=0

on_exit() {
    status=$?
    trap - EXIT

    # If installation failed after the old app moved aside, restore it. A same-volume
    # directory move is atomic, so DEST is either present or absent here.
    if [ "$INSTALL_COMPLETE" -ne 1 ] && [ -n "$BACKUP_APP" ] && [ -d "$BACKUP_APP" ]; then
        if [ ! -e "$DEST" ]; then
            echo "==> Restoring the previous ${APP_NAME}.app" >&2
            if mv "$BACKUP_APP" "$DEST"; then
                rmdir "$BACKUP_ROOT" 2>/dev/null || true
                BACKUP_ROOT=""
            else
                echo "✗ Automatic rollback failed. The previous app is preserved at:" >&2
                echo "  ${BACKUP_APP}" >&2
            fi
        else
            echo "Previous app preserved at ${BACKUP_APP}" >&2
        fi
    fi

    if [ -n "$STAGE_ROOT" ] && [ -d "$STAGE_ROOT" ]; then
        rm -rf "$STAGE_ROOT" || true
    fi
    if [ -n "$BACKUP_ROOT" ] && [ -d "$BACKUP_ROOT" ] \
        && [ ! -e "$BACKUP_APP" ]; then
        rmdir "$BACKUP_ROOT" 2>/dev/null || true
    fi

    exit "$status"
}

trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

cd "$REPO"

# --- the signing identity -----------------------------------------------------------
# Prefer an explicit CAPTUR_SIGN_IDENTITY; otherwise use an Apple Development identity
# in the keychain. Ad-hoc is the fallback and is announced loudly, because it silently
# costs you your permissions on every future update.
IDENTITY="${CAPTUR_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n '/"Apple Development:/s/^ *[0-9][0-9]*) \([A-F0-9]*\) .*/\1/p' | head -1)"
fi
if [ -z "$IDENTITY" ]; then
    IDENTITY="-"
    echo "⚠︎  No codesigning identity found — falling back to ad-hoc."
    echo "   macOS will treat every future build as a different app: expect to re-grant"
    echo "   microphone, accessibility and input monitoring after each install."
fi

echo "==> Building ${APP_NAME} (Release)"
"$REPO/scripts/build.sh" release
BUILT="${BUILD_DIR}/Build/Products/Release/${APP_NAME}.app"
[ -d "$BUILT" ] || { echo "✗ build produced no app at ${BUILT}"; exit 1; }

# --- stage and sign ------------------------------------------------------------------
# Keep every preparatory write beside the final destination. The verified app and its
# backup can then move into place atomically on the same filesystem.
STAGE_ROOT="$(mktemp -d "${APP_PARENT}/.${APP_NAME}.install.XXXXXX")"
STAGED_APP="${STAGE_ROOT}/${APP_NAME}.app"
cp -R "$BUILT" "$STAGED_APP"

# Sign nested code before its containing bundle. Use --deep only for verification.
echo "==> Signing with ${IDENTITY}"
find "$STAGED_APP/Contents" -type f -name "*.dylib" -print0 \
    | xargs -0 -I {} codesign --force --timestamp=none --sign "$IDENTITY" "{}"
find "$STAGED_APP/Contents" -depth -type d -name "*.framework" -print0 \
    | xargs -0 -I {} codesign --force --timestamp=none --sign "$IDENTITY" "{}"
codesign --force --timestamp=none --sign "$IDENTITY" "$STAGED_APP"
codesign --verify --deep --strict --verbose=2 "$STAGED_APP"

# --- replace the installed copy ------------------------------------------------------
# Do not disturb the running or installed app until its replacement is fully signed and
# verified. The backup remains available to the EXIT trap until the final move succeeds.
if [ -L "$DEST" ] || { [ -e "$DEST" ] && [ ! -d "$DEST" ]; }; then
    echo "✗ Refusing to replace a non-application path: ${DEST}" >&2
    exit 1
fi

if pgrep -x "$APP_NAME" >/dev/null; then
    echo "==> Quitting the running ${APP_NAME}"
    osascript -e "tell application \"${APP_NAME}\" to quit" 2>/dev/null || pkill -x "$APP_NAME" || true
    sleep 2
    pkill -x "$APP_NAME" 2>/dev/null || true
fi

if [ -e "$DEST" ]; then
    BACKUP_ROOT="$(mktemp -d "${APP_PARENT}/.${APP_NAME}.backup.XXXXXX")"
    BACKUP_APP="${BACKUP_ROOT}/${APP_NAME}.app"
    mv "$DEST" "$BACKUP_APP"
fi

echo "==> Installing verified app at ${DEST}"
mv "$STAGED_APP" "$DEST"
INSTALL_COMPLETE=1

if [ -n "$BACKUP_ROOT" ] && [ -d "$BACKUP_ROOT" ]; then
    if rm -rf "$BACKUP_ROOT"; then
        BACKUP_ROOT=""
        BACKUP_APP=""
    else
        echo "Installed successfully; the previous app remains at ${BACKUP_APP}" >&2
    fi
fi

# The installed app always launches from the stable path above. Leave Xcode's caches
# alone: they are outside this checkout and Xcode owns their lifecycle.

cat <<'NOTE'

Installed. Two things worth knowing:

  • The FIRST launch from /Applications is a new identity to macOS, so microphone,
    accessibility and input monitoring have to be granted once more, and the Keychain
    will ask once about the API key — click "Always Allow". Every install after this
    one keeps them, because the signature and the path both stay the same.

  • Launch at login is NOT enabled by this script. It is a toggle in
    Settings → General, and turning it on is your call, not the installer's.

Launch /Applications/Captur.app normally to complete first-run setup.

To update after a code change, run this script again.
NOTE
