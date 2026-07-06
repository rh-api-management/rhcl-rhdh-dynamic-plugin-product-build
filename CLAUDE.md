# CLAUDE.md — rhcl-rhdh-dynamic-plugin-product-build

## What this repo is

Konflux product-build repository that produces an OCI image containing the
Kuadrant RHDH dynamic plugins (`@kuadrant/kuadrant-backstage-plugin-frontend`
and `@kuadrant/kuadrant-backstage-plugin-backend`) for Red Hat Developer Hub.

The Konflux application is:
https://konflux-ui.apps.stone-prd-rh01.pg1f.p1.openshiftapps.com/ns/api-management-tenant/applications/rhcl-1-4-rhcl-rhdh-dynamic-plugin

## Repo layout

```
repo/
  build.sh                        # Build script: yarn install, build, export-dynamic
  dynamic-plugins/
    Containerfile                 # FROM scratch — copies pre-built plugin files
    dist/                         # created by build.sh, not committed (gitignored)
  .tekton/
    rhcl-1-4-rhcl-rhdh-dynamic-plugin-push.yaml
    rhcl-1-4-rhcl-rhdh-dynamic-plugin-pull-request.yaml
  packaging/                      # standalone yarn workspace for cachi2 prefetch
  kuadrant-backstage-plugin/      # git submodule → Kuadrant/kuadrant-backstage-plugin
```

## Architecture (ansible-rhdh-plugins pattern)

This repo follows the architecture used by
https://github.com/ansible/ansible-rhdh-plugins:

```
Clone → Prefetch (cachi2) → build-dynamic-plugins task → build-container (buildah FROM scratch)
```

Key insight: the **build happens in a dedicated tekton task** (`run-script-oci-ta`),
not inside the Containerfile. The Containerfile is `FROM scratch` and just packages
the pre-built plugin files into an OCI image.

### Why this matters

- The Containerfile build context is the **output of the build task** (`dynamic-plugins/`
  directory), not the full repo clone.
- The `buildah-oci-ta` task receives `SOURCE_ARTIFACT` from `build-dynamic-plugins`,
  not from `clone-repository`.
- This decouples the JS build environment from the image packaging step.

## The submodule problem

`kuadrant-backstage-plugin/` is a submodule pointing to
https://github.com/Kuadrant/kuadrant-backstage-plugin.git.

**That repo is a full rhdh-local fork** (local dev environment for RHDH), not
a standalone plugin repo. Its `yarn.lock` contains ~3878 packages — dependencies
for both the Kuadrant plugins AND the full RHDH application.

The solution is `packaging/` at the repo root — a standalone yarn workspace with
its own `yarn.lock` (~2800 packages) that covers only the two plugin packages.
cachi2 prefetches from there, never touching the submodule's full lockfile.

## cachi2 / Konflux prefetch

Builds run hermetically (no internet). All dependencies must be pre-fetched by
the `prefetch-dependencies` task (cachi2) before the build task runs.

### prefetch-input

```json
[{"type": "yarn", "path": "./packaging"}]
```

`packaging/` is a standalone yarn workspace root at the repo root covering only
the two kuadrant plugins. Its `yarn.lock` contains ~2800 packages instead of the
full rhdh-local lockfile (~3878 packages).

### What cachi2 reads from the yarn path

cachi2 reads `./packaging/.yarnrc.yml` for the yarn prefetch. That file sets:
- `supportedArchitectures: {cpu: [x64], os: [linux]}` — limits platform-specific
  package fetches to x64 Linux only
- `nodeLinker: node-modules`
- `enableGlobalCache: true` — harmless in hermetic mode (ansible uses it too)

### Why yarn workspaces focus doesn't work in hermetic builds

`yarn workspaces focus` always runs a resolution step that contacts
`registry.yarnpkg.com`, even with a lockfile present. This fails with network
isolation. `yarn install --immutable` skips the resolution step (lockfile is
treated as frozen) and is the correct approach for hermetic builds.

### The build task reads /cachi2/cachi2.env

Inside the `run-script-oci-ta` task, the hermetic environment is set up by cachi2.
`build.sh` must source `/cachi2/cachi2.env` before running yarn commands:

```bash
if [ -f /cachi2/cachi2.env ]; then source /cachi2/cachi2.env; fi
```

## Tekton pipeline

### Task flow

```
init
  └─► clone-repository
        └─► prefetch-dependencies
              └─► build-dynamic-plugins
                    └─► build-container
                          └─► build-image-index
                                ├─► build-source-image
                                ├─► clair-scan
                                ├─► sast-snyk-check
                                ├─► sast-shell-check
                                ├─► sast-unicode-check
                                ├─► clamav-scan
                                ├─► coverity-availability-check
                                ├─► deprecated-base-image-check
                                ├─► rpms-signature-scan
                                ├─► apply-tags
                                └─► push-dockerfile
```

### OCI Trusted Artifact chain

Every task passes its output to the next via OCI Trusted Artifacts — output is
stored as a container image in quay.io, not via PVC workspaces.

```
clone-repository
  → SOURCE_ARTIFACT  (repo stored at output-image.git)

prefetch-dependencies
  ← SOURCE_ARTIFACT (from clone)
  → SOURCE_ARTIFACT  (repo + cachi2 config overlaid)
  → CACHI2_ARTIFACT  (prefetched deps, stored at output-image.prefetch)

build-dynamic-plugins (run-script-oci-ta)
  ← SOURCE_ARTIFACT + CACHI2_ARTIFACT (from prefetch)
  → SCRIPT_ARTIFACT  (dynamic-plugins/ dir, stored at output-image.script)
  → SCRIPT_RUNNER_IMAGE_REFERENCE (resolved digest of the yarn/node runner)

build-container (buildah-oci-ta)
  ← SOURCE_ARTIFACT = SCRIPT_ARTIFACT  ← NOT the original clone
  ← CACHI2_ARTIFACT (from prefetch)
  → IMAGE_URL + IMAGE_DIGEST
```

`build-container`'s build context is `dynamic-plugins/` (the script output),
not the original repo. This is why the Containerfile is `FROM scratch COPY dist/`.

### Post-build tasks

All run in parallel after `build-image-index`. Skipped on PRs (`skip-checks: "true"`).

- `build-source-image` — compliance source image (source + prefetched deps)
- `clair-scan` — CVE scan
- `sast-snyk-check`, `sast-shell-check`, `sast-unicode-check` — static analysis
- `clamav-scan` — malware scan
- `coverity-availability-check` — probes Coverity availability (doesn't run it)
- `rpms-signature-scan` — RPM signature check (mostly no-op for FROM scratch)
- `deprecated-base-image-check` — flags EOL base images
- `apply-tags` — tags the image (branch name, etc.)
- `push-dockerfile` — attaches Containerfile to the image as OCI artifact;
  sourced from `SCRIPT_ARTIFACT` (so it finds `dynamic-plugins/Containerfile`)

### ADDITIONAL_BASE_IMAGES

`build-container` receives `SCRIPT_RUNNER_IMAGE_REFERENCE` (the resolved digest
of the yarn/node runner image) as `ADDITIONAL_BASE_IMAGES`. This records the
runner in SLSA provenance, satisfying Red Hat supply chain policy.

## run-script-oci-ta task

Konflux catalog task that:
1. Extracts SOURCE_ARTIFACT (source code) and PREFETCH_ARTIFACT (cachi2 deps)
2. Runs a shell script (`SCRIPT`) in `SCRIPT_RUNNER_IMAGE`
3. Stores the directory at `SCRIPT_ARTIFACT_RELATIVE_PATH` as a new OCI trusted artifact

Key params for our use:
- `SCRIPT_RUNNER_IMAGE`: `quay.io/konflux-ci/yarn4-nodejs22-ubi9-minimal:3ce50e6`
  (pinned digest tag; has yarn 4 + node 22; no need to install yarn separately)
- `SCRIPT_ARTIFACT_RELATIVE_PATH`: `dynamic-plugins` (the directory build.sh populates)
- `HERMETIC`: passed through from pipeline param

## build.sh

Runs inside `run-script-oci-ta`. Responsibilities:
1. Source `/cachi2/cachi2.env` (sets up offline package registry proxy)
2. `cd packaging` — use the minimal plugin-only workspace at the repo root
3. `yarn install --immutable` — install plugin deps from cachi2 cache (no resolution step)
4. `yarn workspace ... build` — build frontend first (backend imports frontend's permission types)
5. `yarn workspace ... export-dynamic` — export as RHDH dynamic plugin format
6. Collect plugin dirs into `dynamic-plugins/dist/`
7. Copy LICENSE into `dynamic-plugins/`

## dynamic-plugins/Containerfile

```dockerfile
FROM scratch
COPY dist/ /
COPY LICENSE /licenses/LICENSE
LABEL ...
USER 1001
```

Build context = `dynamic-plugins/` (the SCRIPT_ARTIFACT from the build task).
The Containerfile itself lives in `dynamic-plugins/Containerfile` (committed).

## OCI plugin format

The final OCI image is `FROM scratch` with plugin files at the image root.
RHDH's init container extracts these files when deploying. Plugin directories:
- `/kuadrant-backstage-plugin-frontend-dynamic/`
- `/kuadrant-backstage-plugin-backend-dynamic/`

## What NOT to do

- Do not set `yarnPath` in `.yarnrc.yml` for hermetic builds — hermeto (cachi2's
  yarn support) provides its own yarn binary.
- Do not build in the Containerfile itself (old pattern) — resource limits on
  the buildah task are too tight; the dedicated build task has 16Gi RAM.
- Do not use multiarch builds for this component — the JS output is
  architecture-agnostic; building per-arch OOMed the prefetch container.

## Key references

- Similar repo: https://github.com/ansible/ansible-rhdh-plugins
- Konflux task catalog: quay.io/konflux-ci/tekton-catalog/
  - `task-run-script-oci-ta:0.1`
  - `task-buildah-oci-ta:0.10`
  - `task-git-clone-oci-ta:0.1`
  - `task-prefetch-dependencies-oci-ta:0.3`
  - `task-build-image-index:0.3`
  - `task-source-build-oci-ta:0.3`
- Upstream submodule: https://github.com/Kuadrant/kuadrant-backstage-plugin
