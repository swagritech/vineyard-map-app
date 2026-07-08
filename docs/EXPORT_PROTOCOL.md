# Pix4D Export Naming Protocol (Cheat Sheet)

## Easiest way: double-click "Import NDVI Maps"

You do not need to read this whole document or remember any PowerShell commands.
In the `vineyard-map-app` folder, double-click **`Import NDVI Maps.cmd`**. A wizard
opens and walks you through everything:

- Import an NDVI export (zip) - pick the file, it shows you the block mapping
  before changing anything, then converts it.
- Update the block boundaries file for a vineyard.
- Check for gaps (like a missing variety) and publish pending changes.

It asks a plain-English question at every step (Enter always picks the safe
default) and never publishes to the live map without you confirming. The rest of
this document is a reference for the underlying `import-pix4d.ps1` script, useful
if you want to run imports by hand or understand what the wizard is doing.

Use this protocol for all Pix4D exports so imports can run with zero manual renaming.

> **Note:** The importer also reads native Pix4D layer names directly, so renaming is
> optional. All of these are recognized automatically:
>
> - Strict protocol: `B05_Boundary.shp`, `B03-04_WestRun_Rx.shp`
> - Native Pix4D: `NDVI - Block 5 3 zone_Boundary.shp`, `NDVI - Block 3&4 3 zone_Rx.shp`,
>   `NDVI - Blocks 2 1 12 11 10 3zone_Boundary.shp`
> - Legacy Pix4D: `NDVI 101 102 Zones3_Rx.shp`
>
> **Block IDs follow the real block number.** A single block `B5` imports as block `5`
> (folder `blocks/5`, shown as "5" in the app status box). Combined blocks use their first
> number as the id (e.g. `B3-4` -> id `3`), falling back to the next free id on a clash.
>
> **Display names are generated automatically** (shown in the block dropdown), preserving the
> block order from the file: `B5` -> "Block 5", `B3-4` -> "Blocks 3 & 4",
> `B2-1-12-11-10` -> "Blocks 2, 1, 12, 11 & 10". A strict-protocol label still overrides this.

## 1) Zip Structure

Your zip should contain:

- `Boundary/` (all boundary shapefile sets)
- `Rx/` (all prescription shapefile sets)

Each shapefile set includes `.shp`, `.dbf`, `.shx`, `.prj`, `.cpg`.

## 2) File Naming Rules

Use the same token in both `Boundary` and `Rx`.

### Single operational block

- `B01_Boundary.shp`
- `B01_Rx.shp`

### Combined operational blocks

- `B01-02-04_Boundary.shp`
- `B01-02-04_Rx.shp`

### Optional display label

- `B01_MainNorth_Boundary.shp`
- `B01_MainNorth_Rx.shp`
- `B01-02-04_WestRun_Boundary.shp`
- `B01-02-04_WestRun_Rx.shp`

Label rules:

- Allowed: letters, numbers, dash (`-`)
- No spaces (use `-` instead)
- Keep labels short and clear

## 3) Attribute Rules

Rx layer must include numeric zone values:

- `zone = 1|2|3`

Other Rx fields can stay as exported (`appName`, `rate`, `rateInt`, `unit`).

## 4) Step-By-Step (Click-By-Click)

Use these steps if you are not familiar with PowerShell.

1. Open File Explorer.
2. Browse to:
   `C:\Users\seanm\OneDrive - Southwest Agri-Tech Pty Ltd\SWAT\App\vineyard-map-app`
3. Click the folder path bar at the top, type `powershell`, then press `Enter`.
4. A PowerShell window opens in the correct folder.
5. Run a dry run first (safe test):

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\import-pix4d.ps1 `
  -ZipPath "C:\path\to\Export.zip" `
  -Customer "Brookland" `
  -DryRun
```

6. Check the output summary. Confirm block tokens and IDs look correct.
7. Run the live import (writes files):

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\import-pix4d.ps1 `
  -ZipPath "C:\path\to\Export.zip" `
  -Customer "Brookland"
```

8. To also upload to GitHub in one run, use:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\import-pix4d.ps1 `
  -ZipPath "C:\path\to\Export.zip" `
  -Customer "Brookland" `
  -Commit `
  -Push
```

9. Wait for:
- `Committed changes: ...`
- `Pushed to origin/<branch>`

10. Open GitHub and confirm updated files under:
- `customers/<Customer>/blocks.json`
- `customers/<Customer>/blocks/<id>/block<id>boundary.geojson`
- `customers/<Customer>/blocks/<id>/block<id>rx.geojson`
11. If commit fails with "Author identity unknown", run again with:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\import-pix4d.ps1 `
  -ZipPath "C:\path\to\Export.zip" `
  -Customer "Brookland" `
  -Commit `
  -Push `
  -GitUserName "Your Name" `
  -GitUserEmail "you@example.com"
```
12. Optional one-time setup (recommended):

```powershell
git config --global user.name "Your Name"
git config --global user.email "you@example.com"
```

## 5) Import Command (Quick Reference)

From repo root (`vineyard-map-app`):

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\import-pix4d.ps1 `
  -ZipPath "C:\path\to\Export.zip" `
  -Customer "Brookland"
```

Dry run:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\import-pix4d.ps1 `
  -ZipPath "C:\path\to\Export.zip" `
  -Customer "Brookland" `
  -DryRun
```

Live run + commit + push:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\import-pix4d.ps1 `
  -ZipPath "C:\path\to\Export.zip" `
  -Customer "Brookland" `
  -Commit `
  -Push
```

Live run + commit + push (with git identity):

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\import-pix4d.ps1 `
  -ZipPath "C:\path\to\Export.zip" `
  -Customer "Brookland" `
  -Commit `
  -Push `
  -GitUserName "Your Name" `
  -GitUserEmail "you@example.com"
```

With custom commit message:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\import-pix4d.ps1 `
  -ZipPath "C:\path\to\Export.zip" `
  -Customer "Brookland" `
  -Commit `
  -Push `
  -CommitMessage "Import Brookland March export"
```

With custom commit message + git identity:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\import-pix4d.ps1 `
  -ZipPath "C:\path\to\Export.zip" `
  -Customer "Brookland" `
  -Commit `
  -Push `
  -CommitMessage "Import Brookland March export" `
  -GitUserName "Your Name" `
  -GitUserEmail "you@example.com"
```

## 6) What The Importer Does

- Detects valid `B..._Boundary.shp` and `B..._Rx.shp` pairs
- Matches and imports each token as one app block
- Converts shapefiles to GeoJSON (WGS84)
- Writes:
  - `customers/<Customer>/blocks/<id>/block<id>boundary.geojson`
  - `customers/<Customer>/blocks/<id>/block<id>rx.geojson`
- Creates/updates `customers/<Customer>/blocks.json`
- Stores source token in `blocks.json` as `sourceToken`

## 7) Common Mistakes To Avoid

- Mixed tokens in pair:
  - `B01_Boundary.shp` with `B02_Rx.shp` (invalid)
- Spaces in token:
  - `B01 02_Rx.shp` (invalid)
- Missing pair:
  - Boundary exists, Rx missing (invalid)
- Non-numeric `zone` values in Rx
- Git identity not configured for commit (use `-GitUserName` / `-GitUserEmail` or set global git config)
- LF/CRLF warnings from git are usually non-blocking
