# Vendored licensing dependencies (submodules)

These are **forks** of the upstream GitLab projects, mirrored to GitHub so this
project can pin them reproducibly. They are AGPLv3 and are referenced as git
submodules — their source is **not** copied into this repository.

| Submodule | Fork (origin) | Pinned ref | Upstream |
|---|---|---|---|
| `third_party/fastapi-dls` | `github.com/kars85/fastapi-dls` | tag **2.0.3** (`7346cf6`) | `git.collinwebdesigns.de/oscar.krause/fastapi-dls` |
| `third_party/gridd-unlock-patcher` | `github.com/kars85/gridd-unlock-patcher` | tag **1.1** (`16fb072`) | `git.collinwebdesigns.de/vgpu/gridd-unlock-patcher` |

- **fastapi-dls** — self-hosted NVIDIA vGPU licensing server (DLS). Branch-agnostic
  RS256 token/lease signing; serves R535–R595. Consumed at runtime as a container
  image (see `lib/licensing.sh`); the source is pinned here for reference and for
  building your own image if desired.
- **gridd-unlock-patcher** — patches the guest `nvidia-gridd` (Linux) / `nvxdapix.dll`
  (Windows) to trust a self-hosted DLS root certificate. Required for guest drivers
  **18.x and newer** (R570/R580/R595).

## First-time checkout

```bash
git clone --recurse-submodules <this-repo>
# or, in an existing clone:
git submodule update --init --recursive
```

## Updating from upstream (GitLab)

Each submodule has an `upstream` remote pointing at the original GitLab project:

```bash
cd third_party/fastapi-dls
git fetch upstream --tags
git checkout <new-tag>          # e.g. a future 2.0.4
cd ../..
git add third_party/fastapi-dls # record the new pin
git commit -m "licensing: bump fastapi-dls to <new-tag>"
```

Then mirror the new refs to your GitHub fork so origin stays in sync:

```bash
git -C third_party/fastapi-dls push origin --tags
```

## Notes

- Pins are chosen as the latest tested tags. `fastapi-dls 2.0.3` supports vGPU
  16.x–19.x; **20.x/R595 is not yet in its compatibility matrix** — see
  `FASTAPI_DLS_PLAN.md` Phase C for the enablement work.
- Do not `git checkout` a moving branch (e.g. `main`) as the pin; always pin a tag or
  explicit commit so builds are reproducible.
