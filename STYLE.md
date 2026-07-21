# Terminal output style

The installer and the `tracebloc` CLI share **one** terminal style system. This
is the reference; `scripts/check-style.sh` enforces the mechanical parts in CI.

## The idea

From the tracebloc.io homepage gradient — **cyan orients, lime moves**:

- **cyan** `#01a5cc` = *structure* — headings, step titles, links, "where you are"
- **lime** `#91e947` = *action* — commands, the primary CTA, "what to do next"

Everything else stays quiet (dim neutral). Colour is never load-bearing: headings
and commands also carry **bold**, and alerts carry a distinct **glyph**, so the
output still reads under `NO_COLOR`, in a pipe, or for a colour-blind reader.

## Roles → tones

Don't hardcode colour. Use the helper / tone for the role:

| Role | Tone (bash `common.sh`) | Colour | Weight / glyph |
|------|-------------------------|--------|----------------|
| Heading / section / step | `TB_HEADING`, `step_header`, `step` | cyan `#01a5cc` | bold |
| Command (to run) | `TB_CMD` | lime `#91e947` | bold |
| Description / supporting | `TB_DESC` | soft lime `#a7ed6c` | — |
| Link / URL | `TB_LINK` | cyan `#01a5cc` | underline |
| Success ✔ / online ● | `success`, `TB_GO` | lime `#91e947` | glyph |
| Warning ⚠ | `warn`, `TB_WARN` | amber `#ffc62b` | glyph |
| Error ✖ | `error`, `TB_ERR` | red `#f64c4c` | bold glyph |
| Label : value | `TB_LABEL` | dim neutral | — |

**No emoji.** The lime `●` is the online indicator (not 🟢); status uses the
glyphs above.

The colour **engine** lives in one place per surface — extend it there, never
inline a raw escape or hex elsewhere:

- Installer (bash + ps1): `scripts/lib/common.sh` (`_sgr` + the `TB_*` tones).
- Go CLI: `internal/ui/ui.go` (the `tone` table + `hue()`), mirrored 1:1.

It renders exact 24-bit hex on truecolor terminals, the **deep shade**
(`#01637a` / `#578c2b`) on light backgrounds, the nearest ANSI-16 otherwise, and
nothing when colour is off (`NO_COLOR` / non-TTY / `TERM=dumb` / `TB_PLAIN=1`).
The Windows `install-k8s.ps1` runs at the 16-colour tier (`Write-Host` can't do
truecolor): same roles (cyan structure, green commands), not exact hex.

## Terminology

Source of truth: the docs repo `TERMINOLOGY.md`. In user-facing output:

| Use | Not |
|-----|-----|
| secure environment | workspace, hub, client (as a noun for the environment) |
| ingest | upload, import |
| delete | remove, uninstall (for offboarding) |
| Online / Offline | connected / disconnected, up / down |
| collaborators | users, members |
| task | job, experiment type |

`client` stays valid as the CLI verb (`tracebloc client create`) and in code
identifiers — the guard only flags `workspace` in user-facing text.

## What's enforced vs reviewed

`scripts/check-style.sh` (CI, blocking) catches the **mechanical** violations:
hardcoded brand colour outside `common.sh`, status emoji, and `workspace` in
user-facing text. Run it locally with `bash scripts/check-style.sh`.

It can't police **judgement** — using the right *role* for a token (a command in
the command tone, not the heading tone), or the softer terminology calls. Those
stay with review; `STYLE.md` and `scripts/check-style.sh` are CODEOWNER-gated so
the rules can't be quietly weakened.

To intentionally exempt a line, append `# style-guard: allow` with a reason.
