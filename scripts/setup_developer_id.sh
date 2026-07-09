#!/usr/bin/env bash
# Assembles a Developer ID Application signing identity from an issued .cer
# plus the private key generated for its CSR, imports it into the keychain,
# and prints the identity name for build_app.sh / release.sh.
#
# Run AFTER downloading the certificate from the Apple Developer portal
# (Certificates → + → Developer ID Application → upload the CSR).
#
#   scripts/setup_developer_id.sh <path-to.cer> [private_key.pem]
#
# The private key defaults to the one paired with the CSR (kept in the
# session scratchpad / restored from vault). The resulting .p12 is printed so
# it can be stored back in the vault.
set -euo pipefail

CER="${1:?usage: setup_developer_id.sh <cert.cer> [key.pem]}"
KEY="${2:-}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Normalize the cert to PEM (portal delivers DER).
if openssl x509 -inform der -in "$CER" -noout 2>/dev/null; then
  openssl x509 -inform der -in "$CER" -out "$WORK/cert.pem"
else
  cp "$CER" "$WORK/cert.pem"
fi

SUBJECT=$(openssl x509 -in "$WORK/cert.pem" -noout -subject)
echo "Certificate subject: $SUBJECT"
case "$SUBJECT" in
  *"Developer ID Application"*) ;;
  *) echo "WARNING: this is not a 'Developer ID Application' certificate — it cannot be used for notarized direct distribution." >&2 ;;
esac

if [[ -z "$KEY" ]]; then
  echo "error: private key not given. Pass the PEM key paired with the CSR." >&2
  echo "       (restore from vault item 'Developer ID Application - barshelf', field private_key_pem_b64)" >&2
  exit 1
fi

# Confirm the key matches the certificate.
CERT_MOD=$(openssl x509 -in "$WORK/cert.pem" -noout -modulus | openssl md5)
KEY_MOD=$(openssl rsa -in "$KEY" -noout -modulus | openssl md5)
if [[ "$CERT_MOD" != "$KEY_MOD" ]]; then
  echo "error: private key does not match the certificate." >&2
  exit 1
fi
echo "Key/cert match: OK"

P12_PASS="${P12_PASS:-$(openssl rand -hex 16)}"
P12_OUT="${P12_OUT:-$HOME/DeveloperID-Application.p12}"
openssl pkcs12 -export \
  -inkey "$KEY" -in "$WORK/cert.pem" \
  -name "Developer ID Application" \
  -passout "pass:$P12_PASS" \
  -out "$P12_OUT"
echo "Wrote $P12_OUT"

# Import into the login keychain so codesign can find it.
security import "$P12_OUT" -P "$P12_PASS" -T /usr/bin/codesign 2>/dev/null || true

echo
echo "Installed signing identities:"
security find-identity -v -p codesigning | grep "Developer ID Application" || {
  echo "  (none found — unlock the login keychain and re-import if needed)"; exit 1;
}

# Store the issued cert + p12 back in the vault (team-wide reuse).
if command -v bw >/dev/null 2>&1 && [[ -n "${BW_SESSION:-}" ]]; then
  ITEM="Developer ID Application (Jiun Bae)"
  ID=$(bw get item "$ITEM" 2>/dev/null | jq -r '.id // empty')
  if [[ -n "$ID" ]]; then
    CERT_B64=$(base64 -i "$WORK/cert.pem")
    P12_B64=$(base64 -i "$P12_OUT")
    bw get item "$ID" | jq \
      --arg cert "$CERT_B64" --arg p12 "$P12_B64" --arg pass "$P12_PASS" '
      .fields += [
        {name:"cert_pem_b64", value:$cert, type:1},
        {name:"p12_b64", value:$p12, type:1},
        {name:"p12_password", value:$pass, type:1}
      ]' | bw encode | bw edit item "$ID" >/dev/null && echo "Stored cert + p12 in vault item: $ITEM"
    bw sync >/dev/null 2>&1 || true
  fi
else
  echo "Vault not unlocked — store $P12_OUT manually (item 'Developer ID Application (Jiun Bae)')."
fi

echo
echo "Next: sign + notarize a release:"
echo "  SIGN_IDENTITY=\"Developer ID Application: Jiun Bae (728FW73BS8)\" \\"
echo "  NOTARIZE=1 ASC_KEY_ID=<key> ASC_ISSUER_ID=<issuer> bash scripts/release.sh"
