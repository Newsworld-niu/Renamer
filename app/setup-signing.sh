#!/bin/zsh
# One-time, local-only signing identity. Never put private keys in the project.
set -eu
signing_dir="$HOME/Library/Application Support/Renamer/Signing"
identity_file="$signing_dir/identity.sha1"
login_keychain="$HOME/Library/Keychains/login.keychain-db"
if [[ -s "$identity_file" ]]; then
  print 'Renamer already has a saved signing identity; it will not be replaced.'
  exit 0
fi
umask 077
mkdir -p "$signing_dir"
temp_dir=$(mktemp -d "${TMPDIR:-/private/tmp}/renamer-signing.XXXXXX")
trap 'rm -rf "$temp_dir"' EXIT
cat > "$temp_dir/certificate.cnf" <<'EOF'
[req]
distinguished_name = identity
x509_extensions = signing
prompt = no
[identity]
CN = Renamer Local Development
O = Renamer Personal
[signing]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
EOF
openssl req -new -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config "$temp_dir/certificate.cnf" -keyout "$temp_dir/private.key" -out "$temp_dir/certificate.pem" 2>/dev/null
openssl rand -hex 32 > "$temp_dir/import-password"
openssl pkcs12 -export -inkey "$temp_dir/private.key" -in "$temp_dir/certificate.pem" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
  -out "$temp_dir/identity.p12" -passout "file:$temp_dir/import-password"
security import "$temp_dir/identity.p12" -k "$login_keychain" \
  -P "$(cat "$temp_dir/import-password")" -T /usr/bin/codesign
# Persist only the public certificate and fingerprint; Keychain owns the key.
cp "$temp_dir/certificate.pem" "$signing_dir/certificate.pem"
openssl x509 -in "$signing_dir/certificate.pem" -noout -fingerprint -sha1 \
  | sed 's/.*=//; s/://g' > "$identity_file"
print 'Created Renamer signing identity in the login keychain.'
