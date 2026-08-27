# nebula-lighthouse

A [Nebula](https://github.com/slackhq/nebula) lighthouse running on this
cluster. A lighthouse is the mesh's rendezvous point: it keeps the map of
"overlay IP -> current real IP:port" and hands it out so two peers can
hole-punch a direct, encrypted tunnel to each other. Nothing routes *through*
it in the normal case -- except when hole-punching fails, because this one is
also a relay (`relay.am_relay: true`).

Unlike NetBird and Tailscale (also in this repo), Nebula has no control plane
to sign up for: trust is a certificate authority you hold yourself, and the
lighthouse is just another node with `am_lighthouse: true`. That means there
is no account, no admin console, and no route-approval step -- but it also
means **the CA private key is yours to protect**. See "The CA" below.

## Layout

| File | What it is |
| --- | --- |
| `namespace.yaml` | the `nebula-lighthouse` namespace |
| `configmap.yaml` | `config.yml` for the lighthouse, mounted at `/etc/nebula` |
| `deployment.yaml` | the pod: `nebulaoss/nebula`, `hostNetwork`, UDP 4242 |
| `certs.sealed.yaml` | sealed `ca.crt` + `host.crt` + `host.key` (created by the script below) |
| `seal-nebula-certs.sh` | creates the CA once, signs the lighthouse cert, seals it |
| `sign-client.sh` | mints a cert + ready-to-run `config.yml` for one client node |

Addressing, fixed across all of the above:

- overlay network: `10.10.0.0/24` (clear of `192.168.1.0/24` and
  `192.168.20.0/24`, which the L2TP bridges advertise, and of the k3s
  pod/service ranges)
- lighthouse: `10.10.0.1`, publicly at `157.151.171.157:4242`
- clients: `10.10.0.2` upward

Nebula enforces the overlay IP that is baked into each certificate, so
changing the CIDR later means re-signing **every** node. Pick it once.

## Deploying

1. **Seal the certificates.** Nothing starts without them -- the pod mounts
   the Secret non-optionally, so it stays `ContainerCreating` until this
   exists.

   ```bash
   ./seal-nebula-certs.sh
   git add certs.sealed.yaml && git commit -m 'Add sealed Nebula lighthouse certs' && git push
   ```

   The script needs `nebula-cert` and `kubeseal`:

   ```bash
   curl -fsSL https://github.com/slackhq/nebula/releases/latest/download/nebula-linux-arm64.tar.gz \
     | sudo tar -xz -C /usr/local/bin nebula-cert
   KUBESEAL_VERSION=0.27.1
   curl -fsSL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-arm64.tar.gz" \
     | tar -xz -O kubeseal | sudo tee /usr/local/bin/kubeseal >/dev/null && sudo chmod +x /usr/local/bin/kubeseal
   ```

2. **Open UDP 4242.** Two separate firewalls, and the pod will look perfectly
   healthy while both block it:

   ```bash
   # a) the node itself -- Oracle's Ubuntu image ships a default-DROP INPUT chain
   sudo iptables -I INPUT 6 -p udp --dport 4242 -j ACCEPT
   sudo netfilter-persistent save     # or the rule is gone after a reboot

   # b) the OCI security list / NSG for this instance's subnet:
   #    Ingress, stateless=No, source 0.0.0.0/0, IP protocol UDP, dest port 4242
   #    (console: Networking > VCN > Security Lists, or `oci network security-list update`)
   ```

3. **Let ArgoCD sync it.** `gitops/apps/nebula-lighthouse.yaml` is picked up
   by `root-app` automatically -- no Terraform change needed.

   ```bash
   kubectl -n nebula-lighthouse get pod -w
   kubectl -n nebula-lighthouse logs deploy/nebula-lighthouse
   # expect: "Nebula interface is active" with the 10.10.0.1 address
   ```

## Adding a client

```bash
./sign-client.sh laptop 10.10.0.10
```

That writes `clients/laptop/` with `ca.crt`, `host.crt`, `host.key`, and a
`config.yml` already pointing at this lighthouse and using it as a relay.
Copy the directory to `/etc/nebula/` on the node, run
`nebula -config /etc/nebula/config.yml`, then `ping 10.10.0.1` -- the
lighthouse's firewall allows inbound ICMP specifically so this test works.

`clients/` is gitignored: it holds that node's private key in the clear.
Delete each directory once it has been delivered.

## The CA

`seal-nebula-certs.sh` creates `ca/ca.key` on first run and never puts it in
the cluster -- only the public `ca.crt` is sealed alongside the lighthouse's
own keypair. Anyone with `ca/ca.key` can mint a certificate for any overlay
IP and join the mesh as any node, so:

- **back `ca/` up** (password manager, encrypted volume). Without it you
  cannot add a single new client, and recovering means re-issuing every
  existing node's cert.
- `ca/` is gitignored. `nebula-cert ca` also refuses to overwrite an existing
  file, which is the second safety net against silently replacing a CA that
  clients already trust.
- The default CA lifetime is ~1 year. When it approaches, sign a new CA,
  concatenate old + new `ca.crt` so both are trusted during the overlap,
  re-sign the nodes, then drop the old one.

## Notes

- **Why `hostNetwork`.** Every client hardcodes `157.151.171.157:4242` in its
  `static_host_map`, so the port must be identical inside and outside the pod.
  A NodePort would renumber it. The cost is `strategy: Recreate` (two pods
  can't bind the same host port) and `dnsPolicy: ClusterFirstWithHostNet`.
- **Why `privileged`.** Same lesson as the two L2TP bridges in this repo: a
  `hostPath` mount of `/dev/net/tun` exposes the device node, but the device
  cgroup still denies `open()`, and nebula fails to create `nebula1`. k8s has
  no per-device allowlist in the pod spec.
- **Changing `config.yml`.** Nebula reloads only some keys on SIGHUP, and
  nothing here watches the ConfigMap, so restart after editing it:
  `kubectl -n nebula-lighthouse rollout restart deploy/nebula-lighthouse`.
- **Relaying costs bandwidth on this box.** Peers that hole-punch
  successfully never touch it; only double-symmetric-NAT pairs do. Set
  `relay.am_relay: false` in `configmap.yaml` if that ever matters.
- **`nebula1`, not `nebula0`.** Matches upstream's default naming and avoids
  colliding with anything else on the node.
