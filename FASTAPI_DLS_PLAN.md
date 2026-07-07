# FastAPI-DLS Licensing Plan — support newer vGPU drivers (R570 → R595)

**Status:** Proposed · **Owner:** kars85 · **Author:** Claude Fable 5
**Goal:** Make the self-hosted licensing path work reliably for vGPU **18.x/19.x**
and the **20.x (R595)** branch your T4 host actually runs, and pin it into the
`proxmox-vgpu-installer` v2.0 project reproducibly.

---

## 1. How licensing actually works (so the plan targets the right layer)

Verified by reading the upstream repo (`fastapi-dls` **2.0.3**, `app/main.py`,
`README.md` compatibility matrix):

- **The server is branch-agnostic.** FastAPI-DLS signs client-tokens and leases
  with a self-generated CA → SI cert chain using an **RS256 JWT** (`python-jose`,
  `jwk.construct(...RS256)`). The same code path serves R535 through R595 — there is
  no per-driver-branch logic in token/lease signing. It exposes the root cert at
  `GET /-/config/root-certificate`.
- **The guest is where new branches break.** From driver **18.x onward**, the guest
  `nvidia-gridd` (Linux) / `nvxdapix.dll` (Windows) validates the DLS against
  **NVIDIA's official root certificate** and rejects a self-hosted DLS. The
  **`gridd-unlock-patcher`** (separate repo: `git.collinwebdesigns.de/vgpu/gridd-unlock-patcher`)
  patches the guest binary to trust *our* root cert instead. This is the real lever
  for "newer driver support."
- **Current upstream coverage:** FastAPI-DLS 2.x compatibility matrix lists through
  **19.0 / R580** (host `580.65.05`, Linux guest `580.65.06`, Windows `580.88`).
  **20.x / R595 is not listed** — likely works (branch-agnostic signing) but is
  untested and needs the guest patcher to understand the R595 gridd layout.

**Conclusion:** "update fastapi-dls for newer drivers" is mostly (a) pin a known-good
server image, (b) make sure **gridd-unlock-patcher** handles R595, and (c) automate
the guest-side patch + root-cert fetch in our installer. The server itself probably
needs **no code change**; the work is integration + guest tooling + testing.

---

## 2. Current gaps in *our* project (`lib/licensing.sh`)

| # | Gap | Fix |
|---|-----|-----|
| 1 | Image pinned to mutable tag `collinwebdesigns/fastapi-dls:2` (`:6`) | Pin to an immutable ref (`2.0.3` or `@sha256:...`), or our own built image. |
| 2 | Wrong gridd-unlock-patcher URL: points at `oscar.krause/...` (`:176`) | Real repo is `vgpu/gridd-unlock-patcher`. Correct it. |
| 3 | gridd-unlock-patcher is only *mentioned*, not automated | Fetch root cert from `/-/config/root-certificate`, run the patcher, in the guest scripts. |
| 4 | Guest scripts don't fetch the DLS root certificate | Add `curl .../-/config/root-certificate` step for 18.x+ guests. |
| 5 | No post-deploy health check of the container | Poll `https://<ip>:<port>/-/health` after `compose up`. |
| 6 | No 20.x/R595 entry in our driver catalog guest licensing note | Add once tested. |

Already modern (no work): compose v2 (`docker compose`), no `version:` key, routable
host-IP detection, TZ from `timedatectl`, port-conflict warning.

---

## 3. Strategy decision: fork vs. consume

**Recommendation: fork both repos to your GitHub for control, but consume the server
as a pinned image rather than vendoring its source.**

- **Fork `fastapi-dls` → `github.com/kars85/fastapi-dls`** — gives you a stable place
  to (a) pin from, (b) carry a patch if R595 ever needs a server change, (c) rebuild
  an image under your control. Track upstream `main`/tags via a remote.
- **Fork `gridd-unlock-patcher` → `github.com/kars85/gridd-unlock-patcher`** — this is
  the component most likely to need an R595 update; owning a fork lets you patch it.
- **Do NOT copy either source into `proxmox-vgpu-installer`.** Reference them as
  **git submodules** under `third_party/` (or just document the pinned refs). Keeps our
  repo clean and licenses separate (both are AGPLv3 — vendoring pulls that in).
- **Image sourcing:** default to upstream `collinwebdesigns/fastapi-dls` pinned by
  digest; optionally build your fork to **GHCR** (`ghcr.io/kars85/fastapi-dls`) via CI
  for full reproducibility. Make the image configurable via env in `licensing.sh`.

---

## 4. Phased plan

### Phase A — Fork & clone (reproducible baseline)
1. `gh repo fork https://git.collinwebdesigns.de/...` isn't possible (GitLab source);
   instead **mirror-push** to new GitHub repos:
   ```bash
   # fastapi-dls
   gh repo create kars85/fastapi-dls --public --disable-wiki
   git clone --mirror https://git.collinwebdesigns.de/oscar.krause/fastapi-dls.git
   git -C fastapi-dls.git push --mirror https://github.com/kars85/fastapi-dls.git
   # gridd-unlock-patcher
   gh repo create kars85/gridd-unlock-patcher --public --disable-wiki
   git clone --mirror https://git.collinwebdesigns.de/vgpu/gridd-unlock-patcher.git
   git -C gridd-unlock-patcher.git push --mirror https://github.com/kars85/gridd-unlock-patcher.git
   ```
2. Add an `upstream` remote on each fork pointing back at the GitLab origin so you can
   pull updates: `git remote add upstream <gitlab-url>`.
3. In `proxmox-vgpu-installer`, add submodules (pinned to the tested commit):
   ```bash
   git submodule add https://github.com/kars85/fastapi-dls third_party/fastapi-dls
   git submodule add https://github.com/kars85/gridd-unlock-patcher third_party/gridd-unlock-patcher
   ```
   *(Alternative if submodules are unwanted: a `licensing/UPSTREAM.md` recording the
   pinned commit SHAs + image digest.)*
- **Acceptance:** both forks exist on GitHub, mirror upstream, and are referenced at a
  known-good pinned SHA from our repo.

### Phase B — Reproducible server image
1. Resolve and record the digest of `collinwebdesigns/fastapi-dls:2.0.3`
   (`docker buildx imagetools inspect ...`).
2. Make the image configurable in `lib/licensing.sh`:
   `FASTAPI_DLS_IMAGE="${FASTAPI_DLS_IMAGE:-collinwebdesigns/fastapi-dls@sha256:<digest>}"`.
3. *(Optional)* CI in the `fastapi-dls` fork builds `ghcr.io/kars85/fastapi-dls:2.0.3`
   from the pinned source for a fully self-owned supply chain.
- **Acceptance:** `docker compose up` pulls a byte-stable image; digest recorded in repo.

### Phase C — R595 / vGPU 20.x enablement (the actual "newer driver" work)
1. **Server smoke test with your hardware:** deploy 2.0.3, point your T4 guest
   (595.71.05) at it, and check whether a token is accepted *after* patching gridd.
2. **gridd-unlock-patcher for R595:** confirm it recognizes the 595 `nvidia-gridd`
   (Linux) and `nvxdapix.dll` (Windows). If not:
   - diff the R580 vs R595 gridd binary signature/patch offsets,
   - update the patcher's pattern/cert-embed logic in your fork,
   - open an upstream MR so it lands for everyone.
3. **Update compatibility matrix:** add the `2.x | 20.0 | R595 | 595.71.03 | 595.71.05 |
   596.36` row (README in the fork; and our driver-catalog guest note).
- **Acceptance:** a 595/vGPU-20 Linux **and** Windows guest reach
  "License acquired successfully" against the self-hosted DLS.

### Phase D — Integrate into `proxmox-vgpu-installer`
1. `lib/licensing.sh`:
   - fix the gridd-unlock-patcher URL (`vgpu/...`), pin image (Phase B),
   - after `compose up`, health-check `https://<ip>:<port>/-/health` (retry loop),
   - emit the **root-cert fetch** into guest scripts:
     `curl --insecure https://<ip>:<port>/-/config/root-certificate -o /tmp/dls-root.crt`,
   - for R570/R580/R595 branches, generate a guest step that runs gridd-unlock-patcher
     with that root cert before restarting `nvidia-gridd`.
2. `data/driver_catalog.json`: add a `licensing` hint per branch
   (`fastapi_dls_min_version`, `needs_gridd_unlock`) so the guest scripts are generated
   from data, not hard-coded branch strings.
3. Extend `tests/smoke.sh`: assert 18.x/19.x/20.x guest scripts include the root-cert
   fetch + patcher step, and 16.x/17.x do not.
- **Acceptance:** `./installer.sh license` on a 20.x host produces guest scripts that
  license end-to-end with no manual steps beyond running them.

### Phase E — Docs & maintenance
1. README licensing section: self-host vs. NVIDIA NLS, the gridd-unlock-patcher
   requirement per branch, and an "update your fork from upstream" runbook.
2. A `make licensing-update` / script to `git -C third_party/* fetch upstream` and
   bump pins.
- **Acceptance:** a new contributor can rebuild the licensing stack from pinned refs.

---

## 5. Risks & open decisions

| Decision | Recommendation |
|---|---|
| Fork vs. vendor source | Fork to GitHub + submodule/pin; never copy AGPLv3 source into our tree. |
| Upstream image vs. self-built | Start with pinned upstream digest; self-build to GHCR only if you want zero external trust. |
| Where R595 work lands | In the `gridd-unlock-patcher` fork (guest side); upstream it. Server likely untouched. |
| Docker on the PVE host | Keep opt-in (as now); document the LXC/VM alternative for the DLS container. |
| Submodules vs. UPSTREAM.md | Submodules if you want it pinned in-tree; UPSTREAM.md if you prefer a lighter repo. |
| 20.x still unverified upstream | Treat as "should work"; gate the compat-matrix row behind your own successful test. |

## 6. Reference facts (verified July 2026)

- fastapi-dls latest tag **2.0.3**; Python 3.12-alpine, `python-jose`+`cryptography`
  RS256 signing, SQLite/Postgres/MariaDB; compat matrix tops at **19.0 / R580**.
- Server exposes `GET /-/config/root-certificate` — "required for patching nvidia-gridd
  on 18.x, 19.x releases."
- gridd-unlock-patcher repo: `git.collinwebdesigns.de/vgpu/gridd-unlock-patcher`
  (created Apr 2025). Patches guest `nvidia-gridd` / `nvxdapix.dll` to trust a
  self-hosted DLS root cert. **R595 support must be verified/added.**
- Your hardware: host `595.71.03` / guest `595.71.05` = **vGPU 20.x / R595** — beyond
  the current upstream-tested matrix, so this plan's Phase C is the load-bearing part.
