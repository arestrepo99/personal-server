#!/usr/bin/env bash
#tskey-auth-kvUMWTHmmC21CNTRL-6xjfqySFcNNRF3N9m8YYNNMHyT8MNJq6
# Seals the Tailscale auth key into tailscale-secret.sealed.yaml.
#
# The key is read from a silent prompt and piped straight into kubeseal, so
# the plaintext never lands in a file, in your shell history, or in the
# process list (which an --from-literal on the command line would expose).
# Only the encrypted output is written to disk, and only the in-cluster
# sealed-secrets-controller can decrypt it -- so the result is safe to commit.
#
# Usage:  ./seal-tailscale-secret.sh
#
# Get a *reusable* auth key from https://login.tailscale.com/admin/settings/keys
# first. Reusable matters: the sidecar's state is an emptyDir, so the node
# re-authenticates with this key every restart and a one-off key would work
# exactly once. Tick "Ephemeral" too, so the stale node from the previous
# restart is reaped from the tailnet instead of piling up.

set -euo pipefail

NAMESPACE="tailscale-l2tp-bridge"
SECRET_NAME="tailscale-l2tp-bridge-secret"
CONTROLLER_NAME="sealed-secrets-controller"
CONTROLLER_NS="sealed-secrets"
OUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tailscale-secret.sealed.yaml"

command -v kubeseal >/dev/null 2>&1 || {
  echo "error: kubeseal not found. See the install snippet in README.md." >&2
  exit 1
}

# Seal against the live controller's cert, so fail early with a clear message
# rather than emitting a file that nothing in the cluster can decrypt.
kubectl -n "$CONTROLLER_NS" get deploy "$CONTROLLER_NAME" >/dev/null 2>&1 || {
  echo "error: $CONTROLLER_NAME not found in namespace $CONTROLLER_NS." >&2
  echo "       Is the sealed-secrets Application (wave 0) Synced/Healthy?" >&2
  exit 1
}

printf 'Tailscale auth key (input hidden): '
read -rs AUTH_KEY
printf '\n'

[ -n "$AUTH_KEY" ] || { echo "error: empty auth key, nothing to seal." >&2; exit 1; }

if [ -e "$OUT" ]; then
  printf 'Overwrite existing %s? [y/N] ' "$(basename "$OUT")"
  read -r reply
  case "$reply" in
    [yY]*) ;;
    *) echo "aborted, existing file left untouched."; exit 1 ;;
  esac
fi

# Write via a temp file so a kubeseal failure can't leave a truncated or
# half-written sealed secret in place of a working one.
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

kubectl create secret generic "$SECRET_NAME" \
  --namespace "$NAMESPACE" \
  --from-literal=TS_AUTHKEY="$AUTH_KEY" \
  --dry-run=client -o yaml \
| kubeseal --format yaml \
    --controller-name "$CONTROLLER_NAME" \
    --controller-namespace "$CONTROLLER_NS" \
> "$TMP"

# Guard against committing something that isn't actually encrypted.
grep -q 'kind: SealedSecret' "$TMP" || {
  echo "error: kubeseal output is not a SealedSecret, refusing to write." >&2
  exit 1
}
grep -q 'encryptedData' "$TMP" || {
  echo "error: no encryptedData in output, refusing to write." >&2
  exit 1
}

mv "$TMP" "$OUT"
trap - EXIT

echo "wrote $OUT"
echo
echo "Next:"
echo "  git add $(basename "$OUT") && git commit -m 'Add sealed Tailscale auth key' && git push"
echo
echo "ArgoCD syncs it, the controller unseals it into the $SECRET_NAME Secret,"
echo "and the tailscale sidecar picks it up via envFrom. Then approve the"
echo "advertised subnet routes and the exit node in the admin console"
echo "(README: 'Approving the routes') -- the node authenticates itself, but"
echo "nothing is routed through it until you approve it there."
