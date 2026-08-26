# tailscale-l2tp-bridge

The Tailscale twin of `gitops/netbird-l2tp-bridge`. Same pod shape: an
L2TP/IPsec client container dials the remote LNS, and a sidecar in the *same
network namespace* joins the overlay and forwards traffic into `ppp0`. Only
the sidecar differs -- `tailscale/tailscale` instead of `netbirdio/netbird`.

Everything about the L2TP side (privileged pod, `/dev/ppp`, the strongswan
+ xl2tpd + pppd config, the `ip-up` hook, the SIGTERM teardown) is unchanged
and documented in `../netbird-l2tp-bridge/README.md` -- the hard-won notes
there (why `privileged`, why the default route stays on `eth0`, why xl2tpd's
config can't contain comments, why the session must be closed on SIGTERM)
apply here verbatim. This README covers only what's different.

## Before you deploy: the shared L2TP account

This bridge reuses the `server` account on `providencia.arec.me` -- the same
one `netbird-l2tp-bridge` uses. The L2TP server rejects a second concurrent
login for the same username, so the two can never run at once: whichever
pod dials second never gets a session, and restarting either can steal the
tunnel from the other.

`gitops/apps/netbird-l2tp-bridge.yaml` is commented out, which stops ArgoCD
from managing it -- but **that does not stop the workload**. The Application
carries no `resources-finalizer.argocd.argoproj.io`, so when `root-app`
prunes it the delete is non-cascading and the Deployment keeps running,
orphaned, still holding the L2TP session. Confirm it is actually gone:

```bash
kubectl get deploy -n netbird-l2tp-bridge   # expect: no resources found
```

If it is still there, either delete the namespace (after the Application has
been pruned, or ArgoCD just recreates it) or restore the Application and set
`replicas: 0` in its Deployment -- the reversible option.

## Secrets

Two sealed Secrets, both namespace-scoped -- SealedSecrets are encrypted
*for a specific namespace and name*, so the ones in
`../netbird-l2tp-bridge/` cannot be copied here. They must be resealed.

### 1. L2TP password + IPsec PSK

Already sealed in `secret.sealed.yaml`. Server hostname and username aren't
sensitive and live in plaintext in `env-configmap.yaml`; only these two are
encrypted.

They were copied from the netbird bridge's live Secret rather than retyped --
same credentials, and a SealedSecret is bound to one namespace+name so the
existing file could not just be reused. To regenerate (e.g. after a password
change), this re-encrypts for the new namespace without the plaintext ever
reaching the terminal, a file, or your shell history:

```bash
kubectl -n netbird-l2tp-bridge get secret netbird-l2tp-bridge-secret -o json \
| python3 -c "
import json,sys
d=json.load(sys.stdin)
print(json.dumps({'apiVersion':'v1','kind':'Secret','type':'Opaque',
  'metadata':{'name':'tailscale-l2tp-bridge-secret','namespace':'tailscale-l2tp-bridge'},
  'data':d['data']}))" \
| kubeseal --format yaml \
    --controller-name sealed-secrets-controller \
    --controller-namespace sealed-secrets \
> secret.sealed.yaml
```

If the netbird namespace is gone, seal from scratch instead:

```bash
kubectl create secret generic tailscale-l2tp-bridge-secret \
  --namespace tailscale-l2tp-bridge \
  --from-literal=L2TP_PASSWORD='<l2tp password>' \
  --from-literal=IPSEC_PSK='<ipsec pre-shared key>' \
  --dry-run=client -o yaml \
| kubeseal --format yaml \
    --controller-name sealed-secrets-controller \
    --controller-namespace sealed-secrets \
> secret.sealed.yaml
```

(`kubeseal` install snippet is in `../netbird-l2tp-bridge/README.md`.)

### 2. Tailscale auth key

Create the key at <https://login.tailscale.com/admin/settings/keys>, then:

```bash
./seal-tailscale-secret.sh
```

It prompts with input hidden and pipes straight into `kubeseal`, so the key
never reaches a file, your shell history, or the process list. Only the
encrypted `tailscale-secret.sealed.yaml` is written, and the script refuses
to write anything that isn't a real `SealedSecret`.

Make the key **reusable** and **ephemeral**:

- *Reusable*, because the sidecar's state is an `emptyDir`. The node
  re-authenticates from scratch on every restart, so a one-off key works
  exactly once -- the same trap that bit the NetBird bridge ("setup key is
  invalid" after the first restart).
- *Ephemeral*, because each restart is a new node identity. Without it the
  tailnet accumulates `tailscale-l2tp-bridge-1`, `-2`, `-3`... and the
  approved routes stay attached to the dead ones. Ephemeral nodes are reaped
  shortly after they go offline.

Until the key is sealed the `tailscale` container crashloops while the L2TP
tunnel keeps working -- its `secretRef` is marked `optional` precisely so a
missing key can't take the bridge down.

## Approving the routes

Unlike NetBird, the routes are declared *in git* here, on the `tailscale`
container: `TS_ROUTES` for the remote LANs and `--advertise-exit-node` in
`TS_EXTRA_ARGS`. But advertising is not enabling -- in the admin console,
under Machines → this node → Routes, approve:

| Advertised | Purpose |
| --- | --- |
| `192.168.1.0/24`, `192.168.20.0/24` | remote LANs behind the L2TP server |
| exit node | peers' internet egress via the tunnel |

Keep `TS_ROUTES` in sync with `REMOTE_SUBNETS` in `env-configmap.yaml`:
`TS_ROUTES` advertises them to the tailnet, `REMOTE_SUBNETS` is what the
`ip-up` hook actually routes out `ppp0`. Note the different separators --
`TS_ROUTES` is comma-separated (that's `tailscale up` syntax), while
`REMOTE_SUBNETS` is space-separated because the hook iterates it as words.

Clients then use the exit node with `tailscale up --exit-node=<this node>`;
subnet routes need `--accept-routes` on clients that don't take them by
default.

## How the routing works

Identical to the NetBird bridge, and for the same reasons:

- `REMOTE_SUBNETS` get plain routes out `ppp0`.
- Exit-node traffic is policy-routed: `ip rule add from 100.64.0.0/10 lookup
  100`, with `default dev ppp0` in table 100. The pod's own default route
  stays on `eth0` so it keeps cluster and Tailscale control-plane access.
  Matching on **source prefix** rather than `iif tailscale0` is deliberate:
  an `iif` rule resolves the ifindex when added, and the hook can run before
  tailscaled has created its interface, leaving a `[detached]` rule that
  silently leaks peer traffic out `eth0`. Tailscale hands out CGNAT
  addresses, so the source prefix is stable and needs no interface.
- `MASQUERADE` on `ppp0`, since the far side only knows our `ppp0` address.

All of it lives in pppd's `ip-up` hook, so it is re-applied on every redial
rather than once at startup.

tailscaled installs its own `ip rule`s at priorities 5210-5270 (table 52),
which sort *ahead* of ours (~32765). That's harmless: table 52 holds only
tailnet destinations, so internet- and LAN-bound traffic falls through to
our rule.

Two Tailscale-specific env settings worth knowing:

- `TS_USERSPACE: "false"` -- a userspace tailscaled can only proxy its own
  connections; it cannot subnet-route or act as an exit node, which is the
  entire point of this pod.
- `TS_ACCEPT_DNS: "false"` -- MagicDNS would rewrite `/etc/resolv.conf` in a
  netns *shared with the L2TP container*, replacing cluster DNS for both.

## Verifying

```bash
kubectl -n tailscale-l2tp-bridge get pods
kubectl -n tailscale-l2tp-bridge logs deploy/tailscale-l2tp-bridge -c l2tp-client -f
kubectl -n tailscale-l2tp-bridge logs deploy/tailscale-l2tp-bridge -c tailscale -f
```

Look for `ppp0 is up` followed by an `inet` address -- an IPCP-assigned
address is also the proof that the L2TP username/password worked, since auth
happens before addressing. Then, from inside the pod:

```bash
kubectl -n tailscale-l2tp-bridge exec -it deploy/tailscale-l2tp-bridge -c l2tp-client -- bash
ip addr show ppp0                    # should have an inet addr
ping -c3 -I ppp0 <peer from ip addr>
ip rule show                         # "from 100.64.0.0/10 lookup 100"
ip route show table 100              # "default dev ppp0"
```

```bash
kubectl -n tailscale-l2tp-bridge exec -it deploy/tailscale-l2tp-bridge -c tailscale -- tailscale status
```

Don't expect `curl ifconfig.me` *from inside the pod* to show the L2TP exit
IP -- the pod's own default route is on `eth0` by design. Test from a tailnet
client using this node as its exit node instead.
