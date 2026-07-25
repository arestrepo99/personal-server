# NetBird secrets: how to seal `config.yaml`

`config.yaml.template` in this directory has no real secrets in it -- it's
safe to have committed to git. The actual `config.yaml` NetBird reads (with
real secret values filled in) is delivered to the cluster as a
`SealedSecret` (`secret-config.sealed.yaml`), which **is** safe to commit
since it's encrypted and only the `sealed-secrets-controller` running in
this cluster can decrypt it.

## One-time setup, after the `sealed-secrets` Application (wave 0) is Synced/Healthy

1. Install the `kubeseal` CLI matching the controller's app version
   (`0.38.4` as pinned in `apps/sealed-secrets.yaml`):
   ```bash
   KUBESEAL_VERSION=0.38.4
   curl -fsSL -o kubeseal.tar.gz \
     "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-arm64.tar.gz"
   tar -xzf kubeseal.tar.gz kubeseal
   sudo install -m 755 kubeseal /usr/local/bin/kubeseal
   ```

2. Generate the three real secret values. `store.encryptionKey` specifically
   must be **base64-encoded 32 raw bytes** -- NetBird base64-decodes this
   field and checks the decoded length. `openssl rand -hex 32` produces a
   64-char hex string, which happens to also be valid base64 and decodes to
   48 bytes, not 32 -- causes a `FATL ... failed to create field encryptor:
   encryption key must be 32 bytes, got 48` crash loop. Use `-base64`, not
   `-hex`, for this one:
   ```bash
   AUTH_SECRET=$(openssl rand -hex 32)
   STORE_ENCRYPTION_KEY=$(openssl rand -base64 32)
   OWNER_PASSWORD=$(openssl rand -base64 24)
   echo "Save this owner password somewhere safe: $OWNER_PASSWORD"
   ```

3. Render the real `config.yaml` from the template:
   ```bash
   sed -e "s/<PLACEHOLDER_AUTH_SECRET>/$AUTH_SECRET/" \
       -e "s/<PLACEHOLDER_STORE_ENCRYPTION_KEY>/$STORE_ENCRYPTION_KEY/" \
       -e "s/<PLACEHOLDER_OWNER_PASSWORD>/$OWNER_PASSWORD/" \
       config.yaml.template > /tmp/config.yaml
   ```

4. Turn it into a plain Secret manifest, then seal it (never commit the
   plain version -- only the sealed output):
   ```bash
   kubectl create secret generic netbird-config \
     --namespace netbird \
     --from-file=config.yaml=/tmp/config.yaml \
     --dry-run=client -o yaml > /tmp/netbird-config-plain.yaml

   kubeseal --format yaml \
     --controller-name sealed-secrets-controller \
     --controller-namespace sealed-secrets \
     < /tmp/netbird-config-plain.yaml > secret-config.sealed.yaml

   shred -u /tmp/config.yaml /tmp/netbird-config-plain.yaml
   ```

5. Commit `secret-config.sealed.yaml` in this directory and push. ArgoCD
   will pick it up, the controller unseals it into a real `netbird-config`
   Secret in the `netbird` namespace, and the `netbird-server` Deployment
   mounts it.

## First login / wiring up Google OIDC

The embedded auth in `config.yaml` is always on and self-issues its own
OIDC tokens (`auth.issuer`) -- Google isn't configured via `config.yaml` at
all. Sequence:

1. Once `https://netbird.arec.me` is up with a valid cert, log in with the
   `owner` email/password from step 2 above (local auth).
2. In the dashboard: **Settings -> Identity Providers -> Add Identity
   Provider -> Google**.
3. NetBird will display the exact redirect URI to register. Go to Google
   Cloud Console (APIs & Services -> Credentials -> OAuth client ID -> Web
   application), leave redirect URIs empty initially, then paste that
   exact URL back in once NetBird shows it -- don't hand-type a guessed
   path.
4. Scopes needed: `openid profile email`. Google does not provide a
   `groups` claim -- group-based policies need manual group management in
   NetBird.
5. Test Google login from an incognito window before considering
   `localAuthDisabled: true` (disabling local auth) in `config.yaml.template`
   / re-sealing.

## Known issue to watch for

`netbirdio/dashboard#690` -- Google's token endpoint
(`oauth2.googleapis.com`) isn't in the dashboard's default CSP `connect-src`,
which silently breaks the PKCE token exchange. Already worked around via the
`NETBIRD_CSP` env var in `dashboard-deployment.yaml` -- if Google login still
fails with a browser console CSP violation, that's the first thing to check.
