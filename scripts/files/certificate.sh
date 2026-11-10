#!/usr/bin/env bash
set -euo pipefail
certificate_config=$1
shift
if (( $# != 0 )); then
  echo 'Usage: sudo site-files-certificate' >&2
  exit 2
fi
if (( EUID != 0 )); then
  echo 'Run site-files-certificate with sudo.' >&2
  exit 1
fi
umask 077
state=/var/lib/site-files
install -d -m 0755 "$state"
install -d -m 0700 "$state/private"
exec 9>"$state/private/certificate.lock"
flock -n 9 || { echo 'Certificate issuance is already running.' >&2; exit 1; }
work=$(mktemp -d "$state/private/issue.XXXXXX")
trap 'rm -rf -- "$work"' EXIT

openssl_config=$work/openssl.cnf
python3 - "$certificate_config" > "$openssl_config" <<'PY'
import ipaddress
import re
import sys
from pathlib import Path

import yaml

try:
    names = yaml.safe_load(Path(sys.argv[1]).read_text())["files"]["certificateNames"]
except (OSError, yaml.YAMLError, KeyError, TypeError):
    raise SystemExit("Cannot read files.certificateNames from the certificate configuration.") from None
if not isinstance(names, list) or not names or not all(isinstance(name, str) for name in names):
    raise SystemExit("files.certificateNames must be a nonempty array of strings.")

print("""[req]
prompt = no
distinguished_name = subject
[subject]
CN = Private file sharing
[server]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = serverAuth
subjectAltName = @names
[names]""")
for index, name in enumerate(names, 1):
    try:
        address = ipaddress.ip_address(name)
    except ValueError:
        try:
            name = name.encode("idna").decode("ascii")
        except UnicodeError:
            raise SystemExit(f"Invalid domain name at files.certificateNames item {index}.") from None
        if not re.fullmatch(r"(?:\*\.)?[a-zA-Z0-9.-]+", name):
            raise SystemExit(f"Invalid domain name at files.certificateNames item {index}.")
        kind = "DNS"
    else:
        if getattr(address, "scope_id", None) is not None:
            raise SystemExit(f"Use an IP without a scope ID at files.certificateNames item {index}.")
        name, kind = str(address), "IP"
    print(f"{kind}.{index} = {name}")
PY

if [[ ! -e $state/private/ca.key && ! -e $state/ca.crt ]]; then
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -noenc \
    -keyout "$work/ca.key" -out "$work/ca.crt" -days 7300 \
    -subj '/CN=Private file sharing CA' \
    -addext 'basicConstraints=critical,CA:TRUE' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign'
  install -m 0600 "$work/ca.key" "$state/private/ca.key"
  install -m 0644 "$work/ca.crt" "$state/ca.crt"
elif [[ ! -f $state/private/ca.key || ! -f $state/ca.crt ]]; then
  echo 'Restore the matching ca.crt and private/ca.key before issuing a certificate.' >&2
  exit 1
fi

openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -noenc \
  -keyout "$work/server.key" -out "$work/server.csr" -config "$openssl_config"
openssl x509 -req -in "$work/server.csr" -CA "$state/ca.crt" \
  -CAkey "$state/private/ca.key" -set_serial "0x$(openssl rand -hex 16)" \
  -out "$work/server.crt" -days 825 -extfile "$openssl_config" -extensions server
openssl verify -CAfile "$state/ca.crt" "$work/server.crt"
install -m 0600 "$work/server.key" "$state/private/server.key.new"
install -m 0600 "$work/server.crt" "$state/server.crt.new"
mv -f "$state/private/server.key.new" "$state/private/server.key"
mv -f "$state/server.crt.new" "$state/server.crt"
# systemd loads a matching certificate/key pair when the service starts.
systemctl restart site-files-web.service
printf 'Client CA certificate: %s/ca.crt\n' "$state"
openssl x509 -in "$state/server.crt" -noout -dates
