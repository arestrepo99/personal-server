# netbird-l2tp-bridge secrets: how to seal the L2TP/IPsec credentials

Stage 1 (current): this pod is an L2TP/IPsec client only, PSK + username/
password auth. NetBird peer wiring comes later; the namespace/app name is
already the bridge's final name so nothing needs renaming when that lands.

Only the password and PSK are actually sensitive -- server hostname and
username are not secrets, so they live in plaintext in `env-configmap.yaml`
(edit that file directly with your real values and commit it normally, no
sealing needed).

Nothing in the Secret below should ever be sent to me in plaintext -- fill
in the real values yourself and only commit/send back the sealed output.

## One-time setup, after the `sealed-secrets` Application (wave 0) is Synced/Healthy

1. `kubeseal` CLI should already be installed from the netbird setup
   (`gitops/netbird/README.md`). If not:
   ```bash
   KUBESEAL_VERSION=0.38.4
   curl -fsSL -o kubeseal.tar.gz \
     "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-arm64.tar.gz"
   tar -xzf kubeseal.tar.gz kubeseal
   sudo install -m 755 kubeseal /usr/local/bin/kubeseal
   ```

2. Edit `env-configmap.yaml` directly with the real `L2TP_SERVER` and
   `L2TP_USER` values (plaintext, commit as-is -- not secret).

3. Generate and seal the Secret (password + PSK only) in one pipe -- the
   plaintext form never touches disk, it only exists in the pipe between
   the two commands:
   ```bash
   kubectl create secret generic netbird-l2tp-bridge-secret \
     --namespace netbird-l2tp-bridge \
     --from-literal=L2TP_PASSWORD='<l2tp password>' \
     --from-literal=IPSEC_PSK='<ipsec pre-shared key>' \
     --dry-run=client -o yaml \
   | kubeseal --format yaml \
       --controller-name sealed-secrets-controller \
       --controller-namespace sealed-secrets \
   > secret.sealed.yaml
   ```

4. Commit `secret.sealed.yaml` and `env-configmap.yaml` in this directory
   (`gitops/netbird-l2tp-bridge/`) and push -- or hand me `secret.sealed.yaml`'s
   contents, since it's encrypted and safe to share (only the in-cluster
   `sealed-secrets-controller` can decrypt it). ArgoCD picks it up, the
   controller unseals it into a real `netbird-l2tp-bridge-secret` Secret in
   the `netbird-l2tp-bridge` namespace, and the Deployment consumes both via
   `envFrom`.

## Verifying the tunnel after deploy

```bash
kubectl -n netbird-l2tp-bridge get pods
kubectl -n netbird-l2tp-bridge logs deploy/netbird-l2tp-bridge -f
```

Look for `ppp0 is up` in the logs. Then, from inside the pod:

```bash
kubectl -n netbird-l2tp-bridge exec -it deploy/netbird-l2tp-bridge -- bash
ip addr show ppp0
ip route            # default route should now be via ppp0
curl -s ifconfig.me # should show the L2TP server's exit IP, not this host's
```

## Known rough edge

This pod needs `NET_ADMIN`/`NET_RAW` and a host `/dev/ppp` device mount --
enough host-networking privilege that containerization buys little isolation
here. That's inherent to running a PPP-based tunnel, not something to try to
harden away.
