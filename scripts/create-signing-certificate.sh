#!/bin/bash
# Creates the self-signed code signing certificate for DuoBar+ releases.
# Run once, on the Mac that builds releases. macOS asks for your password.
# Every release must use this same certificate, so keep the backup safe.
set -euo pipefail

NAME="DuoBar+ Developer"
BACKUP_DIR="$HOME/DuoBarPlus-signing-backup"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
OPENSSL=/usr/bin/openssl # LibreSSL writes a .p12 that macOS can import

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "A certificate named \"$NAME\" already exists. Nothing was changed." >&2
  exit 1
fi

read -r -s -p "Choose a password for the backup file: " PASSWORD; echo
read -r -s -p "Repeat the password: " REPEAT; echo
[[ -n "$PASSWORD" && "$PASSWORD" == "$REPEAT" ]] || { echo "The passwords did not match." >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "${WORK:?}"' EXIT
chmod 700 "$WORK"

cat > "$WORK/cert.cnf" <<CONFIG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONFIG

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 \
  -config "$WORK/cert.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

export P12_PASSWORD="$PASSWORD"
"$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
  -out "$WORK/identity.p12" -passout env:P12_PASSWORD

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
install -m 600 "$WORK/identity.p12" "$BACKUP_DIR/DuoBarPlus-signing.p12"

security import "$WORK/identity.p12" -k "$KEYCHAIN" -f pkcs12 -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
echo "macOS now asks you to approve the certificate for code signing."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo
security find-identity -v -p codesigning | grep "$NAME"
echo
echo "Done. Backup: $BACKUP_DIR/DuoBarPlus-signing.p12"
echo "Keep the backup and its password safe, for example in a password manager."
echo "Never add the file to Git."
