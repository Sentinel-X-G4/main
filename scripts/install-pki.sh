#!/usr/bin/env bash
# Installe la PKI de Baptiste (dossier secrets/, jamais commité) dans l'infra :
#   secrets/ca.crt, ca.key, mosquitto.key, proxy.key, dhparam.pem
# Signe avec ca.key les certificats serveur aux noms utilisés par la pile :
#   mosquitto.crt : mqtt.sentinel.lan, localhost, 192.168.40.1, 127.0.0.1
#   proxy.crt     : dashboard.sentinel.lan, sentinel.local, localhost, 192.168.40.1, 127.0.0.1
# Les fichiers de secrets/ ne sont jamais modifiés. Relancer `make up` (ou recréer
# sentinel-mosquitto et sentinel-reverse-proxy) ensuite.
set -e
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."

if ! command -v openssl >/dev/null 2>&1; then
  echo "OpenSSL non trouvé sur l'hôte, exécution via conteneur Docker..."
  docker run --rm -v "${PWD}:/work" -w /work alpine sh -c "apk add --no-cache openssl bash coreutils >/dev/null && bash scripts/install-pki.sh"
  exit $?
fi

S=secrets
M=services/infrastructure/mosquitto/certs
N=services/infrastructure/nginx/certs

for f in ca.crt ca.key mosquitto.key proxy.key dhparam.pem; do
  [ -f "$S/$f" ] || { echo "Manquant : $S/$f" >&2; exit 1; }
done

# Le certificat serveur ne doit pas survivre à la CA
ca_end=$(date -j -f "%b %d %T %Y %Z" "$(openssl x509 -in $S/ca.crt -noout -enddate | cut -d= -f2)" +%s 2>/dev/null \
  || date -d "$(openssl x509 -in $S/ca.crt -noout -enddate | cut -d= -f2)" +%s)
days=$(( (ca_end - $(date +%s)) / 86400 - 1 ))
[ "$days" -gt 0 ] || { echo "CA expirée" >&2; exit 1; }

W=.tmp_certs
rm -rf "$W"
mkdir -p "$W"
trap 'rm -rf "$W"' EXIT
sign() { # clé CN SAN sortie
  openssl req -new -key "$1" -subj "/C=FR/ST=Campus/L=EPSI/O=AetherCorp/OU=Cyber/CN=$2" -out "$W/req.csr"
  printf "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=%s\n" "$3" > "$W/ext.cnf"
  openssl x509 -req -in "$W/req.csr" -CA $S/ca.crt -CAkey $S/ca.key -set_serial "0x$(openssl rand -hex 16)" \
    -days "$days" -sha256 -extfile "$W/ext.cnf" -out "$4" 2>/dev/null
}

BIND_IP=""
if [ -f .env ]; then
  BIND_IP=$(grep -E '^BIND_IP=' .env | cut -d= -f2 | tr -d ' \r\n' || true)
fi
EXTRA_IP=""
if [ -n "$BIND_IP" ] && [ "$BIND_IP" != "127.0.0.1" ] && [ "$BIND_IP" != "192.168.40.1" ]; then
  EXTRA_IP=",IP:$BIND_IP"
fi

sign $S/mosquitto.key mqtt.sentinel.lan "DNS:mqtt.sentinel.lan,DNS:localhost,IP:192.168.40.1,IP:127.0.0.1${EXTRA_IP}" "$W/mosquitto.crt"
sign $S/proxy.key dashboard.sentinel.lan "DNS:dashboard.sentinel.lan,DNS:sentinel.local,DNS:localhost,IP:192.168.40.1,IP:127.0.0.1${EXTRA_IP}" "$W/proxy.crt"
openssl verify -CAfile $S/ca.crt "$W/mosquitto.crt" "$W/proxy.crt" >/dev/null

rm -f $M/ca.key $M/ca.srl          # restes éventuels de la CA de DEV (make certs)
cp $S/ca.crt "$W/mosquitto.crt" $S/mosquitto.key $M/
cp "$W/proxy.crt" $S/proxy.key $S/dhparam.pem $N/
chmod 600 $N/proxy.key 2>/dev/null || true
chmod 644 $M/mosquitto.key $M/ca.crt $M/mosquitto.crt 2>/dev/null || true
echo "OK : PKI installée (certificats serveur valables $days jours)"
