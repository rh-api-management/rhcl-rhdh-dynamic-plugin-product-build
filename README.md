# RHCL RHDH Dynamic Plugin Product Build

Konflux product-build repository that produces an OCI image containing the
Kuadrant RHDH dynamic plugins for Red Hat Developer Hub:

- `@kuadrant/kuadrant-backstage-plugin-frontend`
- `@kuadrant/kuadrant-backstage-plugin-backend`

The Konflux application is at:
https://konflux-ui.apps.stone-prd-rh01.pg1f.p1.openshiftapps.com/ns/api-management-tenant/applications/rhcl-1-4-rhcl-rhdh-dynamic-plugin

## Repository layout

```
repo/
  build.sh                        # Build script: yarn install, build, export-dynamic
  dynamic-plugins/
    Containerfile                 # FROM scratch — copies pre-built plugin files
    dist/                         # created by build.sh, not committed (gitignored)
  .tekton/
    rhcl-1-4-rhcl-rhdh-dynamic-plugin-push.yaml
    rhcl-1-4-rhcl-rhdh-dynamic-plugin-pull-request.yaml
  .yarnrc.yml                     # sets supportedArchitectures for cachi2
  kuadrant-backstage-plugin/      # git submodule → Kuadrant/kuadrant-backstage-plugin
```

## Pipeline

Builds run hermetically (no internet access) using Konflux/Tekton. All tasks
communicate via OCI Trusted Artifacts — each task stores its output as a
container image in quay.io; the next task pulls and extracts it.

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

### Artifact chain

```
clone-repository
  → SOURCE_ARTIFACT  (the git repo, stored at output-image.git)

prefetch-dependencies
  ← SOURCE_ARTIFACT (from clone)
  → SOURCE_ARTIFACT  (repo + cachi2 config overlaid)
  → CACHI2_ARTIFACT  (all prefetched deps, stored at output-image.prefetch)

build-dynamic-plugins
  ← SOURCE_ARTIFACT + CACHI2_ARTIFACT (from prefetch)
  → SCRIPT_ARTIFACT  (the dynamic-plugins/ dir, stored at output-image.script)
  → SCRIPT_RUNNER_IMAGE_REFERENCE (resolved digest of the yarn/node runner image)

build-container
  ← SOURCE_ARTIFACT = SCRIPT_ARTIFACT (from build task — NOT the original clone)
  ← CACHI2_ARTIFACT (from prefetch)
  → IMAGE_URL + IMAGE_DIGEST
```

`build-container`'s build context is the output of `build-dynamic-plugins`
(`dynamic-plugins/`), not the original repo clone. That is why the Containerfile
is `FROM scratch` with just `COPY dist/`.

### Key tasks

**`clone-repository`** — clones the repo including submodules, stores it as an
OCI trusted artifact.

**`prefetch-dependencies`** — runs cachi2 against the `prefetch-input` parameter.
Downloads ~2931 yarn packages offline and stores them in `CACHI2_ARTIFACT`. Sets
up an offline registry proxy consumed by `build.sh` via `/cachi2/cachi2.env`.
`dev-package-managers: "true"` ensures devDependencies are included (needed for
tsc, turbo, rhdh-cli).

**`build-dynamic-plugins`** — the JS build step. Runs `build.sh` inside
`quay.io/konflux-ci/yarn4-nodejs22-ubi9-minimal:latest` (yarn 4 + node 22).
The script sources `/cachi2/cachi2.env` so yarn works fully offline. The
`dynamic-plugins/` directory at the end of the script becomes `SCRIPT_ARTIFACT`.
Both this task and `prefetch-dependencies` are allocated 6 CPU / 16Gi RAM.

**`build-container`** — buildah builds the `FROM scratch` Containerfile using
`dynamic-plugins/` as the build context. `ADDITIONAL_BASE_IMAGES` records the
yarn/node runner image digest for SLSA provenance.

**`build-image-index`** — wraps the image in an OCI image index, the standard
deliverable format Konflux expects.

**Post-build tasks** (all run in parallel, skipped on PRs via `skip-checks`):

| Task | Purpose |
|---|---|
| `build-source-image` | Builds a source image containing source + prefetched deps (compliance) |
| `clair-scan` | CVE scan of the final image |
| `sast-snyk-check` | Static analysis on source code |
| `sast-shell-check` | shellcheck on bash scripts (including `build.sh`) |
| `sast-unicode-check` | Detects Unicode bidirectional tricks in source |
| `clamav-scan` | Malware scan |
| `coverity-availability-check` | Probes Coverity SAST availability |
| `rpms-signature-scan` | Verifies RPM signatures in the image |
| `deprecated-base-image-check` | Flags EOL base images |
| `apply-tags` | Adds additional tags (e.g. branch name) to the image |
| `push-dockerfile` | Attaches the Containerfile as an OCI artifact alongside the image |

## Submodule

`kuadrant-backstage-plugin/` points to
https://github.com/Kuadrant/kuadrant-backstage-plugin, which is a full
rhdh-local fork (not a standalone plugin repo). Its `yarn.lock` covers the
entire RHDH application (~3878 packages).

The `prefetch-input` uses a `workspaces` filter to limit cachi2 to only the
transitive dependencies of the two kuadrant plugins (~2931 packages). Without
this filter, cachi2 would prefetch everything in the lockfile and OOM.

## build.sh

Runs inside `build-dynamic-plugins`. Steps:

1. Sources `/cachi2/cachi2.env` — sets up the offline package registry proxy
2. `yarn workspaces focus` — installs only the two plugin workspaces (not all 3878 packages)
3. `yarn turbo run build` — compiles the plugins
4. `yarn workspace ... export-dynamic` — exports each plugin as an RHDH dynamic plugin (`dist-dynamic/`)
5. Copies `dist-dynamic/` dirs into `dynamic-plugins/dist/`
6. Copies LICENSE into `dynamic-plugins/`

## OCI plugin format

The final image is `FROM scratch` with plugin files at `/dynamic-plugins/dist/`.
RHDH's init container extracts these at deploy time:

```
/dynamic-plugins/dist/
  kuadrant-backstage-plugin-frontend-dynamic/
  kuadrant-backstage-plugin-backend-dynamic/
```
