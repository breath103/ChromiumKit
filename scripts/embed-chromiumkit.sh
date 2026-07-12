#!/usr/bin/env bash
# embed-cefview.sh — embed CEF framework + 5 helper apps into a host .app bundle.
#
# Designed to run from an Xcode "Run Script Build Phase" after Xcode has
# produced the host app at $BUILT_PRODUCTS_DIR/$PRODUCT_NAME.app. Picks up
# everything else from environment variables Xcode sets.
#
# Required env:
#   BUILT_PRODUCTS_DIR     — $TARGET_BUILD_DIR from Xcode
#   PRODUCT_NAME           — host app target name (no .app suffix)
#   PRODUCT_BUNDLE_IDENTIFIER — host bundle id (e.g. com.acme.MyApp)
#   CHROMIUMKIT_FRAMEWORK_PATH — path to "Chromium Embedded Framework.framework"
#   CHROMIUMKIT_HELPER_PATH    — path to a prebuilt helper executable (one binary
#                            is reused for all 5 helpers, only plist differs)
#   CHROMIUMKIT_HELPER_PLIST   — path to helper.plist.in template
#
# Optional env:
#   EXPANDED_CODE_SIGN_IDENTITY — Xcode-provided signing identity (default: -)
#   CHROMIUMKIT_HELPER_ENTITLEMENTS — path to the helper hardened-runtime
#                            entitlements plist applied when re-signing helpers
#                            with a real Developer ID identity (default: the
#                            package's Resources/entitlements/CEFKit.helper.entitlements)
#
# Standalone usage:
#   BUILT_PRODUCTS_DIR=out PRODUCT_NAME=Demo PRODUCT_BUNDLE_IDENTIFIER=foo.demo \
#   CHROMIUMKIT_FRAMEWORK_PATH=... CHROMIUMKIT_HELPER_PATH=... CHROMIUMKIT_HELPER_PLIST=... \
#   ./scripts/embed-cefview.sh

set -euo pipefail

: "${BUILT_PRODUCTS_DIR:?required}"
: "${PRODUCT_NAME:?required}"
: "${PRODUCT_BUNDLE_IDENTIFIER:?required}"
: "${CHROMIUMKIT_FRAMEWORK_PATH:?required}"
: "${CHROMIUMKIT_HELPER_PATH:?required}"
: "${CHROMIUMKIT_HELPER_PLIST:?required}"

SIGN_ID="${EXPANDED_CODE_SIGN_IDENTITY:--}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER_ENTITLEMENTS="${CHROMIUMKIT_HELPER_ENTITLEMENTS:-$SCRIPT_DIR/../Resources/entitlements/CEFKit.helper.entitlements}"
APP="$BUILT_PRODUCTS_DIR/$PRODUCT_NAME.app"
FRAMEWORKS="$APP/Contents/Frameworks"

[[ -d "$APP" ]] || { echo "error: host app not found at $APP" >&2; exit 1; }
mkdir -p "$FRAMEWORKS"

echo "[ChromiumKit] embedding into $APP"

if [[ -n "${XCODE_PRODUCT_BUILD_VERSION:-}" ]]; then
  # Under Xcode the CCEF binary target is auto-embedded + signed via the
  # standard "Embed Frameworks" build phase Xcode generates from the SPM
  # dependency on ChromiumKit (which depends on CCEF). We must not touch it here.
  echo "[ChromiumKit]  → framework already embedded by Xcode, skipping"
else
  echo "[ChromiumKit]  → copying Chromium Embedded Framework"
  rm -rf "$FRAMEWORKS/Chromium Embedded Framework.framework"
  cp -R "$CHROMIUMKIT_FRAMEWORK_PATH" "$FRAMEWORKS/Chromium Embedded Framework.framework"
fi

# NB: framework Info.plist is injected into the framework at fetch-cef.sh
# time, before it gets packaged into CEF.xcframework. Doing it here would
# invalidate Xcode's framework codesign that already ran above.

embed_helper() {
  local label="$1"      # ""  | " (GPU)" | " (Renderer)" | " (Plugin)" | " (Alerts)"
  local id_suffix="$2"  # ""  | ".gpu"   | ".renderer"   | ".plugin"   | ".alerts"
  local exec_name="$PRODUCT_NAME Helper${label}"
  local app="$FRAMEWORKS/${exec_name}.app"
  local bundle_id="${PRODUCT_BUNDLE_IDENTIFIER}.helper${id_suffix}"

  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS"
  cp "$CHROMIUMKIT_HELPER_PATH" "$app/Contents/MacOS/${exec_name}"

  sed -e "s|__EXECUTABLE_NAME__|${exec_name}|g" \
      -e "s|__BUNDLE_ID__|${bundle_id}|g" \
      "$CHROMIUMKIT_HELPER_PLIST" > "$app/Contents/Info.plist"
}

echo "[ChromiumKit]  → assembling 5 helper bundles"
embed_helper ""            ""
embed_helper " (GPU)"      ".gpu"
embed_helper " (Renderer)" ".renderer"
embed_helper " (Plugin)"   ".plugin"
embed_helper " (Alerts)"   ".alerts"

# Helper bundle signing.
#
# Dev builds sign ad-hoc ("-"): we MUST leave the helper executables'
# linker-signed signatures untouched — Chromium's IPC handshake validates them
# byte-for-byte and a naive ad-hoc re-sign trips a CHECK inside
# cef_execute_process.
#
# For a REAL Developer ID identity we DO re-sign each helper .app with the
# Hardened Runtime + the helper entitlements. Apple notarization REJECTS the
# linker-signed helpers (un-notarizable, no secure timestamp, no runtime), so
# a shipping/notarized build needs proper same-team signatures — exactly what
# Chrome/Electron/Slack ship. Same-team re-signing keeps the IPC handshake valid
# because every process now shares one Team ID. Sign inside-out: each helper .app
# here → framework → (host signed last, by Xcode or the standalone branch below),
# so the enclosing seals include these signatures.
if [[ "$SIGN_ID" == "-" ]]; then
  echo "[ChromiumKit]  → ad-hoc identity: leaving helper linker-signatures intact"
else
  [[ -f "$HELPER_ENTITLEMENTS" ]] || {
    echo "error: helper entitlements not found at $HELPER_ENTITLEMENTS" >&2; exit 1;
  }
  echo "[ChromiumKit]  → signing 5 helpers (identity: $SIGN_ID, hardened runtime)"
  echo "[ChromiumKit]     entitlements: $HELPER_ENTITLEMENTS"
  for helper in "$FRAMEWORKS/"*Helper*.app; do
    codesign --force --sign "$SIGN_ID" --options runtime --timestamp \
      --entitlements "$HELPER_ENTITLEMENTS" "$helper"
  done
fi

# Pick the codesign timestamp flag based on the identity:
#   - a real Developer ID identity needs a SECURE timestamp (`--timestamp`),
#     which Apple notarization requires — this makes a network round-trip to
#     Apple's timestamp server.
#   - the ad-hoc identity ("-", local dev) can't get a secure timestamp anyway,
#     so use `--timestamp=none` to avoid the network round-trip and any
#     offline/CI flakiness.
if [[ "$SIGN_ID" == "-" ]]; then
  TIMESTAMP_FLAG="--timestamp=none"
else
  TIMESTAMP_FLAG="--timestamp"
fi

# Sign the framework's nested standalone dylibs.
#
# The CEF framework ships prebuilt Mach-O dylibs under Versions/A/Libraries
# (libEGL, libGLESv2, libvk_swiftshader, libcef_sandbox). These are NOT signed
# as part of signing the framework BUNDLE — codesign only seals the bundle's
# main binary + Resources, not arbitrary nested dylibs — so Apple notarization
# REJECTS them ("not signed with a valid Developer ID certificate" / "signature
# does not include a secure timestamp"). We must sign them ourselves.
#
# This runs REGARDLESS of the Xcode branch: Xcode signs the framework bundle and
# the host, but never reaches inside to sign these nested dylibs. We sign them
# inside-out — each dylib FIRST, before the enclosing framework bundle is sealed
# (by Xcode below, or by the standalone branch that follows) — so the bundle's
# seal covers valid dylib signatures.
#
# Glob *.dylib (don't hardcode names) so this stays correct if CEF adds/removes
# libraries in a future version.
FRAMEWORK="$FRAMEWORKS/Chromium Embedded Framework.framework"
LIBRARIES="$FRAMEWORK/Versions/A/Libraries"
if [[ -d "$LIBRARIES" ]]; then
  echo "[ChromiumKit]  → signing framework nested dylibs (identity: $SIGN_ID, hardened runtime)"
  for dylib in "$LIBRARIES/"*.dylib; do
    [[ -e "$dylib" ]] || continue  # glob matched nothing
    codesign --force --sign "$SIGN_ID" --options runtime "$TIMESTAMP_FLAG" "$dylib"
  done
fi

# Sign the framework BUNDLE — regardless of the Xcode branch, and AFTER the
# nested dylibs above.
#
# This must run under Xcode too. Under Xcode the framework is auto-embedded and
# signed on copy, but the nested-dylib signing above reseals files *inside* the
# bundle, which BREAKS Xcode's on-copy seal: the framework's main binary (and
# the enclosing host, whose seal covers this framework) then fail notarization
# with "The signature of the binary is invalid." Re-signing the bundle here with
# --force replaces Xcode's stale on-copy signature and reseals the (now-signed)
# nested dylibs in one shot, restoring a valid seal.
#
# Signing the .framework bundle path signs its main binary AND reseals the
# nested Libraries/*.dylib together — do NOT sign the main binary separately.
#
# Inside-out order: nested dylibs (above) → framework bundle (here) → helpers
# (above) → host (Xcode last, or the standalone branch below).
echo "[ChromiumKit]  → signing framework bundle (identity: $SIGN_ID)"
codesign --force --sign "$SIGN_ID" --options runtime "$TIMESTAMP_FLAG" \
  "$FRAMEWORK"

# Skip host signing when running under Xcode — Xcode signs the host app
# itself as the final build step, after this script. Doing it here too fails
# because Xcode has already injected __preview.dylib for SwiftUI Previews,
# which codesign can't process. Standalone shell builds set no XCODE_*
# vars and DO need us to sign the host.
if [[ -n "${XCODE_PRODUCT_BUILD_VERSION:-}" ]]; then
  echo "[ChromiumKit]  → skipping host sign (Xcode will sign on its own)"
else
  echo "[ChromiumKit]  → signing host"
  codesign --force --sign "$SIGN_ID" --timestamp=none "$APP"
fi

echo "[ChromiumKit]  done"
