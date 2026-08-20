# Running the cup viewer from its container image

For an agent or automated environment that needs the viewer running, without
building it from source.

## What the image is

A static web page served by nginx on port **8080**. There is no backend, no
database, no state, and nothing to configure. It renders a glass cup with a
real-time WebGL2 refraction shader; everything else is client side.

The image is **self-contained**: three.js is vendored in at build time, so it
needs no network access at runtime. The one exception is the Anton display font,
loaded from Google Fonts. Without egress the title falls back to Impact and the
page is otherwise complete and fully functional.

Image: `ghcr.io/arestrepo99/cup`

Tags: the short commit SHA (for example `59367a9`), and `latest`. **Prefer the
SHA tag.** `latest` moves whenever someone publishes, so pinning the SHA is the
difference between a reproducible run and one that changes under you.

## Pull and run

```bash
docker run --rm -p 8080:8080 ghcr.io/arestrepo99/cup:latest
```

Then open `http://localhost:8080/`.

Readiness: poll `GET /healthz`, which returns `200` with the body `ok` once nginx
is serving. Do not treat container start as readiness; wait for that endpoint.

```bash
until curl -sf http://localhost:8080/healthz >/dev/null; do sleep 0.5; done
```

## Authentication

The package is **private by default**, so an anonymous `docker pull` will fail
with `denied` or `unauthorized`. That error means credentials, not a bad tag.

To pull a private image you need a GitHub token with the `read:packages` scope:

```bash
echo "$GITHUB_TOKEN" | docker login ghcr.io -u <github-username> --password-stdin
docker pull ghcr.io/arestrepo99/cup:latest
```

With the `gh` CLI already authenticated, `gh auth token` supplies it:

```bash
gh auth token | docker login ghcr.io -u "$(gh api user -q .login)" --password-stdin
```

If the package has been made public (see below), no login is needed at all.

## Rendering considerations for headless agents

The page requires **WebGL2**. Without it, it shows a plain "WebGL2 required"
message instead of the viewer, which is a legitimate response and not a crash.

Headless Chrome usually has no GPU, so software rendering must be enabled
explicitly or the page will hit that gate:

```bash
chrome --headless=new --enable-unsafe-swiftshader --use-gl=angle \
       --virtual-time-budget=10000 --screenshot=out.png \
       http://localhost:8080/
```

Two things to expect under software rendering. Frame rate will be far below the
real figure — the on-page FPS counter reflects SwiftShader, not the GPU, so do
not use it as a performance measurement. And give the page several seconds:
`--virtual-time-budget` needs to cover the model load, the shader compile, and
enough animation to reach a representative frame.

The controls panel is collapsed to a small gear button in the top-left corner by
default; click it to expand the parameters.

## Building and publishing

```bash
./scripts/publish-container.sh                  # build locally, no push
./scripts/publish-container.sh --push           # multi-arch build, push to GHCR
./scripts/publish-container.sh --push --public  # ...and make it world-pullable
```

Pushing is opt-in because it publishes to a registry others can pull from, and a
tag may be cached elsewhere before you can withdraw it. `--public` is a separate
flag again, since it removes access control entirely.

Publishing needs the `write:packages` scope, which is **not** part of the default
`gh` login:

```bash
gh auth refresh -h github.com -s write:packages
```

The script derives the image path from the `origin` remote, so a fork publishes
under its own namespace, and lowercases it because GHCR rejects uppercase in
image paths while GitHub usernames permit it.
