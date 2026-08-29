#!/usr/bin/env bash
#
# Build a CA bundle that Python will accept behind a TLS-intercepting proxy:
# certifi's roots plus the corporate roots from the macOS System keychain.
# Idempotent. See README, "Corporate proxy (TLS interception)".
#
set -euo pipefail
cd "$(dirname "$0")"

OUT="certs/walmart-ca-bundle.pem"
VENV="s2s_venv"

[ -x "./$VENV/bin/python" ] || {
    echo "error: $VENV missing. Run ./setup-local-backend.sh first." >&2; exit 1; }

CERTIFI="$(./$VENV/bin/python -c 'import certifi; print(certifi.where())')"

mkdir -p certs
{
    cat "$CERTIFI"
    echo
    security find-certificate -a -p -c "Walmart" /Library/Keychains/System.keychain
    security find-certificate -a -p -c "SSL_Decryption" /Library/Keychains/System.keychain
} > "$OUT" 2>/dev/null

echo "==> $OUT ($(grep -c 'BEGIN CERT' "$OUT") certificates)"
