# Installer supply-chain integrity (RFC-0001 R8)

**Audience:** release engineers and security reviewers.
**Scope:** how the two bootstraps — `curl | bash` (`scripts/install.sh`) and the
Windows `irm | iex` peer (`scripts/install.ps1`, §7) — verify the sub-scripts
they run, and exactly what the release pipeline + key management must provide
for that verification to be real.

Tracking issue: **backend#889** (private security ticket). RFC: §9, §14 R8, §13.

---

## 1. The problem this closes

The bootstrap is the **most privileged code in the product**: the sub-scripts it
fetches install the CLI, run `tracebloc login` + `client create` to **mint the
machine credential**, write that credential to disk, and run **Helm** as a
cluster admin. Before this change it pulled ~15 sub-scripts from a **mutable
branch ref** (`BRANCH`, default `main`) over `raw.githubusercontent.com` with
**no checksum and no signature**. Whoever could move that ref — or sit on-path —
could change what ran as root on every customer box. The cosign-signed CLI
binary covered only the *leaf*; everything upstream of it was unverified.

## 2. The verification model (what the installer does today)

1. **Immutable ref.** `scripts/install.sh` fetches every sub-script from a fixed
   release **tag** (`DEFAULT_REF`, e.g. `v2.0.1`), not a branch. GitHub serves
   tag content immutably, so the tag's bytes can't be moved under us. A `BRANCH`
   / non-`vX.Y.Z` ref is refused unless the operator sets
   `TRACEBLOC_ALLOW_UNVERIFIED=1` (developer-only, and it shouts).

2. **Signed manifest.** A `manifest.sha256` lists the sha256 of every sub-script
   at that tag. The bootstrap downloads each sub-script, recomputes its digest,
   and compares it to the manifest. **Any mismatch, or any sub-script missing
   from the manifest, aborts the install** — before `install-k8s.sh` (and thus
   `provision.sh` / Helm) runs.

3. **Authenticated manifest.** The manifest itself is **cosign-signed** (keyless
   Sigstore — the same machinery the CLI binary uses). The bootstrap verifies
   `manifest.sha256.sig` against `manifest.sha256.cert` with cosign before
   trusting a single digest in it. The signing identity is pinned to the
   tracebloc/client release workflow's OIDC certificate.

4. **Fail-closed, never silent-skip.** If cosign is not on PATH, the bootstrap
   **bootstraps a pinned cosign** (downloads the release binary for the host
   OS/arch and verifies it against cosign's own published checksums) and uses
   that. If cosign can be neither found nor bootstrapped, the install **fails
   closed** with remediation — it does **not** degrade to a checksum fetched over
   the same channel an attacker controls. The only way past is the explicit
   `TRACEBLOC_ALLOW_UNVERIFIED=1` opt-in.

The assets the bootstraps consume are published as **GitHub Release assets** on
the pinned tag:

| Asset | Produced by | Verifies |
|---|---|---|
| `install.sh` | release job, `DEFAULT_REF` stamped to the tag | the entrypoint itself (pin) |
| `install.ps1` | release job, `$DefaultRef` stamped to the tag | the Windows entrypoint (pin, §7) |
| `manifest.sha256` | `scripts/gen-manifest.sh` | every sub-script's bytes (both platforms) |
| `manifest.sha256.sig` | `cosign sign-blob` (keyless) | authenticity of the manifest |
| `manifest.sha256.cert` | `cosign sign-blob` (keyless) | the cert the sig verifies against |

Sub-script **content** is still pulled from the immutable tag *tree*
(`raw.githubusercontent.com/.../<tag>/scripts/...`); only the manifest +
signature live as release assets (signing happens in CI *after* the tag is cut,
so they can't be committed into the tagged commit — same reason the CLI serves
`SHA256SUMS` as a release asset).

## 3. Why cosign keyless (and not minisign / gpg)

| Option | Key management | Why / why not |
|---|---|---|
| **cosign keyless (chosen)** | **None.** Signing identity = the GitHub Actions OIDC token for the release workflow; transparency via Rekor. | The CLI binary release already uses exactly this (`cli/.github/workflows/release.yml`). One mechanism, one verification idiom across both repos. No long-lived private key to store, rotate, or leak. |
| minisign | A long-lived private key held in a repo secret or offline. | Adds a secret to manage + a new compromise vector. No transparency log. |
| gpg | A long-lived private key + keyring/web-of-trust. | Heaviest key management; awkward in CI; same secret-custody problem. |

The decisive factor: cosign keyless introduces **no new signing secret**. The
trust root is GitHub's OIDC issuer + the certificate-identity of the release
workflow, both already trusted by the CLI's verification path.

## 4. What the release pipeline must provide  — IMPLEMENTED here

`.github/workflows/release-helm-chart.yaml` gains a `sign-installer-manifest`
job (runs on `release: published`, same trigger as the chart publish) that:

1. Checks out the **released tag** (`github.event.release.tag_name`).
2. Installs cosign (`sigstore/cosign-installer`, pinned `v2.4.1`).
3. Runs `scripts/gen-manifest.sh` to (re)generate `manifest.sha256` from the
   exact `FILES` the bootstrap fetches — the script cross-checks the two `FILES`
   lists and fails on drift, so a sub-script can never ship unlisted.
4. `cosign sign-blob` → `manifest.sha256.sig` + `manifest.sha256.cert` (keyless;
   needs `id-token: write`, already granted).
5. Stamps `__TRACEBLOC_RELEASE_REF__` → the tag in a *copy* of `install.sh` and
   self-tests that the stamped installer parses and **fails closed** on a
   mutable ref.
6. Attaches `install.sh`, `manifest.sha256`, `manifest.sha256.sig`,
   `manifest.sha256.cert` to the release.

A CI gate in `installer-tests.yaml` (`gen-manifest.sh --check`) fails any PR that
changes a sub-script without regenerating the committed manifest, so the
in-repo manifest never drifts from the scripts it covers.

## 5. Human follow-ups required to make this fully real

These are **infra / process** items a human must own — they are **not** code in
this PR, and some depend on repo settings or one-time decisions:

1. **Verify keyless signing works on the first release that includes this job.**
   The `release` job in this repo did not previously do cosign signing; confirm
   the runner gets an OIDC token (the job sets `id-token: write`) and that
   `cosign sign-blob` succeeds end-to-end on a real `release: published` event.
   *(Owner: release engineering.)*

2. **Pin / publish `DEFAULT_REF` for the documented entrypoints.**
   - The in-repo `install.sh` keeps the `__TRACEBLOC_RELEASE_REF__` placeholder
     and **must not** be curl-piped directly (it fails closed). The canonical
     entrypoints must serve the **stamped release asset**:
     - `https://tracebloc.io/i.sh` → redirect/proxy to
       `https://github.com/tracebloc/client/releases/latest/download/install.sh`
       (or a specific tag). **This redirect is infra the website owns** — update
       it so customers get the stamped, pinned installer, not the raw `main`
       copy. *(Owner: web / infra.)*
     - The README / INSTALL `raw.githubusercontent.com/.../main/scripts/install.sh`
       one-liners are updated in this PR to point at the release-asset URL.

3. **Decide the cosign-bootstrap trust posture for hardened/air-gapped sites.**
   When cosign is absent the bootstrap downloads it from the sigstore GitHub
   release and verifies it against `cosign_checksums.txt` fetched over the same
   TLS channel — a pragmatic trust root, strictly better than today's nothing,
   but not a signature-rooted one (you can't verify cosign's signature without
   cosign). For regulated buyers, document the stronger options: (a) pre-install
   cosign via the OS package manager before running the installer, or (b) mirror
   a pinned cosign internally. *(Owner: security; doc'd in §6 below.)*

4. **Certificate-identity hardening.** The bootstrap currently accepts any
   workflow under `tracebloc/client/.github/workflows/*` as the signer
   (`--certificate-identity-regexp`). Once `sign-installer-manifest` is the
   settled signer, tighten this to the exact workflow path
   (`.../release-helm-chart.yaml@refs/tags/<tag>`) to narrow the trust surface.
   *(Owner: security; tracked as a follow-up so we don't lock the regex before
   the first signed release proves the exact identity string.)*

5. **Branch-protect the release workflow + tags.** The keyless trust root is
   "whatever the release workflow signs." Protect `release-helm-chart.yaml` and
   the `gen-manifest.sh` FILES list under CODEOWNERS, and restrict who can push
   `v*` tags / publish releases. *(Owner: repo admin.)*

## 6. Operator guidance — verifying a release by hand

Anyone can independently verify a release the same way the bootstrap does:

```bash
TAG=v2.0.1
BASE=https://github.com/tracebloc/client/releases/download/$TAG
curl -fsSLO "$BASE/manifest.sha256"
curl -fsSLO "$BASE/manifest.sha256.sig"
curl -fsSLO "$BASE/manifest.sha256.cert"

cosign verify-blob \
  --certificate-identity-regexp \
    'https://github.com/tracebloc/client/\.github/workflows/.*@.*' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  --certificate manifest.sha256.cert \
  --signature   manifest.sha256.sig \
  manifest.sha256
# → "Verified OK"

# Then confirm a sub-script matches the manifest:
curl -fsSL "https://raw.githubusercontent.com/tracebloc/client/$TAG/scripts/lib/provision.sh" \
  | sha256sum  # compare to the provision.sh line in manifest.sha256
```

On Windows the same `cosign verify-blob` invocation works verbatim (cosign ships
a Windows binary); compare a sub-script's digest with
`Get-FileHash -Algorithm SHA256 install-k8s.ps1` against its line in
`manifest.sha256`.

**Hardened / air-gapped sites:** install cosign from your OS package manager (or
an internal mirror) *before* running the installer, so the bootstrap uses a
cosign you already trust rather than downloading one.

## 7. The Windows bootstrap (`scripts/install.ps1`)

Everything above applies to Windows as well — `scripts/install.ps1` is the
PowerShell peer of `install.sh` and implements the same guarantee (added with
the R8 Windows leg, PR #299):

1. **Immutable ref.** The release pipeline stamps `$DefaultRef` to the release
   tag in the same "Stamp the published installer" job that stamps `install.sh`
   (`release-helm-chart.yaml`), and self-tests the stamp before attaching the
   asset. An un-stamped copy (placeholder ref) **refuses to run**. `$env:REF`
   pins a different release tag; the legacy `$env:BRANCH` escape and any
   non-`vX.Y.Z` ref require `$env:TRACEBLOC_ALLOW_UNVERIFIED = '1'` and warn
   loudly.
2. **Signed manifest.** Its integrity surface (`$Files`, currently
   `scripts/install-k8s.ps1`) is hashed into the **same** `manifest.sha256`:
   the `WINDOWS_FILES` array in `gen-manifest.sh` mirrors `$Files`, and the CI
   `--check` gate fails any PR where the two drift — exactly like the bash
   `FILES` list. One manifest, one cosign signature, both entrypoints.
3. **Fail-closed cosign.** The manifest signature is required on the default
   path. If cosign is absent, the bootstrap fetches the pinned `$CosignVersion`
   release binary and verifies it against cosign's published checksums; if it
   can be neither found nor bootstrapped, the install **fails closed** — the
   only way past is the explicit `TRACEBLOC_ALLOW_UNVERIFIED` opt-in.

Canonical Windows entrypoint (PowerShell as Administrator):

```powershell
irm https://github.com/tracebloc/client/releases/latest/download/install.ps1 | iex
```

The raw-`main` copy of `install.ps1` is un-stamped and fails closed by design;
customers must use the release asset. (A raw `<TAG>` URL serves the same
un-stamped tree — the committed tag tree keeps the `__TRACEBLOC_RELEASE_REF__`
placeholder; only the release *asset* is stamped — so it too refuses to run
unless you also set `$env:REF = '<TAG>'` to pin the ref yourself.)
