# Vineyard Map App v2 — Architecture & Implementation Spec

**Status:** Approved design, ready for implementation.
**Audience:** This document is written for an AI executor (Claude Sonnet/Opus) or a developer
implementing v2. Follow it precisely. Where it says MUST, deviation will break something that
has already been thought through. Read the whole document before writing any code.

---

## 1. Purpose and design principles

The app lets vineyard workers **field-proof NDVI maps**: stand in a vineyard with a phone,
see which block you are in, what's growing there, and which NDVI zone you're standing in.

New in v2 (the reason for this redesign): vineyards have messy records. Workers often don't
know which block they're standing in or what's planted where. v2 shows **the whole vineyard
at once** — every block, labelled, with variety — instead of v1's one-block-at-a-time picker.

Principles (do not violate):

1. **Zero build step.** The app is a single `index.html` (plus `service-worker.js`,
   `manifest.webmanifest`) served as static files. No npm, no bundler, no framework,
   no new CDN dependencies beyond the existing Google Maps JS API and Google Fonts.
2. **Field-first.** Big tap targets, glanceable status, works one-handed in sunlight.
   Every feature must earn its place on a phone screen in a paddock.
3. **Data is messy; the app must not assume it's clean.** Boundary data and NDVI data
   disagree (see §3). Missing files, missing varieties, unmatched blocks are NORMAL states,
   not errors.
4. **Existing customers must keep working with no re-import** (migration is scripted).
5. **The importer stays a PowerShell 5.1 script** (`scripts/import-pix4d.ps1`). Sean runs it
   (or asks Claude to). It must remain idempotent: re-running on the same inputs is safe.

---

## 2. Current state (v1) — what exists today

- **Hosting:** static host with Netlify-style `_redirects` (`/customers/*` passthrough,
  `/*` → `/index.html`). Custom domain `maps.swagritech.com.au`. `404.html` is a
  byte-for-byte copy of `index.html` (SPA fallback for GitHub-Pages-style hosting).
- **Routing:** `/<Customer>/` (path = customer id), `?block=<id>` query param.
  Landing page at `/` with resume-last-customer card and find-customer box.
- **Data per customer:** `customers/<Name>/blocks.json` (id, name, sourceToken per block)
  plus `customers/<Name>/blocks/<id>/block<id>boundary.geojson` and `block<id>rx.geojson`.
  Rx features carry a numeric `zone` property (1=Red, 2=Orange, 3=Green).
- **App behavior:** loads ONE block at a time into two `google.maps.Data` layers, block
  dropdown to switch, zone filter checkboxes, GPS watch with blue dot + accuracy circle +
  follow mode, throttled point-in-polygon hit-test against the loaded block's zones,
  zone pill ("Red zone" / "Outside zones").
- **Importer:** `scripts/import-pix4d.ps1` converts Pix4D shapefile zips → GeoJSON via
  `ogr2ogr` (QGIS), assigns block ids from real block numbers, generates friendly display
  names ("Blocks 3 & 4"), updates `blocks.json`, optional commit+push.

Known v1 defects to fix during v2 (do not fix separately):

- `service-worker.js` pre-caches `/BlkAZones_3_Boundary.kml` and
  `/BlkAZones_3_Prescription.json`, which do not exist. `cache.addAll()` therefore rejects
  and **the service worker never installs** — offline support is currently broken.
- `initMap()` fetches `blocks.json` twice (a validation fetch then a real fetch).

---

## 3. The core model change: Blocks vs Surveys

v1 has one concept ("block") that is actually the NDVI survey unit. v2 has two:

| Concept | Source | What it is | Example (Fishbone) |
|---|---|---|---|
| **Block** | `*_Boundaries.geojson` (hand-drawn, e.g. in Pix4Dfields) | Vineyard truth: the planting unit a worker navigates by. Carries variety (via attributes), area. | "Block 4/5 - 1.929 ha" |
| **Survey** | Pix4D NDVI export (existing `blocks/<id>/` files) | An NDVI capture unit: boundary + rx zones. May cover several blocks. | `B3-4` (blocks 3 and 4 together) |

**Critical reality (verified in the Fishbone data): the two layers DISAGREE, and their
numbering schemes are DIFFERENT — names/numbers are useless as join keys.**

- Boundaries file has blocks 1, 2, 3, **4/5 combined**, 6, 7, 8 (7 polygons).
- NDVI surveys are B2-1-12-11-10, **B3-4 combined**, B5, B6, B7 (5 units).
- Spatial verification (2026-07-08) proved the numbers are scrambled between the two:
  Pix4D's "B5" flight physically sits on drawn "Block 3", "B6" on "Block 1",
  "B2-1-12-11-10" on "Block 4/5". Sean groups blocks freely when flying NDVI (coarse
  groupings tell the overhead story) and numbers them independently of the drawn records.

Consequences the implementation MUST honor:

1. Blocks ↔ surveys are matched **by spatial overlap only** (§4.6), producing 0..N surveys
   per block. NEVER by names or numbers — a number-based join shipped in the first design
   mockup and activated visibly wrong zones; Sean caught it immediately.
2. GPS "which block am I in" hit-tests **block polygons**; GPS "which zone am I in"
   hit-tests **all rx zone polygons directly** — NEVER route zone detection through the
   block→survey mapping (it would be wrong for split/overlapping units).
3. A customer with no boundaries file (all current customers except Fishbone) falls back to
   **surveys acting as blocks**. Everything must degrade gracefully.
4. The boundaries file has **no variety data** (verified: properties are only `color`,
   `creationDate`, `fill`, `visualType`, `name` like `"Block 1 - 1.259 ha"`).
   Variety comes from a hand-maintained `attributes.json` (§4.3).

---

## 4. Data architecture v2

### 4.1 File layout per customer

```
customers/<Name>/
  vineyard.json                    NEW  v2 manifest (metadata only, generated by importer)
  <anything>_Boundaries.geojson    NEW  optional, hand-drawn block boundaries (committed as-is)
  attributes.json                  NEW  optional, hand-edited block attributes (variety etc.)
  blocks.json                      v1 index — KEEP writing it (do not delete; see §7 Phase C)
  blocks/<id>/block<id>boundary.geojson   unchanged (survey boundary)
  blocks/<id>/block<id>rx.geojson         unchanged (survey rx zones)
```

Existing geojson files are **never moved, renamed, or rewritten**. The manifest references
them by relative path.

### 4.2 `vineyard.json` (v2 manifest) — generated by the importer

Metadata only. No geometry is ever embedded. Concrete example for Fishbone:

```json
{
  "schemaVersion": 2,
  "customer": "Fishbone",
  "updatedUtc": "2026-07-08T08:00:00Z",
  "boundaries": "Fishbone_Boundaries.geojson",
  "blocks": [
    {
      "key": "1",
      "featureName": "Block 1 - 1.259 ha",
      "displayName": "Block 1",
      "numbers": [1],
      "areaHa": 1.259,
      "variety": "",
      "notes": ""
    },
    {
      "key": "4/5",
      "featureName": "Block 4/5 - 1.929 ha",
      "displayName": "Block 4/5",
      "numbers": [4, 5],
      "areaHa": 1.929,
      "variety": "",
      "notes": ""
    }
  ],
  "surveys": [
    {
      "id": "5",
      "token": "B5",
      "displayName": "Block 5",
      "numbers": [5],
      "boundary": "blocks/5/block5boundary.geojson",
      "rx": "blocks/5/block5rx.geojson"
    },
    {
      "id": "2",
      "token": "B2-1-12-11-10",
      "displayName": "Blocks 2, 1, 12, 11 & 10",
      "numbers": [2, 1, 12, 11, 10],
      "boundary": "blocks/2/block2boundary.geojson",
      "rx": "blocks/2/block2rx.geojson"
    }
  ]
}
```

Rules:

- `boundaries` is `null` when no boundaries file exists. `blocks` is then `[]`.
- `blocks[].featureName` is the EXACT `name` property of the corresponding feature in the
  boundaries geojson. The app matches features to manifest entries by this exact string —
  the app never parses feature names itself.
- `blocks[].key` and `numbers` come from parsing the feature name with (case-insensitive):
  `^Block\s*(?<nums>[\d\s/&,.-]+?)\s*-\s*(?<area>[\d.]+)\s*ha\s*$`
  where `nums` splits on `/ & , space -` into integers. `displayName` = `"Block " + key`.
  **If a feature name does not match the regex, still emit a block entry**: key = full name,
  numbers = [], areaHa = null, displayName = full name. Never drop features.
- `surveys[]` is derived from the same data as `blocks.json` (id, sourceToken); `numbers`
  parses the token (`B308-103-801` → [308, 103, 801]); `displayName` uses the existing
  `Format-BlockName` friendly-name function.
- **`numbers` (on both blocks and surveys) are display/sorting metadata ONLY.** They MUST
  NOT be used to link blocks to surveys — the numbering schemes across the two datasets
  are proven inconsistent (§3, §4.6).
- Written with the existing `Save-Json` helper (it already un-escapes `& < > '`).

### 4.3 `attributes.json` — hand-edited, merged by the importer

```json
{
  "1":   { "variety": "Chardonnay" },
  "2":   { "variety": "" },
  "4/5": { "variety": "Sauvignon Blanc", "notes": "top half replanted 2024" }
}
```

- Keys match `blocks[].key`. Allowed fields per entry: `variety`, `notes` (strings).
  Unknown fields are copied through verbatim (forward compatibility).
- The importer merges these into the manifest's `blocks[]` on every run.
- If the file is absent and a boundaries file IS present, the importer **scaffolds it**
  (all keys, empty strings) so Sean only has to fill in values.
- The importer MUST NOT overwrite an existing `attributes.json`.

**Variety workflow (decision record).** Sean usually types the variety into the block name
in the drawing tool, but with no consistent format — sometimes it exports, sometimes not.
Therefore: the importer MUST NOT attempt to parse variety from freeform feature names.
`attributes.json` is the single source of truth for variety. To make gaps visible, the
importer prints a summary table after every run that touches a customer with boundaries:

```
Block attributes for 'Fishbone':
  key   feature name              variety
  1     Block 1 - 1.259 ha        Chardonnay
  4/5   Block 4/5 - 1.929 ha      (empty - fill in attributes.json)
```

A drawing-tool naming convention (e.g. `Block 5 - Chardonnay`) MAY be recommended to Sean
in Phase C docs; an opt-in parser for it is a Phase C decision, not part of A/B.

### 4.4 Importer changes (`scripts/import-pix4d.ps1`)

1. **Always (re)generate `vineyard.json`** at the end of a successful run (also in the new
   sync mode below). Keep writing `blocks.json` exactly as today.
2. **Boundaries auto-detect:** case-insensitive search in `customers/<Name>/` (top level
   only) for `*_Boundaries.geojson` or `boundaries.geojson`. First match wins; record its
   filename in the manifest. Parse it with `ConvertFrom-Json` for METADATA ONLY (feature
   names). **MUST NOT rewrite the geojson file** — no ConvertTo-Json round-trip of geometry
   (PowerShell 5.1 mangles precision/formatting). The file is committed as-is.
3. **New parameter `-SyncManifest`** (switch): skips zip/ogr2ogr entirely; just rebuilds
   `vineyard.json` (+ attributes scaffold) from existing `blocks.json` + files on disk.
   `-ZipPath` MUST become optional (`Mandatory = $false`, validate it's provided when not
   `-SyncManifest`). Used to migrate all existing customers:
   ```powershell
   Get-ChildItem .\customers -Directory | ForEach-Object {
     powershell -ExecutionPolicy Bypass -File .\scripts\import-pix4d.ps1 -Customer $_.Name -SyncManifest
   }
   ```
4. Migration keeps v1 `blocks.json` names untouched; the manifest's survey `displayName`
   is regenerated with `Format-BlockName`, so old customers (e.g. Brookland, whose
   blocks.json still has raw names like "B302") get friendly names in v2 for free.

### 4.5 Why manifest + separate files (decision record)

A single embedded bundle was considered and rejected: PowerShell 5.1 JSON round-tripping of
deep coordinate arrays is slow and risky, per-file layout keeps git diffs meaningful, and
HTTP/2 parallel fetch of ~13 small files (~60–350 KB total per customer) is fine even on
rural connections. The service worker caches all of it after first load.

### 4.6 Block ↔ survey linking — spatial, computed in the app at load

**Decision record.** The first design joined blocks to surveys by block-number
intersection. Field review (2026-07-08) disproved it: drawn-boundary numbering and Pix4D
flight numbering are independent schemes. Verified mapping for Fishbone:

| Drawn boundary | Survey physically covering it | Number-join would have said (wrong) |
|---|---|---|
| Block 1 | B6 | B2-1-12-11-10 |
| Block 2 | B7 | B2-1-12-11-10 |
| Block 3 | B5 | B3-4 |
| Block 4/5 | B2-1-12-11-10 | B3-4, B5 |
| Block 6 | B3-4 | B6 |
| Block 7 | (none — no NDVI) | B7 |
| Block 8 | (none — no NDVI) | (none) |

**Algorithm (runtime, in JS, after all files are fetched):** survey `s` is linked to block
`b` iff ANY polygon part of ANY of `s`'s rx features has its representative point inside
`b`'s geometry. Representative point = vertex average of the part's outer ring. Cheap
(~hundreds of point-in-polygon tests per customer) and robust against boundary-edge
slivers, since a sliver's rep point rarely falls inside the neighbouring block.

```js
function repPoints(g) {
  const polys = g.type === "Polygon" ? [g.coordinates] : g.coordinates;
  return polys.map(rings => {
    const ring = rings[0];
    let sx = 0, sy = 0;
    for (const c of ring) { sx += c[0]; sy += c[1]; }
    return [sx / ring.length, sy / ring.length];
  });
}
// survey s covers block b iff:
s.rx.features.some(f => repPoints(f.geometry).some(p => pointInGeom(p[0], p[1], b.geom)))
```

Rules:

- Links are computed in the app at load and NEVER stored in `vineyard.json` — they cannot
  go stale, and the importer never needs geometry logic. (PowerShell 5.1 silently unrolls
  single-element arrays across function boundaries, corrupting nested GeoJSON coordinate
  handling — verified during this design. Geometry code lives in JavaScript only.)
- GPS zone detection stays direct (§3 consequence 2) — links drive only tap/jump zone
  activation and the info card's "NDVI coverage" line.

---

## 5. App UX v2 (`index.html`)

### 5.1 What the user sees

On opening `/<Customer>/`:

1. Map fits to the WHOLE vineyard (union of all block + survey bounds). Satellite view.
2. **Every block is drawn and labelled** (name at polygon center; label visible at
   zoom ≥ 15). Blocks with a known variety show it in the label's second line.
   - Block outlines: white/cyan stroke, near-zero fill (satellite imagery stays visible).
3. **NDVI zones are visible only for the "active" survey(s)** — not all at once (rainbow
   soup). Active surveys change by (last event wins):
   - Tapping a block → that block's spatially linked surveys (§4.6) become active
     (and info card opens).
   - GPS entering a different block → that block's linked surveys become active
     (no card popup while walking — card only on tap).
   - A new **"All zones" checkbox** in the panel forces every survey visible (overrides
     active-set logic while checked). Existing Red/Orange/Green filter checkboxes still
     apply on top.
   - An active survey also draws its flight boundary as a **dashed outline**, so workers
     see NDVI coverage that spills past the drawn blocks. (Implementation note: the Maps
     Data layer cannot render dashed strokes — use `google.maps.Polyline` with dash
     `icons` per ring, `clickable: false`.)
4. **Info card** (tap a block): fixed card, bottom-center on mobile. Contents:
   - Title: `Block 4/5 — Sauvignon Blanc` (displayName — variety if known)
   - Meta line: `1.9 ha · NDVI coverage: B2-1-12-11-10` (areaHa if known; spatially
     linked survey tokens, or "No NDVI survey yet")
   - Buttons: `Zoom to block` · `Close`. (Zones already activated by the tap.)
5. **Status panel** (existing panel, reworked labels):
   - `Customer: Fishbone`
   - `Block: Block 4/5 — Sauvignon Blanc` (GPS-detected block, or `—` when GPS off/outside)
   - `Zone:` existing pill (Red/Orange/Green/Outside zones) — unchanged semantics.
   - Collapsed mini-summary mirrors the same three lines (existing mechanism).
6. **Jump dropdown** (reuse existing `blockSelect`): lists all blocks
   (`Block 1 — Chardonnay (1.3 ha)`), or surveys for legacy customers. Selecting: fit map
   to that block, activate its surveys, open its card. First option: `— Jump to block —`
   (placeholder, no auto-selection on load; the map starts showing everything).
7. GPS behavior (blue dot, accuracy circle, follow mode, start/stop) is UNCHANGED.

### 5.2 Status truthfulness rule

The zone pill reflects the zone polygon under the GPS point across **ALL surveys' zones**,
regardless of which zones are currently visible. Display state (active surveys, filters)
must never change what the pill reports, with one exception kept from v1: the Red/Orange/
Green filter checkboxes also exclude those zones from hit-testing (existing behavior —
keep it, workers use filters to mean "I don't care about these").

GPS block detection: point-in-polygon over block polygons; if no block contains the point,
fall back to survey boundaries (`Block: <survey displayName> (survey)`); else `Outside blocks`.

### 5.3 Data loading (rewrite of the v1 single-block loader)

1. Fetch `/customers/<C>/vineyard.json`. If 404 → fetch `blocks.json` and synthesize an
   in-memory v2 manifest from it (surveys only, `boundaries: null`) — insurance for any
   customer not yet migrated. If both 404 → landing page with error (existing behavior).
2. `Promise.all` over: boundaries file (if any) + each survey's `boundary` and `rx` files.
   Update `statusLabel` with progress (`Loading 7/11…`). One failed file must NOT abort
   the app: log it, show `Status: OK (1 file failed)`, continue without that layer.
3. For each fetched GeoJSON, inject identity properties into every feature BEFORE
   `layer.addGeoJson(json)` (this is how features are traced back to manifest entries):
   - boundaries features: `f.properties.blockKey = <matched block.key>` (match feature's
     `name` property to `blocks[].featureName`; unmatched feature names → synthesize a
     block entry client-side so the polygon still renders and labels as its raw name).
   - survey boundary features: `f.properties.surveyId = <survey.id>`.
   - rx features: `f.properties.surveyId = <survey.id>` (keep existing `zone` property).
4. Build hit-test caches from the SAME raw JSON (don't re-extract from the Data layer):
   `blockGeoms[] = {key, geom}`, `surveyGeoms[] = {surveyId, geom}`,
   `zoneGeoms[] = {zone, surveyId, geom}`. Reuse the existing `pointInGeom` code as-is.
   Then compute each block's `surveyIds` spatially per §4.6.
5. Layers: `blocksLayer` (boundaries), `surveysLayer` (survey flight outlines), `zonesLayer`
   (all rx). Survey outlines render **dashed, only while their survey is active or
   "All zones" is on**; in legacy fallback mode (no boundaries file) they instead render
   solid at all times and act as the block outlines. Zone visibility styling:
   `visible = zoneEnabled(z) && (allZonesChecked || activeSurveyIds.has(surveyId))`.
6. Labels: one `google.maps.Marker` per block at the polygon's bounds center
   (`LatLngBounds.getCenter()` over the feature geometry), `icon: {path: CIRCLE, scale: 0}`,
   `label: {text, color: "#fff", fontSize: "13px", fontWeight: "700"}` with a second
   line for variety via `\n` if present. Toggle all label markers' visibility on
   `zoom_changed` (visible when zoom ≥ 15).

### 5.4 URL / deep links

- `?block=` now carries a block `key` (URL-encoded; `4/5` → `4%2F5`) or, for legacy
  customers, a survey id. On load, if present and matched: activate + fit to it (but still
  load everything). Update the param on dropdown jumps. Old links like `?block=2` keep
  working for legacy customers unchanged.
- `saveLastContext` / resume card: unchanged, stores the same param value.

### 5.5 Landing page

Unchanged except the find-box probe order: try `vineyard.json` first, then `blocks.json`.

---

## 6. Executor guardrails (READ TWICE)

1. **`404.html` MUST be updated to a byte-for-byte copy of `index.html` in the same commit
   as any `index.html` change**: `Copy-Item index.html 404.html -Force`. Deep links break
   on the host otherwise.
2. **Coordinate order:** GeoJSON is `[lng, lat]`; Google Maps is `(lat, lng)`. The existing
   hit-test code already handles this (`x = lng, y = lat`) — reuse it, don't rewrite it.
3. **No frameworks, no build step, no new external dependencies** (§1). No Turf.js — the
   existing point-in-polygon code is sufficient.
4. **PowerShell 5.1 only** for the importer: no `&&`, no `??`, no ternary. Use the existing
   `Save-Json` (handles `&` un-escaping). NEVER round-trip geojson geometry through
   `ConvertFrom-Json | ConvertTo-Json`.
5. **Never modify files under `customers/*/blocks/`** or any `*_Boundaries.geojson` —
   the importer/app treat geometry files as read-only artifacts.
6. **Do not touch the Google Maps API key**, the URL routing scheme, `_redirects`, or the
   `/customers/*` path convention.
7. **Service worker:** bump `CACHE_NAME` to `"vineyard-maps-v2"`, fix `APP_ASSETS` to only
   files that exist (`/`, `/index.html`, `/manifest.webmanifest`,
   `/images/SWAT_Logo_june2025.png`, the two icon PNGs). Keep the network-first fetch
   strategy exactly as is. Never cache `googleapis` origins.
8. **`blocks.json` files stay** — written by the importer and used as the app's fallback.
   Do not delete or stop generating them in Phases A/B.
9. Commit data and code in the granularity of §7's phases; test after each phase before
   moving on. Never commit the raw source folders (e.g. `customers/Fishbone/Fishbone NW/`)
   or `Export.zip` files.
10. If something in this spec contradicts what you find in the repo, STOP and report the
    contradiction instead of improvising.
11. **Never join the two datasets by block names or numbers** — the drawn-boundary
    numbering and the Pix4D flight numbering are proven inconsistent (§4.6). Spatial
    overlap is the only join. If a link looks wrong, inspect geometry; do not "fix" it
    with a name-based patch.

---

## 7. Implementation plan

### Phase A — Importer v2 + data migration (no app changes)

Files: `scripts/import-pix4d.ps1` only, plus generated data files.

1. Implement §4.2–§4.4 (manifest generation, boundaries auto-detect + name parsing,
   attributes merge + scaffold, `-SyncManifest` mode, optional `-ZipPath`).
2. Run `-SyncManifest` for all six customers (Brindle, Brookland, Fishbone, Menzies,
   Secretgarden, Seruling).
3. Commit `customers/Fishbone/Fishbone_Boundaries.geojson` (it is currently untracked).

**Acceptance (verify each, report results):**
- Every customer folder has a parseable `vineyard.json` with `schemaVersion: 2`.
- Fishbone: `boundaries` set, 7 block entries (keys `1,2,3,4/5,6,7,8`), block `4/5` has
  `numbers: [4,5]` and `areaHa: 1.929`; 5 surveys; `attributes.json` scaffold exists.
- Brookland: `boundaries: null`, `blocks: []`, 7 surveys, survey `B302`'s displayName is
  `"Block 302"` (friendly), while `blocks.json` is byte-identical to before Phase A.
- `git status` shows ONLY: modified importer, new `vineyard.json` ×6, new Fishbone
  boundaries + attributes files. No `.geojson` under `blocks/` modified.
- Re-running `-SyncManifest` twice in a row produces zero further diff (idempotent).
- Run the full Brookland regression: dry-run import of `Export.zip` still maps tokens to
  existing ids 1–7 as today.

### Phase B — App v2

Files: `index.html` (then copy to `404.html`), `service-worker.js`.

1. Implement §5 in `index.html`. Reuse (do not rewrite): panel collapse mechanism,
   landing/find/resume logic, GPS engine, PIP functions, zone pill, styling approach.
   Remove: single-block loading, the double-fetch of blocks.json.
2. Fix the service worker per guardrail 7.
3. `Copy-Item index.html 404.html -Force`.

**Acceptance — manual test script (run with a local static server, e.g.
`python -m http.server` or any static file server; test in Chrome device mode):**

| # | Action | Expected |
|---|---|---|
| B1 | Open `/Fishbone/` | Map fits whole vineyard; 7 labelled block outlines; no zones visible; no card |
| B2 | Tap the "Block 4/5" polygon | Card: `Block 4/5 — <variety or no dash>`; meta shows `1.9 ha` and `NDVI coverage: B2-1-12-11-10`; that flight's zones + dashed flight outline appear. It MUST NOT activate B3-4 or B5 (§4.6 — names are scrambled) |
| B2b | Tap "Block 3" | Card meta `NDVI coverage: B5`; B5's zones appear over Block 3 |
| B3 | Tap "Block 8" | Card shows `No NDVI survey yet`; no zones appear |
| B4 | Tick "All zones" | Every survey's zones visible; untick → back to active-only |
| B5 | DevTools > Sensors > set location lat `-33.79210` lng `115.07300`; Start GPS | Status `Block: Block 1`; zones of survey `B6` activate (spatial link); pill shows a colour or "Outside zones" (between rows) |
| B6 | Move sensor to lat `-33.79265` lng `115.07300` | Status changes to `Block 3`; zones of `B5` activate; pill updates |
| B7 | Jump dropdown → "Block 7" | Map fits Block 7; card opens showing `No NDVI survey yet` (drawn Block 7 has NO spatially linked survey — §4.6); NO zones activate; URL gains `?block=7`. To see zones activate on a jump, use Block 1 (→B6) or Block 4/5 (→B2-1-12-11-10) |
| B8 | Open `/Brookland/` (legacy, no boundaries) | Survey outlines act as blocks, labelled with friendly names ("Blocks 101, 102, 104 & 307"); tap + GPS + dropdown all work |
| B9 | Open `/Brookland/?block=2` (legacy deep link) | Fits survey 2, activates its zones |
| B10 | Open `/NoSuchCustomer/` | Landing page with error (unchanged v1 behavior) |
| B11 | Reload with DevTools offline (after one online load) | App shell + data load from SW cache; map tiles may be blank (expected — Google tiles aren't cached) |
| B12 | `git diff --stat` | Only `index.html`, `404.html`, `service-worker.js` changed; `404.html` identical to `index.html` (`fc.exe /b index.html 404.html`) |

### Phase C — Docs & polish (after Sean field-verifies B)

1. Update `docs/EXPORT_PROTOCOL.md`: boundaries-file convention, attributes.json workflow,
   `-SyncManifest`, the two-layer model.
2. Refresh `docs/PIX4D_Export_Cheat_Sheet.docx` to match.
3. Only now consider retiring v1 `blocks.json` reads/writes (separate decision with Sean).

---

## 8. Out of scope (explicitly deferred)

- Offline base-map tiles (would require MapLibre + self-hosted tiles; Google satellite
  imagery is core value — revisit only if offline becomes critical).
- Multi-site support beyond one map per customer (Fishbone NW vs other sites: all polygons
  render on one map; fine at current scale).
- Survey dates / NDVI freshness metadata (add `-SurveyDate` importer param later).
- Editing block attributes in the app UI (attributes.json is the workflow for now).
- A web-based uploader replacing the PowerShell importer.
