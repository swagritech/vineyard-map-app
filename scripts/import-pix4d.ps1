param(
  [Parameter(Mandatory = $false)]
  [string]$ZipPath,

  [Parameter(Mandatory = $true)]
  [string]$Customer,

  [string]$RepoRoot = ".",
  [switch]$SyncManifest,
  [switch]$DryRun,
  [switch]$Commit,
  [switch]$Push,
  [string]$CommitMessage = "",
  [string]$GitUserName = "",
  [string]$GitUserEmail = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-Ogr2Ogr {
  $candidates = @(
    "ogr2ogr",
    "C:\Program Files\QGIS 3.44.6\bin\ogr2ogr.exe",
    "C:\Program Files\QGIS 3.34.15\bin\ogr2ogr.exe",
    "C:\OSGeo4W\bin\ogr2ogr.exe"
  )

  foreach ($c in $candidates) {
    try {
      if ($c -eq "ogr2ogr") {
        $cmd = Get-Command ogr2ogr -ErrorAction Stop
        return $cmd.Source
      }
      if (Test-Path $c) { return $c }
    } catch {
      continue
    }
  }

  throw "Could not find ogr2ogr. Install QGIS/OSGeo4W and ensure ogr2ogr is available."
}

function Convert-NumsToToken([string]$nums) {
  # Turns a run of block numbers separated by spaces, "&", "-" or tabs into a
  # normalized token, e.g. "3&4" -> "B3-4", "2 1 12 11 10" -> "B2-1-12-11-10".
  $sep = [char[]]@([char]0x26, ' ', '-', "`t")
  $parts = $nums.Split($sep, [System.StringSplitOptions]::RemoveEmptyEntries)
  return ("B" + ($parts -join "-")).ToUpperInvariant()
}

function Parse-ExportName([string]$fileStem) {
  # 1) Strict protocol: B01_Boundary, B01-02-04_WestRun_Rx
  $strict = [regex]::Match($fileStem, '^(?<token>B\d+(?:-\d+)*)(?:_(?<label>[A-Za-z0-9-]+))?_(?<kind>Boundary|Rx)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if ($strict.Success) {
    return [pscustomobject]@{
      Token = $strict.Groups["token"].Value.ToUpperInvariant()
      Label = $strict.Groups["label"].Value
      Kind  = $strict.Groups["kind"].Value
    }
  }

  # 2) Native Pix4D block names, e.g.
  #    "NDVI - Block 5 3 zone_Boundary"
  #    "NDVI - Block 3&4 3 zone_Rx"
  #    "NDVI - Blocks 2 1 12 11 10 3zone_Boundary"
  $pix4d = [regex]::Match($fileStem, '^NDVI\s*-?\s*Blocks?\s+(?<nums>\d+(?:[\s&]+\d+)*)\s+\d+\s?zones?_(?<kind>Boundary|Rx)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if ($pix4d.Success) {
    return [pscustomobject]@{
      Token = Convert-NumsToToken $pix4d.Groups["nums"].Value
      Label = ""
      Kind  = $pix4d.Groups["kind"].Value
    }
  }

  # 2b) Native Pix4D wrapper around a vineyard's own block code, e.g.
  #     "NDVI - CHRBK04 3 zones_Rx" -> token "CHRBK04"
  #     (the Block-number form above is tried first, so Fishbone-style names
  #     never land here)
  $pix4dCode = [regex]::Match($fileStem, '^NDVI\s*-?\s*(?<code>.+?)\s*\d+\s*zones?_(?<kind>Boundary|Rx)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if ($pix4dCode.Success) {
    return [pscustomobject]@{
      Token = $pix4dCode.Groups["code"].Value.Trim()
      Label = ""
      Kind  = $pix4dCode.Groups["kind"].Value
    }
  }

  # 3) Legacy Pix4D names, e.g.
  #    "NDVI 101 102 104 307 Zones3_Rx"
  #    "NDVI 302 Zone3_Boundary"
  $legacy = [regex]::Match($fileStem, '^NDVI (?<nums>\d+(?: \d+)*) Zones?3_(?<kind>Boundary|Rx)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if ($legacy.Success) {
    return [pscustomobject]@{
      Token = Convert-NumsToToken $legacy.Groups["nums"].Value
      Label = ""
      Kind  = $legacy.Groups["kind"].Value
    }
  }

  # 4) Generic fallback: pair ANY "<stem>_Boundary" / "<stem>_Rx" by exact stem,
  #    so vineyards with their own block codes (e.g. "CHRBK04 - Cabernet") still
  #    import. Ids fall back to sequential; the raw stem becomes the name.
  $generic = [regex]::Match($fileStem, '^(?<token>.+?)\s*_(?<kind>Boundary|Rx)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if ($generic.Success) {
    return [pscustomobject]@{
      Token = $generic.Groups["token"].Value.Trim()
      Label = ""
      Kind  = $generic.Groups["kind"].Value
    }
  }

  return $null
}

function Get-DesiredIdFromToken([string]$token) {
  # Uses the first block number in the token as the app/folder id, so a single
  # block like "B5" imports as block 5 rather than a sequential counter.
  # Returns 0 when the token has no usable leading number.
  $first = ($token.TrimStart('B','b') -split '-')[0]
  $n = 0
  if ([int]::TryParse($first, [ref]$n) -and $n -gt 0) { return $n }
  return 0
}

function Get-TokenSortKey([string]$token) {
  # Numeric B-tokens sort by zero-padded numbers; non-numeric tokens (customer
  # block codes) sort as their own text.
  $keys = @()
  foreach ($part in @($token.TrimStart('B','b').Split('-') | Where-Object { $_ -ne '' })) {
    $n = 0
    if ([int]::TryParse($part, [ref]$n)) { $keys += ("{0:D4}" -f $n) } else { return $token }
  }
  return ($keys -join "-")
}

function Format-BlockName([string]$token) {
  # Turns a numeric token into a friendly display name, preserving the block
  # order from the source file: "B5" -> "Block 5", "B3-4" -> "Blocks 3 & 4",
  # "B2-1-12-11-10" -> "Blocks 2, 1, 12, 11 & 10". Non-numeric tokens
  # (customer block codes like "CHRBK04 - Cabernet") display as-is.
  $parts = @($token.TrimStart('B','b').Split('-') | Where-Object { $_ -ne '' })
  foreach ($p in $parts) {
    $n = 0
    if (-not [int]::TryParse($p, [ref]$n)) { return $token }
  }
  $parts = @($parts | ForEach-Object { [string][int]$_ })
  if ($parts.Count -le 1) { return "Block $($parts -join '')" }
  $head = ($parts[0..($parts.Count - 2)]) -join ", "
  $last = $parts[$parts.Count - 1]
  return "Blocks $head & $last"
}

function Normalize-DisplayName([string]$label, [string]$token) {
  # An explicit label (strict protocol) wins; otherwise build a friendly name
  # from the block numbers in the token.
  if (-not [string]::IsNullOrWhiteSpace($label)) {
    return ($label -replace "-", " ").Trim()
  }
  return Format-BlockName $token
}

function Save-Json($obj, [string]$path) {
  $json = $obj | ConvertTo-Json -Depth 100
  # ConvertTo-Json escapes &, <, >, ' as \uXXXX. These are safe as literals in
  # JSON, so unescape them to keep display names (e.g. "Blocks 3 & 4") readable.
  $json = $json -replace '\\u0026', '&' -replace '\\u003c', '<' -replace '\\u003e', '>' -replace '\\u0027', "'"
  [System.IO.File]::WriteAllText($path, $json + [Environment]::NewLine)
}

function Convert-ShpToGeoJson([string]$ogr2ogr, [string]$srcShp, [string]$dstGeoJson) {
  $dstDir = Split-Path -Parent $dstGeoJson
  if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir | Out-Null }

  if (Test-Path $dstGeoJson) { Remove-Item $dstGeoJson -Force }

  & $ogr2ogr `
    -f "GeoJSON" `
    -t_srs "EPSG:4326" `
    -lco "RFC7946=YES" `
    $dstGeoJson `
    $srcShp

  if ($LASTEXITCODE -ne 0) {
    throw "ogr2ogr failed converting '$srcShp' -> '$dstGeoJson'"
  }
}

function Invoke-Git([string[]]$GitArgs) {
  & git @GitArgs
  if ($LASTEXITCODE -ne 0) {
    throw "git command failed: git $($GitArgs -join ' ')"
  }
}

function Get-GitOutput([string[]]$GitArgs) {
  $out = & git @GitArgs
  if ($LASTEXITCODE -ne 0) {
    throw "git command failed: git $($GitArgs -join ' ')"
  }
  return ($out | Out-String).Trim()
}

function Commit-AndPushChanges(
  [string]$repoRootPath,
  [string]$customerName,
  [switch]$shouldCommit,
  [switch]$shouldPush,
  [string]$customMessage,
  [string]$gitUserName,
  [string]$gitUserEmail
) {
  Push-Location $repoRootPath
  try {
    $isRepo = Get-GitOutput -GitArgs @("rev-parse", "--is-inside-work-tree")
    if ($isRepo -ne "true") {
      throw "Repo root is not a git repository: $repoRootPath"
    }

    $customerPath = ("customers/{0}" -f $customerName)
    Invoke-Git -GitArgs @("add", "--", $customerPath)

    $hasStaged = (& git diff --cached --name-only -- $customerPath | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($hasStaged)) {
      Write-Host "No staged changes under $customerPath. Skipping commit/push."
      return
    }

    if ($shouldCommit) {
      $existingName = (& git config --get user.name | Out-String).Trim()
      $existingEmail = (& git config --get user.email | Out-String).Trim()

      if ([string]::IsNullOrWhiteSpace($existingName) -and -not [string]::IsNullOrWhiteSpace($gitUserName)) {
        Invoke-Git -GitArgs @("config", "user.name", $gitUserName)
        $existingName = $gitUserName
      }
      if ([string]::IsNullOrWhiteSpace($existingEmail) -and -not [string]::IsNullOrWhiteSpace($gitUserEmail)) {
        Invoke-Git -GitArgs @("config", "user.email", $gitUserEmail)
        $existingEmail = $gitUserEmail
      }

      if ([string]::IsNullOrWhiteSpace($existingName) -or [string]::IsNullOrWhiteSpace($existingEmail)) {
        throw "Git identity missing. Set it once with: git config --global user.name `"Your Name`" ; git config --global user.email `"you@example.com`" OR pass -GitUserName and -GitUserEmail to this script."
      }

      $msg = $customMessage
      if ([string]::IsNullOrWhiteSpace($msg)) {
        $msg = "Import Pix4D data for $customerName"
      }
      Invoke-Git -GitArgs @("commit", "-m", $msg)
      Write-Host ("Committed changes: {0}" -f $msg)
    } else {
      Write-Host "Commit flag not set. Changes are staged but not committed."
      return
    }

    if ($shouldPush) {
      $branch = Get-GitOutput -GitArgs @("branch", "--show-current")
      if ([string]::IsNullOrWhiteSpace($branch)) {
        throw "Could not determine current git branch."
      }
      Invoke-Git -GitArgs @("push", "origin", $branch)
      Write-Host ("Pushed to origin/{0}" -f $branch)
    }
  }
  finally {
    Pop-Location
  }
}

$repoRoot = (Resolve-Path $RepoRoot).Path

$customersRoot = Join-Path $repoRoot "customers"
$customerRoot = Join-Path $customersRoot $Customer
$blocksRoot = Join-Path $customerRoot "blocks"
$blocksJsonPath = Join-Path $customerRoot "blocks.json"

if (-not (Test-Path $customersRoot)) {
  throw "Not a vineyard-map-app repo root. Missing: $customersRoot"
}

if (-not (Test-Path $customerRoot)) {
  throw "Customer folder does not exist: $customerRoot"
}

# -SyncManifest rebuilds vineyard.json from existing blocks.json + files on disk;
# it skips the zip / ogr2ogr pipeline entirely (and never rewrites blocks.json).
if (-not $SyncManifest) {
  if ([string]::IsNullOrWhiteSpace($ZipPath)) {
    throw "-ZipPath is required unless -SyncManifest is specified."
  }
  $zipPath = (Resolve-Path $ZipPath).Path
  $ogr2ogrPath = Resolve-Ogr2Ogr

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("pix4d_ingest_" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $tmp | Out-Null

  try {
  [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $tmp)

  $shps = Get-ChildItem -Path $tmp -Recurse -File -Filter *.shp
  if (-not $shps) {
    throw "No .shp files found in zip."
  }

  $pairs = @{}
  foreach ($shp in $shps) {
    $parsed = Parse-ExportName $shp.BaseName
    if ($null -eq $parsed) { continue }

    if (-not $pairs.ContainsKey($parsed.Token)) {
      $pairs[$parsed.Token] = [ordered]@{
        Token = $parsed.Token
        Label = ""
        Boundary = $null
        Rx = $null
      }
    }

    if (-not [string]::IsNullOrWhiteSpace($parsed.Label)) {
      $pairs[$parsed.Token].Label = $parsed.Label
    }

    if ($parsed.Kind -ieq "Boundary") { $pairs[$parsed.Token].Boundary = $shp.FullName }
    if ($parsed.Kind -ieq "Rx") { $pairs[$parsed.Token].Rx = $shp.FullName }
  }

  if ($pairs.Count -eq 0) {
    throw "No export files matched naming protocol. Expected names like B01_Boundary.shp or B01-02-04_WestRun_Rx.shp"
  }

  $tokens = @($pairs.Keys | Sort-Object { Get-TokenSortKey $_ })

  foreach ($token in $tokens) {
    $p = $pairs[$token]
    if (-not $p.Boundary) { throw "Missing Boundary shapefile for token '$token'" }
    if (-not $p.Rx) { throw "Missing Rx shapefile for token '$token'" }
  }

  if (Test-Path $blocksJsonPath) {
    $blocksJson = Get-Content -Raw $blocksJsonPath | ConvertFrom-Json
  } else {
    $blocksJson = [pscustomobject]@{
      customer = $Customer
      defaultBlock = "1"
      blocks = @()
    }
  }

  if (-not $blocksJson.blocks) { $blocksJson | Add-Member -NotePropertyName blocks -NotePropertyValue @() -Force }
  if (-not $blocksJson.defaultBlock) { $blocksJson | Add-Member -NotePropertyName defaultBlock -NotePropertyValue "1" -Force }
  $blocksJson.customer = $Customer

  $existingByToken = @{}
  $usedIds = New-Object 'System.Collections.Generic.HashSet[int]'
  $maxId = 0
  foreach ($b in @($blocksJson.blocks)) {
    $idNum = 0
    [void][int]::TryParse([string]$b.id, [ref]$idNum)
    if ($idNum -gt $maxId) { $maxId = $idNum }
    if ($idNum -gt 0) { [void]$usedIds.Add($idNum) }

    if ($b.PSObject.Properties.Name -contains "sourceToken" -and -not [string]::IsNullOrWhiteSpace($b.sourceToken)) {
      $existingByToken[$b.sourceToken.ToUpperInvariant()] = $b
    }
  }

  # Migration helper:
  # If no sourceToken metadata exists yet and blocks are still generic "Block N",
  # map imported tokens onto existing IDs by sorted order to avoid duplicate IDs.
  if ($existingByToken.Count -eq 0) {
    $existing = @($blocksJson.blocks | Sort-Object { [int]$_.id })
    $hasGenericNames = $true
    foreach ($b in $existing) {
      if (-not ([string]$b.name -match '^Block\s+\d+$')) {
        $hasGenericNames = $false
        break
      }
    }

    if ($hasGenericNames -and $existing.Count -eq $tokens.Count) {
      for ($i = 0; $i -lt $tokens.Count; $i++) {
        $existingByToken[$tokens[$i].ToUpperInvariant()] = $existing[$i]
      }
    }
  }

  $touched = @()
  foreach ($token in $tokens) {
    $pair = $pairs[$token]
    $label = Normalize-DisplayName $pair.Label $token

    $blockEntry = $null
    if ($existingByToken.ContainsKey($token)) {
      $blockEntry = $existingByToken[$token]
    } else {
      $newId = Get-DesiredIdFromToken $token
      if ($newId -le 0 -or $usedIds.Contains($newId)) {
        # Block number unavailable (combined-block collision, or non-numeric):
        # fall back to the next free sequential id.
        $newId = $maxId + 1
        while ($usedIds.Contains($newId)) { $newId += 1 }
      }
      [void]$usedIds.Add($newId)
      if ($newId -gt $maxId) { $maxId = $newId }

      $blockEntry = [pscustomobject]@{
        id = [string]$newId
        name = $label
        sourceToken = $token
      }
      $blocksJson.blocks += $blockEntry
    }

    $blockEntry.name = $label
    if (-not ($blockEntry.PSObject.Properties.Name -contains "sourceToken")) {
      $blockEntry | Add-Member -NotePropertyName sourceToken -NotePropertyValue $token -Force
    } else {
      $blockEntry.sourceToken = $token
    }

    $blockId = [string]$blockEntry.id
    $blockDir = Join-Path $blocksRoot $blockId
    $boundaryOut = Join-Path $blockDir ("block{0}boundary.geojson" -f $blockId)
    $rxOut = Join-Path $blockDir ("block{0}rx.geojson" -f $blockId)

    $touched += [pscustomobject]@{
      Token = $token
      BlockId = $blockId
      Name = $label
      BoundaryIn = $pair.Boundary
      RxIn = $pair.Rx
      BoundaryOut = $boundaryOut
      RxOut = $rxOut
    }
  }

  $blocksJson.blocks = @(
    $blocksJson.blocks | Sort-Object { [int]$_.id }
  )

  # defaultBlock must reference a block that exists (ids are no longer
  # guaranteed to start at 1 now that they follow real block numbers).
  $blockIds = @($blocksJson.blocks | ForEach-Object { [string]$_.id })
  if ($blockIds.Count -gt 0 -and -not ($blockIds -contains [string]$blocksJson.defaultBlock)) {
    $blocksJson.defaultBlock = $blockIds[0]
  }

  if ($DryRun) {
    Write-Host "DRY RUN - no files changed."
  } else {
    foreach ($item in $touched) {
      Convert-ShpToGeoJson -ogr2ogr $ogr2ogrPath -srcShp $item.BoundaryIn -dstGeoJson $item.BoundaryOut
      Convert-ShpToGeoJson -ogr2ogr $ogr2ogrPath -srcShp $item.RxIn -dstGeoJson $item.RxOut
    }

    if (-not (Test-Path $customerRoot)) { New-Item -ItemType Directory -Path $customerRoot | Out-Null }
    if (-not (Test-Path $blocksRoot)) { New-Item -ItemType Directory -Path $blocksRoot | Out-Null }
    Save-Json $blocksJson $blocksJsonPath

    if ($Push -and -not $Commit) {
      throw "Push requires Commit. Use -Commit -Push together."
    }

    if ($Commit -or $Push) {
      Commit-AndPushChanges -repoRootPath $repoRoot -customerName $Customer -shouldCommit:$Commit -shouldPush:$Push -customMessage $CommitMessage -gitUserName $GitUserName -gitUserEmail $GitUserEmail
    }
  }

  Write-Host ""
  Write-Host "Ingest summary for customer '$Customer':"
  foreach ($item in $touched) {
    Write-Host ("  {0} -> block {1} ({2})" -f $item.Token, $item.BlockId, $item.Name)
  }
  Write-Host ""
  Write-Host ("blocks.json: {0}" -f $blocksJsonPath)
}
  finally {
    if (Test-Path $tmp) {
      Remove-Item -Recurse -Force $tmp
    }
  }
}

# ---------------------------------------------------------------------------
# v2 manifest generation (§4.2-§4.4). Runs for both zip imports and
# -SyncManifest. Metadata only: it reads geometry files for feature names but
# NEVER rewrites any .geojson (no ConvertTo-Json round-trip of geometry).
# Skipped on -DryRun so a dry run truly changes nothing.
# ---------------------------------------------------------------------------
if (-not $DryRun) {
  if (Test-Path $blocksJsonPath) {
    $blocksData = Get-Content -Raw $blocksJsonPath | ConvertFrom-Json
  } elseif ($SyncManifest) {
    # Boundaries-first onboarding: a brand-new vineyard may have boundaries but no
    # NDVI flights yet. Use an empty in-memory structure and do NOT write
    # blocks.json (it stays absent until a real zip import creates it).
    $blocksData = [pscustomobject]@{ customer = $Customer; defaultBlock = "1"; blocks = @() }
  } else {
    throw "Cannot build vineyard.json: blocks.json not found at $blocksJsonPath"
  }

  # --- Boundaries auto-detect: top level only, case-insensitive.
  #     Matches "<anything>_Boundaries.geojson" or bare "boundaries.geojson". ---
  $boundariesName = $null
  $boundaryFile = $null
  $boundaryCandidates = @(
    Get-ChildItem -Path $customerRoot -File |
      Where-Object { $_.Name -imatch '(^|_)boundaries\.geojson$' } |
      Sort-Object Name
  )
  if ($boundaryCandidates.Count -gt 0) {
    $boundaryFile = $boundaryCandidates[0]
    $boundariesName = $boundaryFile.Name
  }

  # --- Build blocks[] from the boundaries feature names (metadata only). ---
  # Arrays for 'numbers' are built inline here (never returned from a function)
  # so PowerShell 5.1 cannot unroll single-element arrays.
  $blockList = @()
  $blockKeysOrdered = @()

  if ($null -ne $boundaryFile) {
    $boundaryJson = Get-Content -Raw $boundaryFile.FullName | ConvertFrom-Json
    foreach ($f in @($boundaryJson.features)) {
      $featureName = ""
      if ($null -ne $f.properties -and ($f.properties.PSObject.Properties.Name -contains 'name')) {
        $featureName = [string]$f.properties.name
      }

      # Block names as typed in the drawing tool. Vineyards label differently,
      # so patterns are tried in order (first match wins); anything unmatched
      # still becomes a block under its raw name (never drop a feature):
      #   P1  "Block 5 Cab Sauv - 1.228 ha"        Block-number convention
      #   P2  "CHRBK04 - Chardonnay - 1.884 ha"    customer block codes
      #   P3  "North Paddock - 2.1 ha"             any name + area, no variety
      $key = $featureName
      $parsedVariety = ""
      $areaHa = $null
      $numbers = @()
      $displayName = $featureName
      $patternMatched = $false

      $p1 = [regex]::Match($featureName, '^Block\s+(?<key>\d+[A-Za-z]?(?:\s*[/&,-]\s*\d+[A-Za-z]?)*)\s*(?<label>[^-]*?)\s*-\s*(?<area>[\d.]+)\s*ha\s*$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
      if ($p1.Success) {
        $key = ($p1.Groups['key'].Value -replace '\s+', '')
        $parsedVariety = $p1.Groups['label'].Value.Trim()
        $areaHa = [double]::Parse($p1.Groups['area'].Value, [System.Globalization.CultureInfo]::InvariantCulture)
        $displayName = "Block " + $key
        $patternMatched = $true
      } else {
        $p2 = [regex]::Match($featureName, '^(?<key>[A-Za-z0-9/&_.]+)\s*-\s*(?<label>.+?)\s*-\s*(?<area>[\d.]+)\s*ha\s*$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($p2.Success) {
          $key = $p2.Groups['key'].Value.Trim()
          $parsedVariety = $p2.Groups['label'].Value.Trim()
          $areaHa = [double]::Parse($p2.Groups['area'].Value, [System.Globalization.CultureInfo]::InvariantCulture)
          $displayName = $key
          $patternMatched = $true
        } else {
          $p3 = [regex]::Match($featureName, '^(?<key>.+?)\s*-\s*(?<area>[\d.]+)\s*ha\s*$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
          if ($p3.Success) {
            $key = $p3.Groups['key'].Value.Trim()
            $areaHa = [double]::Parse($p3.Groups['area'].Value, [System.Globalization.CultureInfo]::InvariantCulture)
            $displayName = $key
            $patternMatched = $true
          }
        }
      }

      if ($patternMatched) {
        # Digit runs in the key, for display/sorting only ("4/5" -> 4,5;
        # "CHRBK04" -> 4). Raw-name fallbacks get none (they would be noise).
        $numbers = @([regex]::Matches($key, '\d+') | ForEach-Object { [int]$_.Value })
      }

      $block = [ordered]@{
        key = $key
        featureName = $featureName
        displayName = $displayName
        numbers = $numbers
        areaHa = $areaHa
        variety = $parsedVariety
        notes = ""
      }
      $blockList += $block
      $blockKeysOrdered += $key
    }
  }

  # --- attributes.json: scaffold when absent (boundaries present), never
  #     overwrite an existing file, then merge into blocks[] every run. ---
  $attributesPath = Join-Path $customerRoot "attributes.json"
  $attributes = $null
  if ($null -ne $boundariesName) {
    if (-not (Test-Path $attributesPath)) {
      # Pre-filled with the varieties parsed from the boundary names; edit this
      # file only to correct or override them.
      $scaffold = [ordered]@{}
      foreach ($block in $blockList) {
        $scaffold[[string]$block['key']] = [ordered]@{ variety = [string]$block['variety']; notes = "" }
      }
      Save-Json $scaffold $attributesPath
      Write-Host ("Scaffolded attributes.json: {0}" -f $attributesPath)
    }
    $attributes = Get-Content -Raw $attributesPath | ConvertFrom-Json

    foreach ($block in $blockList) {
      $attrEntry = $null
      $ap = $attributes.PSObject.Properties | Where-Object { $_.Name -eq $block['key'] }
      if ($ap) { $attrEntry = $ap.Value }
      if ($null -ne $attrEntry) {
        # Copy known + unknown fields (forward compatibility). Empty strings do
        # not override, so a blank attributes entry keeps the name-parsed variety.
        foreach ($prop in $attrEntry.PSObject.Properties) {
          $v = $prop.Value
          if ($v -is [string] -and [string]::IsNullOrWhiteSpace($v)) { continue }
          $block[$prop.Name] = $v
        }
      }
    }
  }

  # --- Build surveys[] from blocks.json (id + sourceToken). ---
  $surveyList = @()
  foreach ($b in @($blocksData.blocks)) {
    $sid = [string]$b.id
    $token = ""
    if (($b.PSObject.Properties.Name -contains 'sourceToken') -and -not [string]::IsNullOrWhiteSpace([string]$b.sourceToken)) {
      $token = [string]$b.sourceToken
    } else {
      $token = "B" + $sid
    }
    $token = $token.ToUpperInvariant()

    $sNumbers = @(
      $token.TrimStart('B','b').Split('-') |
        Where-Object { $_ -ne '' } |
        ForEach-Object { $n = 0; if ([int]::TryParse($_, [ref]$n)) { $n } }
    )

    $survey = [ordered]@{
      id = $sid
      token = $token
      displayName = Format-BlockName $token
      numbers = $sNumbers
      boundary = "blocks/$sid/block${sid}boundary.geojson"
      rx = "blocks/$sid/block${sid}rx.geojson"
    }
    $surveyList += $survey
  }

  # --- Assemble manifest. ---
  $manifest = [ordered]@{
    schemaVersion = 2
    customer = $Customer
    updatedUtc = ""
    boundaries = $boundariesName
    blocks = @($blockList)
    surveys = @($surveyList)
  }

  # --- Idempotent timestamp: reuse the previous updatedUtc when nothing else
  #     changed, so re-running -SyncManifest produces zero diff. ---
  $vineyardPath = Join-Path $customerRoot "vineyard.json"
  $stamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  $existingRaw = $null
  $prevStamp = $null
  if (Test-Path $vineyardPath) {
    $existingRaw = Get-Content -Raw $vineyardPath
    try {
      $existingObj = $existingRaw | ConvertFrom-Json
      if ($existingObj.PSObject.Properties.Name -contains 'updatedUtc') {
        $prevStamp = [string]$existingObj.updatedUtc
      }
    } catch {
      $prevStamp = $null
    }
  }

  if ($null -ne $prevStamp) {
    $manifest.updatedUtc = $prevStamp
    # Reconstruct exactly what Save-Json would write, to compare byte-for-byte.
    $candJson = $manifest | ConvertTo-Json -Depth 100
    $candJson = $candJson -replace '\\u0026', '&' -replace '\\u003c', '<' -replace '\\u003e', '>' -replace '\\u0027', "'"
    $candText = $candJson + [Environment]::NewLine
    if ($candText -ne $existingRaw) {
      $manifest.updatedUtc = $stamp
    }
  } else {
    $manifest.updatedUtc = $stamp
  }

  Save-Json $manifest $vineyardPath

  # --- Variety gap summary (only for customers with boundaries). ---
  if ($null -ne $boundariesName) {
    $keyHeader = "key"
    $nameHeader = "feature name"
    $kw = $keyHeader.Length
    $nw = $nameHeader.Length
    foreach ($block in $blockList) {
      if (([string]$block['key']).Length -gt $kw) { $kw = ([string]$block['key']).Length }
      if (([string]$block['featureName']).Length -gt $nw) { $nw = ([string]$block['featureName']).Length }
    }

    Write-Host ""
    Write-Host ("Block attributes for '{0}':" -f $Customer)
    Write-Host ("  {0}  {1}  {2}" -f $keyHeader.PadRight($kw), $nameHeader.PadRight($nw), "variety")
    foreach ($block in $blockList) {
      $variety = [string]$block['variety']
      if ([string]::IsNullOrWhiteSpace($variety)) { $variety = "(empty - fill in attributes.json)" }
      Write-Host ("  {0}  {1}  {2}" -f ([string]$block['key']).PadRight($kw), ([string]$block['featureName']).PadRight($nw), $variety)
    }
  }

  Write-Host ""
  $boundariesLabel = "null"
  if ($null -ne $boundariesName) { $boundariesLabel = $boundariesName }
  Write-Host ("vineyard.json: {0}" -f $vineyardPath)
  Write-Host ("  schemaVersion 2  boundaries: {0}  blocks: {1}  surveys: {2}" -f $boundariesLabel, $blockList.Count, $surveyList.Count)
}
