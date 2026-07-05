#!/usr/bin/env bash
# Create a stable, self-signed code-signing identity for local HelloChromium
# builds/tests, and trust it for code signing.
#
# WHY: the example app is ad-hoc signed by default (CODE_SIGN_IDENTITY="-"), so
# every rebuild produces a *different* code identity. macOS keys both Keychain
# "Always Allow" ACLs (CEF's "Chromium Safe Storage") and TCC grants (XCTest
# automation/accessibility, developer tools) to the signing identity — so with
# ad-hoc signing every grant is discarded on the next build and you re-authorize
# forever. A stable identity makes those one-time grants stick.
#
# This does NOT change anything committed: the repo default stays ad-hoc. You
# opt in locally by setting CHROMIUMKIT_SIGN_IDENTITY (see .env.example), which
# scripts/cli.swift forwards to xcodebuild. See documents/code-signing.md.
#
# Usage:  scripts/make-signing-identity.sh ["Identity Name"]
# Default name: "ChromiumKit Local"

set -euo pipefail

NAME="${1:-ChromiumKit Local}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "✓ A code-signing identity named \"$NAME\" already exists. Nothing to do."
  echo "  Set CHROMIUMKIT_SIGN_IDENTITY=\"$NAME\" in .env (see .env.example)."
  exit 0
fi

echo "==> Generating a self-signed code-signing certificate \"$NAME\""
cat > "$WORK/req.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no
[ dn ]
CN = $NAME
[ v3 ]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/req.cnf" >/dev/null 2>&1

# -legacy + SHA1 PBE so macOS's `security` can read the PKCS#12 (OpenSSL 3's
# default MAC/PBE is rejected by SecKeychainItemImport).
openssl pkcs12 -export -legacy -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/identity.p12" -passout pass:chromiumkit -name "$NAME" \
  -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES >/dev/null 2>&1

# The login password is needed to unlock the keychain and to set the key's
# partition list (so `codesign` can use the key without a GUI prompt).
read -rs -p "macOS login (keychain) password: " PW; echo

echo "==> Importing identity into the login keychain"
security unlock-keychain -p "$PW" "$KEYCHAIN"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P chromiumkit \
  -A -T /usr/bin/codesign -T /usr/bin/security

echo "==> Allowing codesign to use the key (partition list)"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KEYCHAIN" >/dev/null

echo "==> Trusting the certificate for code signing"
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo
echo "✓ Created and trusted code-signing identity:"
security find-identity -v -p codesigning | grep "\"$NAME\"" || true
echo
echo "Next: add this to a .env file at the repo root (gitignored):"
echo "  CHROMIUMKIT_SIGN_IDENTITY=\"$NAME\""
echo "Then \`scripts/cli.swift ui|unit|xcode\` signs with it. Grant the CEF"
echo "Keychain + XCTest prompts ONCE on the next run; they will then persist."
