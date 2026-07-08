# NDVI Import Wizard — Implementation Spec

**Status:** Approved design, ready for implementation.
**Audience:** AI executor (Claude Sonnet) or developer. Follow precisely; MUST means it.
Read this whole document AND `docs/V2_DESIGN.md` §4 + §6 before writing code — the v2
guardrails carry over. If this spec contradicts the repo, STOP and report (V2 guardrail 10).

---

## 1. Purpose and principles

Sean (field operator, not a developer) needs to import Pix4D NDVI exports and boundary
files without remembering commands, and to be **asked** about gaps (like a missing
variety) instead of noticing them later. Today this is a CLI (`scripts/import-pix4d.ps1`)
he cannot remember how to run.

Principles (do not violate):

1. **The wizard is a thin interactive wrapper.** `scripts/import-pix4d.ps1` remains the
   only conversion/manifest engine. The wizard NEVER re-implements parsing, conversion,
   or manifest logic — it gathers inputs, invokes the importer, interviews gaps, and
   publishes. One narrowly-scoped importer amendment is allowed (§7).
2. **Zero new runtime.** Windows PowerShell 5.1 + a double-clickable `.cmd`. No modules,
   no packaging, no GUI framework. (A WinForms file-open dialog via
   `Add-Type -AssemblyName System.Windows.Forms` is allowed — it ships with Windows.)
3. **Testable headlessly.** The wizard accepts `-RepoRoot` so tests run against a
   throwaway fixture repo, and reads answers from redirected stdin (`Read-Host` reads
   piped lines in powershell.exe). No test may touch real customer data.
4. **Nothing publishes without an explicit Y.** All git operations are scoped to
   `customers/<Customer>` pathspecs. NEVER `git add -A`.
5. **No geometry math in PowerShell** (V2 §4.6 rule). The optional coverage check runs
   via Node when available and is silently skipped otherwise.

## 2. Deliverables

| File | What |
|---|---|
| `Import NDVI Maps.cmd` | Repo root. Double-click launcher. |
| `scripts/import-wizard.ps1` | The wizard. |
| `scripts/check-coverage.mjs` | Node helper: block↔flight coverage report (§6.4). |
| `scripts/import-pix4d.ps1` | ONE amendment only (§7). |
| `docs/EXPORT_PROTOCOL.md` | Add a short "Easiest way: double-click Import NDVI Maps" intro section. |

`Import NDVI Maps.cmd` contents (exactly):

```bat
@echo off
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "scripts\import-wizard.ps1"
```

(No `pause` — the wizard itself ends with a "Press Enter to close" prompt.)

## 3. Wizard skeleton

```
param(
  [string]$RepoRoot = ""   # default: resolve to the script's parent directory's parent
)
```

- Resolve `$RepoRoot` (default `Split-Path -Parent $PSScriptRoot`). Validate it contains
  `customers\` and `scripts\import-pix4d.ps1`; exit with a clear message otherwise.
- `Set-StrictMode -Version Latest`; `$ErrorActionPreference = "Stop"` with a top-level
  try/catch that prints the error in red and still reaches "Press Enter to close".
- Console styling: section headers in Green, warnings Yellow, errors Red, prompts default.
- Every `[Y/n]` prompt: Enter = Y. Every "(Enter to skip)": Enter = skip. State the
  default in the prompt text itself.

Main menu (after an environment report, §6.0):

```
What do you want to do?
  1) Import an NDVI export (zip)
  2) Update the block boundaries file for a vineyard
  3) Check gaps / publish pending changes
  Q) Quit
Choice [1]:
```

All three paths converge on: **sync → gap interview (§6) → publish prompt (§8)**.

## 4. Customer selection (shared step)

- List directories under `customers\` as a numbered menu, plus `N) New vineyard…`.
- New vineyard: prompt for a name matching `^[A-Za-z0-9]+$` (it becomes the URL path);
  reject (case-insensitive) reserved names: `customers, icons, images, favicon.ico,
  manifest.webmanifest, service-worker.js`. Create `customers\<Name>\`. Echo the future
  URL: `https://maps.swagritech.com.au/<Name>/`.

## 5. The three flows

### 5.1 Flow 1 — Import an NDVI export

1. File-open dialog: title "Choose the Pix4D export zip", filter `Zip files (*.zip)|*.zip`,
   initial directory = the user's Downloads folder (`Join-Path $env:USERPROFILE "Downloads"`).
   Dialog cancelled → back to main menu.
2. Run the importer `-DryRun` and show its output verbatim:
   `powershell -NoProfile -ExecutionPolicy Bypass -File "<repo>\scripts\import-pix4d.ps1" -ZipPath "<zip>" -Customer "<C>" -RepoRoot "<repo>" -DryRun`
   (Always pass `-RepoRoot` — the wizard may be running against a fixture.)
3. `Does the block mapping look right? Convert now [Y/n]:` — n → main menu, nothing changed.
4. Run the importer live (same command minus `-DryRun`). Non-zero exit → red message:
   files were NOT published; show the importer's error; mention
   `docs/EXPORT_PROTOCOL.md` for naming rules; return to main menu. Do NOT auto-revert.
5. Continue to §6 gap interview, then §8 publish.

### 5.2 Flow 2 — Update the boundaries file

1. File-open dialog: title "Choose the boundaries GeoJSON", filter
   `GeoJSON (*.geojson)|*.geojson`, initial dir Downloads.
2. Sanity-parse it (ConvertFrom-Json; count `features`). Show:
   `Found <n> block boundaries. Names: Block 1 Cab Sauv - 0.588 ha, … (first 3)`.
   If the existing canonical file exists, show both files' feature counts and dates, then
   `Replace the current boundaries for <C>? [Y/n]`.
3. Copy (never move) to the canonical path `customers\<C>\<C>_Boundaries.geojson`
   (`-Force`). The source file is READ-ONLY to us — never modify or delete it.
4. If OTHER `*boundaries*.geojson` files (case-insensitive) exist at the customer top
   level besides the canonical one, list them and ask
   `Remove the old boundaries file(s) so only one remains? [Y/n]` — the importer takes
   the first alphabetical match, so duplicates are a real hazard. (git history preserves
   anything removed.)
5. Run the importer `-SyncManifest -RepoRoot "<repo>"`, then §6, then §8.

### 5.3 Flow 3 — Check gaps / publish pending

1. Run the importer `-SyncManifest -RepoRoot "<repo>"` (refreshes the manifest).
2. §6 gap interview, §8 publish (which also picks up any earlier unpublished changes
   under this customer).

## 6. Environment report and gap interview

### 6.0 Environment report (wizard start, before the menu)

Print a one-line status for each; do not block unless noted:

- `ogr2ogr`: reuse the importer's candidate paths (Get-Command + the QGIS paths). Missing
  → yellow warning "zip imports will fail until QGIS is installed" (Flow 1 then refuses
  to start, Flows 2–3 still work).
- `git`: present + `user.name`/`user.email` set. Missing identity → yellow warning that
  publishing will be disabled (publish step hides).
- `node`: present → coverage check available; absent → note it will be skipped.
- Whether `$RepoRoot` is a git work tree (`git rev-parse --is-inside-work-tree`). Not a
  repo (e.g. fixture) → publishing hidden entirely.

### 6.0b Boundaries presence check (first step of every gap interview)

A missing boundaries file is itself a gap: NDVI flights are often combined groupings,
but the drawn boundaries are the per-block truth — without them the map has no
per-block names/varieties and GPS can't announce block crossings. If no
`(^|_)boundaries.geojson` (case-insensitive) exists at the customer top level:

```
Gap: no block boundaries file is loaded for <C>.
The map will show NDVI flight areas only - no per-block names, varieties, or GPS block announcements.
Load a boundaries GeoJSON now? [Y/n]:
```

Y → run the shared boundaries loader (the same pick → preview → copy → dedupe → re-sync
routine Flow 2 uses; factored as `Invoke-BoundariesLoad`, result via
`$script:BoundariesLoadOk` — never capture the call, it would swallow the nested
importer's stdout). n or a cancelled/failed load → yellow
`You can load it any time: wizard option 2.` and the interview continues regardless.
This makes the one-sitting flow work: import a zip for a new vineyard → offered the
boundaries file → variety interview → publish.

### 6.1 Variety interview (the core ask)

After the sync, read `customers\<C>\vineyard.json`. If `boundaries` is null, skip 6.1.

- For each `blocks[]` entry with an empty `variety`, prompt:
  `Variety for <displayName> (Enter to skip):`
- Non-empty answers are written into `customers\<C>\attributes.json` under the block's
  `key` (create the file/entry if needed; PRESERVE all existing entries and unknown
  fields; only set `variety`). Use a `Write-JsonFile` helper that replicates the
  importer's `Save-Json` un-escaping (`&`→`&`, `<`→`<`, `>`→`>`,
  `'`→`'`) and appends a trailing newline.
- Spelling guard: compare each answered/parsed variety (trimmed, case-insensitive exact
  match) against this list:
  `Cabernet Sauvignon, Cab Sauv, Cab Franc, Cabernet Franc, Shiraz, Merlot, Malbec,
  Petit Verdot, Tempranillo, Grenache, Mataro, Pinot Noir, Pinot, Pinot Gris, Sangiovese,
  Nebbiolo, Zinfandel, Chardonnay, Sauvignon Blanc, Semillon, Chenin Blanc, Riesling,
  Vermentino, Viognier, Muscat`
  No match → `"<x>" isn't in the common grape list - keep it as typed? [Y/n]` (n → re-prompt
  that block). This is a typo tripwire, not a validator — Y always wins.
- If anything was answered: re-run the importer `-SyncManifest` once so `vineyard.json`
  reflects the answers, then show the importer's final variety table.

### 6.2 Zone sanity scan (informational)

Regex-scan each `customers\<C>\blocks\<id>\block<id>rx.geojson` file's raw text for
`"zone"\s*:\s*(-?\d+)`. Any value outside 1–3 → yellow warning listing file + values.
No prompt, no JSON parsing, never modify these files.

### 6.3 Missing-pair sanity (informational)

For each survey in `vineyard.json`, `Test-Path` its `boundary` and `rx` files; warn in
yellow for any missing (the app tolerates this — the wizard just surfaces it).

### 6.4 Coverage report (informational, Node only)

If `node` is available, run `scripts/check-coverage.mjs "<repo>" "<Customer>"` and print
its output; otherwise print "(coverage check skipped - Node not installed)".

`check-coverage.mjs` (new file): loads the customer's `vineyard.json`; if `boundaries`
is null exits silently (exit 0). Otherwise loads the boundaries file + each survey's rx
file and reports, using EXACTLY the rep-point algorithm and PIP functions from
`docs/V2_DESIGN.md` §4.6 (copy the code shapes; also copy `pointInRing`/`pointInPolygon`/
`pointInGeom` from `index.html`):

```
NDVI coverage for Fishbone:
  Block 5 (Cab Sauv)      <- B5
  Block 7 (Chardonnay)    <- (no NDVI flight covers this block)
  Flight B9: covers no drawn block
```

Plain `console.log`, no dependencies, Node 18+ syntax, exit 0 always (warnings are not
errors).

## 7. The ONE importer amendment

In `scripts/import-pix4d.ps1`, the manifest section currently throws when `blocks.json`
is missing. Change ONLY this: when `-SyncManifest` is set and `blocks.json` does not
exist, use an in-memory empty structure
(`[pscustomobject]@{ customer = $Customer; defaultBlock = "1"; blocks = @() }`) and do
NOT write a `blocks.json`. (Enables boundaries-first onboarding of a new vineyard with no
NDVI flights yet — manifest gets `blocks` from boundaries and `surveys: []`.) In non-sync
mode the existing throw stays. No other importer change is permitted.

## 8. Publish step

Shown only when: inside a git work tree AND git identity is set.

1. `git status --porcelain -- "customers/<C>"`, then FILTER the result to only the
   publishable paths in step 3 (untracked raw-source folders like
   `customers/<C>/Fishbone NW/` also show up under the customer pathspec and MUST be
   ignored). Nothing publishable → "Nothing new to publish." and return to menu.
2. Show the publishable changed files (paths only), then:
   `Publish these to the live map now? [Y/n]:`
   Y/N prompts accept only Y, N, or Enter (=Y); anything else re-prompts — a stray
   keypress must never count as consent to publish.
3. On Y, stage ONLY:
   `customers/<C>/vineyard.json`, `customers/<C>/attributes.json`,
   `customers/<C>/blocks.json`, `customers/<C>/blocks`, and the canonical
   `customers/<C>/<C>_Boundaries.geojson` — each path only if it exists. NEVER stage raw
   source folders (e.g. `customers/<C>/<anything else>/`), zips, or paths outside
   `customers/<C>`.
4. Commit message by flow: Flow 1 `Import NDVI for <C>`; Flow 2
   `Update <C> block boundaries`; Flow 3 `Update <C> block attributes`.
5. `git push origin <current branch>`. Success → green:
   `Live in ~1 minute: https://maps.swagritech.com.au/<C>/`
   Push failure → red message that the commit is saved locally and re-running the wizard
   (Flow 3) can retry the push; do not retry automatically.
6. On n → "Saved locally, not published. Run the wizard again (option 3) to publish."

## 9. Executor guardrails

1. PowerShell 5.1 only: no `&&`, `??`, ternary. Beware single-element array unrolling
   across function returns — wrap with `,` or build arrays inline (see V2 §4.6 note).
2. Only touch the §2 deliverables. NEVER `index.html`, `404.html`, `service-worker.js`,
   `_redirects`, `.claude/`, or anything under `customers/` (tests use fixtures).
3. Do NOT git commit, stage, or push anything — leave the working tree for architect
   review. (The PUBLISH step's git logic is exercised only against fixtures, §10.)
4. Invoke the importer exactly as shown (child `powershell -NoProfile -ExecutionPolicy
   Bypass -File … -RepoRoot …`), checking `$LASTEXITCODE`.
5. Quote every path (OneDrive path contains spaces). Test tooling note: run scripts via
   the PowerShell tool, not Bash (Bash mangles `powershell -File` backslashes).
6. Temp/fixture files go under the session scratchpad directory, never the repo.
7. All user-facing text: plain, friendly, no jargon. The exact prompt strings in this
   spec are the copy — use them verbatim.

## 10. Acceptance tests (run all; report PASS/FAIL with evidence)

Build a **fixture repo** in the scratchpad: `fixture\customers\TestVine\` containing a
copy of Fishbone's `blocks\` + `blocks.json` + a boundaries file renamed
`TestVine_Boundaries.geojson` in which ONE feature's name is edited to
`"Block 9 - 0.500 ha"` (no variety → a real gap; edit the copy's JSON text — this is a
fixture, not customer data). `git init` the fixture (with a local test identity) so
publish logic can be exercised safely; also prepare a SECOND fixture without `.git` to
test publish-hiding.

| # | Test | Expected |
|---|---|---|
| W1 | `.cmd` exists; wizard parses: `[scriptblock]::Create((Get-Content -Raw import-wizard.ps1))` | No parse errors |
| W2 | Pipe scripted answers: menu 3 on TestVine fixture | Runs sync; prompts `Variety for Block 9 (Enter to skip):` |
| W3 | Answer `Chardonnay` | attributes.json gains `"9": {"variety":"Chardonnay"...}`; after re-sync `vineyard.json` block 9 variety = Chardonnay; final table shows it |
| W4 | Answer a misspelling (`Chardonay`) in a fresh run on another gap | Wizard asks the keep-as-typed question; `n` re-prompts, `Y` keeps |
| W5 | Menu 3 again, all varieties filled | No variety prompts; "no gaps" wording shown |
| W6 | Zone scan against a fixture rx file hand-edited to contain `"zone": 4` | Yellow warning names the file and value 4 |
| W7 | Publish flow in the git fixture: answer Y | Commit created in fixture with ONLY the §8 pathspec files staged; push failure handled per §8.5 (fixture has no remote — expect the red local-commit message) |
| W8 | Publish prompt in the non-git fixture | Publish step hidden; wizard says why |
| W9 | Flow 2 with a second boundaries file present | Canonical copy written; duplicate-file prompt appears; after Y only one boundaries file remains |
| W10 | Importer amendment: `-SyncManifest` on a fixture customer with boundaries but NO blocks.json | vineyard.json written with blocks from boundaries, `surveys: []`; no blocks.json created; zip-mode behavior unchanged (regression: dry-run Brookland mapping via `-RepoRoot` pointing at the REAL repo is read-only and must still list ids 1–7) |
| W11 | `check-coverage.mjs` on the real repo, Fishbone (read-only) | Reports Blocks 1,2,10,11,12←B2-1-12-11-10; 3,4←B3-4; 5,5b←B5; 6←B6; 7←B7 |
| W12 | `git status --porcelain` on the REAL repo at the end | Shows ONLY: new `Import NDVI Maps.cmd`, new `scripts/import-wizard.ps1`, new `scripts/check-coverage.mjs`, modified `scripts/import-pix4d.ps1`, modified `docs/EXPORT_PROTOCOL.md` |

## 11. Out of scope

- Web-based uploader (revisit if a non-QGIS machine or second person needs to upload).
- Any GUI beyond the file-open dialogs.
- Editing NDVI/rx data, spatial joins in PowerShell, deleting customers, multi-customer
  batch runs.
