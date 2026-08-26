#!/usr/bin/env bash
# network_trace — capture packets from a pod's network namespace
# usage: network_trace <pod> [-n ns] [-f filter] [-i iface] [-o file] [-t secs]
set -uo pipefail

die() { echo "error: $*" >&2; exit 1; }

POD="${1:-}"
[ -n "$POD" ] || die "usage: $0 <pod> [-n ns] [-f filter] [-i iface] [-o file] [-t secs]"
shift

NS="default"; FILTER=""; IFACE="any"; OUT=""; DUR=""
IMAGE="nicolaka/netshoot"

while getopts "n:f:i:o:t:" opt; do
  case $opt in
    n) NS="$OPTARG" ;;
    f) FILTER="$OPTARG" ;;
    i) IFACE="$OPTARG" ;;
    o) OUT="$OPTARG" ;;
    t) DUR="$OPTARG" ;;
    *) die "bad flag" ;;
  esac
done

# ---- resolve pod ----------------------------------------------------------
NODE=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.spec.nodeName}') \
  || die "pod $POD not found in namespace $NS"
[ -n "$NODE" ] || die "pod $POD has no node assigned"

CID=$(kubectl get pod "$POD" -n "$NS" \
      -o jsonpath='{.status.containerStatuses[0].containerID}' | sed 's|.*://||')
[ -n "$CID" ] || die "container not running"

echo ">> pod=$POD ns=$NS node=$NODE" >&2

TCPDUMP="tcpdump -i $IFACE -U -w -"
[ -n "$DUR" ] && TCPDUMP="timeout $DUR $TCPDUMP"

# ---- local fast path: we're already on the target node ---------------------
if [ "$NODE" = "$(hostname)" ] && command -v k3s >/dev/null 2>&1; then
  echo ">> local mode (nsenter on host)" >&2
  PID=$(sudo k3s crictl inspect --output go-template --template '{{.info.pid}}' "$CID") \
    || die "crictl inspect failed"
  [ -n "$PID" ] && [ "$PID" != "0" ] || die "could not resolve pid"
  echo ">> pid=$PID" >&2

  if [ -n "$OUT" ]; then
    sudo nsenter -t "$PID" -n $TCPDUMP $FILTER > "$OUT"
  elif command -v wireshark >/dev/null 2>&1; then
    sudo nsenter -t "$PID" -n $TCPDUMP $FILTER | wireshark -k -i -
  else
    die "no display for wireshark — pass -o <file> instead"
  fi
  exit 0
fi

# ---- remote mode: privileged pod on the target node ------------------------
echo ">> remote mode (privileged pod on $NODE)" >&2
SNIFFER="ksniff-$(printf '%06x' $((RANDOM * RANDOM % 16777216)))"
cleanup() {
  kubectl delete pod "$SNIFFER" -n "$NS" --grace-period=0 --force >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

kubectl run "$SNIFFER" -n "$NS" --restart=Never --image="$IMAGE" \
  --overrides="$(cat <<JSON
{"spec":{
  "nodeName":"$NODE",
  "hostPID":true,
  "containers":[{
    "name":"sniffer","image":"$IMAGE",
    "command":["sleep","3600"],
    "securityContext":{"privileged":true}
  }],
  "tolerations":[{"operator":"Exists"}]
}}
JSON
)" >/dev/null || die "failed to create sniffer pod"

kubectl wait --for=condition=Ready "pod/$SNIFFER" -n "$NS" --timeout=90s >/dev/null \
  || die "sniffer pod never became ready"

# hostPID=true means host PIDs are visible in /proc; match the container cgroup
PID=$(kubectl exec "$SNIFFER" -n "$NS" -- sh -c "
  for p in /proc/[0-9]*; do
    [ -r \$p/cgroup ] || continue
    if grep -qs '$CID' \$p/cgroup; then echo \${p#/proc/}; break; fi
  done")
[ -n "$PID" ] || die "could not resolve pid for container $CID"
echo ">> pid=$PID" >&2

CMD="nsenter -t $PID -n $TCPDUMP $FILTER"

if [ -n "$OUT" ]; then
  kubectl exec "$SNIFFER" -n "$NS" -- sh -c "$CMD" > "$OUT"
elif command -v wireshark >/dev/null 2>&1; then
  kubectl exec "$SNIFFER" -n "$NS" -- sh -c "$CMD" | wireshark -k -i -
else
  die "no display for wireshark — pass -o <file> instead"
fi