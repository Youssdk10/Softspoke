#!/bin/zsh
# Creates a self-signed code-signing certificate in your login Keychain, so
# Softspoke keeps its permissions across rebuilds.
#
# It is not marked as trusted system-wide, and only identifies this app on this
# Mac. It can't be used to share the app with others. To remove it, delete
# "Softspoke Local Signing" in Keychain Access.
set -euo pipefail

NAME="Softspoke Local Signing"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "Certificate already exists: $NAME"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

cat > "$WORK/cert.conf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.conf" 2>/dev/null

# The transfer password only protects this temporary file, which is deleted on exit.
TRANSFER="$(/usr/bin/openssl rand -hex 24)"
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$NAME" -out "$WORK/identity.p12" -passout "pass:$TRANSFER"

security import "$WORK/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P "$TRANSFER" -T /usr/bin/codesign >/dev/null

echo "Created certificate: $NAME"
