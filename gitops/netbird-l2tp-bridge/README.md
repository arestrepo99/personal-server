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

## Stage 2: the NetBird sidecar

The `netbird` container runs in the *same pod*, so it shares the network
namespace and sees `ppp0` directly -- that shared netns is why it's a
sidecar and not its own pod.

Routing is installed by pppd's `ip-up` hook (written by `entrypoint.sh`),
so it's re-applied on every redial rather than once at startup:

- `REMOTE_SUBNETS` (in `env-configmap.yaml`) get plain routes out `ppp0`.
- Exit-node traffic is **policy-routed**: `ip rule add iif wt0 lookup 100`
  with `default dev ppp0` in table 100. The pod's own default route stays
  on `eth0` so it keeps cluster and NetBird control-plane access -- only
  traffic arriving from NetBird goes out the tunnel.
- `MASQUERADE` on `ppp0`, since the far side only knows our `ppp0` address.

### Sealing the setup key

Create a **reusable** setup key in the dashboard (`https://netbird.arec.me`)
-- reusable because the sidecar's state is an `emptyDir`, so the peer
re-registers with this key on every restart and a one-off key would work
exactly once.

Then run:

```bash
./seal-netbird-secret.sh
```

It prompts for the key with input hidden and pipes it straight into
`kubeseal`, so the plaintext never reaches a file, your shell history, or
the process list (which `--from-literal` on a command line would expose).
Only the encrypted `netbird-secret.sealed.yaml` is written, and only the
in-cluster controller can decrypt it -- so it's safe to commit. The script
refuses to write anything that isn't a real `SealedSecret`.

If the sidecar logs:

```
couldn't add peer: setup key is invalid
```

the key was **one-off and already consumed**. It registers the peer once,
then every later restart fails, because the sidecar's `emptyDir` state is
wiped and it re-registers from scratch. Create a reusable key and re-run
the script. (Seen in practice -- the peer came up once, then `wt0`
disappeared after the next restart.)

Commit `netbird-secret.sealed.yaml`. Until it exists the `netbird`
container crashloops while the L2TP tunnel keeps working -- the secretRef
is marked `optional` precisely so a missing key can't take the bridge down.

### Advertising the routes

The manifests build the routes; they do **not** advertise them. In the
dashboard, under Network Routes, add two routes with this peer as the
routing peer:

| Network range | Purpose |
| --- | --- |
| `192.168.1.0/24`, `192.168.20.0/24` | remote LANs behind the L2TP server |
| `0.0.0.0/0` | exit node -- peers' internet egress via the tunnel |

Keeping them separate lets you enable each per peer group independently.
Distribution groups are set in the dashboard, not in git.

## Verifying the tunnel after deploy

```bash
kubectl -n netbird-l2tp-bridge get pods
kubectl -n netbird-l2tp-bridge logs deploy/netbird-l2tp-bridge -f
```

Look for `ppp0 is up` in the logs, followed by an `inet` address. Then, from
inside the pod:

```bash
kubectl -n netbird-l2tp-bridge exec -it deploy/netbird-l2tp-bridge -- bash
ip addr show ppp0                    # should have an inet addr, e.g. 192.168.2.6
ping -c3 -I ppp0 <peer from ip addr> # peer address shown by "ip addr show ppp0"
```

An IPCP-assigned address on `ppp0` is also the proof that the L2TP
username/password worked -- auth happens before addressing, so a wrong
password never gets this far.

Note the pod's **default route stays on `eth0`, not `ppp0`**. `pppd` is
passed `defaultroute`, but that option won't override an already-present
default route, so it's a no-op here. That's deliberate: sending everything
through the tunnel would cut the pod off from the cluster and (later) from
the NetBird control plane. Stage 2 routes only NetBird-peer traffic out
`ppp0` via policy routing, rather than moving the default route.

So don't expect `curl ifconfig.me` to show the L2TP server's exit IP --
it will show this host's. Test the tunnel by pinging the peer over `ppp0`
explicitly, as above.

## Known rough edge

This pod runs `privileged: true`. `NET_ADMIN`/`NET_RAW` plus the host
`/dev/ppp` mount are necessary but *not* sufficient: the mount makes the
device node visible, while the device cgroup still denies `open()` on it, so
pppd fails with `Sorry - this system lacks PPP kernel support` (misleading --
the host kernel has `ppp_generic` builtin). Kubernetes has no per-device
allowlist in the pod spec, so `privileged` is the only way to grant it.

That's enough host privilege that containerization buys little isolation
here. It's inherent to running a PPP-based tunnel, not something to try to
harden away.
