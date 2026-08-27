#!/usr/bin/env bash
# Creates the Nebula CA (once), signs this lighthouse's certificate, and seals
# ca.crt + host.crt + host.key into certs.sealed.yaml.
#
# The CA *private key* is the root of trust for the whole mesh: anyone holding
# it can mint a certificate for any overlay IP and join. It is written to
# ./ca/ca.key, which .gitignore excludes, and it never enters the cluster --
# only the public ca.crt does. Back ./ca/ up somewhere safe (password
# manager, encrypted volume); losing it means re-issuing every node's cert.
#
# Only the sealed output is written into the repo, and only the in-cluster
# sealed-secrets-controller can decrypt it -- so that file is safe to commit.
#
# Usage:  ./seal-nebula-certs.sh
#
# Afterwards, use ./sign-client.sh <name> <overlay-ip> to mint node certs.

set -euo pipefail

NAMESPACE="nebula-lighthouse"
SECRET_NAME="nebula-lighthouse-certs"
CONTROLLER_NAME="sealed-secrets-controller"
CONTROLLER_NS="sealed-secrets"

# Must match configmap.yaml's overlay addressing and the CA name below.
CA_NAME="arec.me nebula"
LIGHTHOUSE_IP="10.10.0.1/24"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CA_DIR="$HERE/ca"
OUT="$HERE/certs.sealed.yaml"

command -v nebula-cert >/dev/null 2>&1 || {
  echo "error: nebula-cert not found. Install it with:" >&2
  echo "  curl -fsSL https://github.com/slackhq/nebula/releases/latest/download/nebula-linux-arm64.tar.gz \\" >&2
  echo "    | sudo tar -xz -C /usr/local/bin nebula-cert" >&2
  echo "  (use nebula-linux-amd64.tar.gz on an x86 workstation)" >&2
  exit 1
}
command -v kubeseal >/dev/null 2>&1 || {
  echo "error: kubeseal not found. See the install snippet in README.md." >&2
  exit 1
}

# Seal against the live controller's cert, so this fails early with a clear
# message rather than emitting a file nothing in the cluster can decrypt.
kubectl -n "$CONTROLLER_NS" get deploy "$CONTROLLER_NAME" >/dev/null 2>&1 || {
  echo "error: $CONTROLLER_NAME not found in namespace $CONTROLLER_NS." >&2
  echo "       Is the sealed-secrets Application (wave 0) Synced/Healthy?" >&2
  exit 1
}

mkdir -p "$CA_DIR"
chmod 700 "$CA_DIR"

if [ -f "$CA_DIR/ca.key" ]; then
  echo "using existing CA at $CA_DIR/ca.crt"
else
  echo "no CA found, creating one (valid ~1 year by default -- see -duration)"
  # Generated in place; nebula-cert refuses to overwrite, which is the
  # safety net against silently replacing a CA that clients already trust.
  nebula-cert ca -name "$CA_NAME" -out-crt "$CA_DIR/ca.crt" -out-key "$CA_DIR/ca.key"
  chmod 600 "$CA_DIR/ca.key"
  echo "created $CA_DIR/ca.key -- BACK THIS UP, it is not in git and not in the cluster."
fi

# Sign fresh host material every run. Cheap, and it means re-running this
# after a CA rotation just works.
TMPDIR_CERT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_CERT"' EXIT

nebula-cert sign \
  -ca-crt "$CA_DIR/ca.crt" \
  -ca-key "$CA_DIR/ca.key" \
  -name "lighthouse" \
  -ip "$LIGHTHOUSE_IP" \
  -groups "lighthouse" \
  -out-crt "$TMPDIR_CERT/host.crt" \
  -out-key "$TMPDIR_CERT/host.key"

if [ -e "$OUT" ]; then
  printf 'Overwrite existing %s? [y/N] ' "$(basename "$OUT")"
  read -r reply
  case "$reply" in
    [yY]*) ;;
    *) echo "aborted, existing file left untouched."; exit 1 ;;
  esac
fi

SEALED="$TMPDIR_CERT/sealed.yaml"

kubectl create secret generic "$SECRET_NAME" \
  --namespace "$NAMESPACE" \
  --from-file=ca.crt="$CA_DIR/ca.crt" \
  --from-file=host.crt="$TMPDIR_CERT/host.crt" \
  --from-file=host.key="$TMPDIR_CERT/host.key" \
  --dry-run=client -o yaml \
| kubeseal --format yaml \
    --controller-name "$CONTROLLER_NAME" \
    --controller-namespace "$CONTROLLER_NS" \
> "$SEALED"

# Guard against committing something that isn't actually encrypted.
grep -q 'kind: SealedSecret' "$SEALED" || {
  echo "error: kubeseal output is not a SealedSecret, refusing to write." >&2
  exit 1
}
grep -q 'encryptedData' "$SEALED" || {
  echo "error: no encryptedData in output, refusing to write." >&2
  exit 1
}
# The host key must never appear in the committed file in the clear.
grep -q 'NEBULA' "$SEALED" && {
  echo "error: PEM material found in kubeseal output, refusing to write." >&2
  exit 1
}

mv "$SEALED" "$OUT"

echo "wrote $OUT"
echo
echo "Next:"
echo "  git add $(basename "$OUT") && git commit -m 'Add sealed Nebula lighthouse certs' && git push"
echo
echo "ArgoCD syncs it, the controller unseals it into the $SECRET_NAME Secret,"
echo "and the lighthouse pod mounts it at /nebula-certs. Then open UDP 4242 in"
echo "the OCI security list and on the node (README: 'Opening the port')."
