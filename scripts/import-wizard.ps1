param(
  [string]$RepoRoot = ""   # default: resolve to the script's parent directory's parent
)

# ===========================================================================
# NDVI Import Wizard (docs/WIZARD_SPEC.md).
#
# THIN interactive wrapper: all conversion/manifest logic lives in
# scripts\import-pix4d.ps1, which this script always invokes as a child
# powershell process (never re-implemented here). This script only gathers
# inputs, interviews gaps, and publishes via scoped git commands.
# ===========================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Low-level input helpers.
#
# Read-Host's own built-in prompt text does not reliably appear when stdin is
# redirected (piped scripted answers), even though the VALUE it reads still
# works correctly. So every prompt is printed explicitly via Write-Host first
# (guaranteeing it is always visible/logged), then a bare Read-Host reads the
# answer. When redirected input runs out, Read-Host returns $null; we turn
# that into a clean terminating error so the top-level try/catch can end the
# wizard gracefully instead of crashing on a StrictMode null-property error.
# ---------------------------------------------------------------------------
function Read-Answer([string]$Prompt) {
  Write-Host -NoNewline ($Prompt + ": ")
  $v = Read-Host
  if ($null -eq $v) {
    Write-Host ""
    throw "Input ended before the wizard finished (no more answers were provided)."
  }
  return $v
}

# Every [Y/n] prompt: Enter = Y. Include the literal "[Y/n]" in $Prompt text.
# Anything that isn't clearly Y or N re-prompts - a stray keypress must never
# count as consent (these prompts gate publishing to the live site).
function Read-YesNo([string]$Prompt) {
  while ($true) {
    $ans = Read-Answer $Prompt
    $t = $ans.Trim()
    if ($t.Length -eq 0) { return $true }
    $c = $t.Substring(0, 1).ToUpperInvariant()
    if ($c -eq "Y") { return $true }
    if ($c -eq "N") { return $false }
    Write-Host "Please answer Y or N." -ForegroundColor Yellow
  }
}

# File-open dialog for interactive use; falls back to reading a path from the
# next stdin line when input is redirected (a GUI dialog cannot be driven from
# piped input, so headless tests supply the path the same way they supply
# every other answer - see docs/WIZARD_SPEC.md principle 3, "testable
# headlessly"). Real double-click usage always gets the real dialog.
function Select-FileViaDialogOrStdin {
  param(
    [string]$Title,
    [string]$Filter,
    [string]$InitialDirectory,
    [string]$StdinPrompt
  )

  if ([Console]::IsInputRedirected) {
    $p = Read-Answer $StdinPrompt
    $p = $p.Trim().Trim('"')
    if ($p.Length -eq 0) { return $null }
    return $p
  }

  Add-Type -AssemblyName System.Windows.Forms | Out-Null
  $dlg = New-Object System.Windows.Forms.OpenFileDialog
  $dlg.Title = $Title
  $dlg.Filter = $Filter
  if (Test-Path $InitialDirectory) { $dlg.InitialDirectory = $InitialDirectory }
  $result = $dlg.ShowDialog()
  if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
    return $dlg.FileName
  }
  return $null
}

# ---------------------------------------------------------------------------
# JSON helper - replicates import-pix4d.ps1's Save-Json un-escaping exactly
# (& < > ' are written literally, not as \uXXXX), with a trailing newline.
# ---------------------------------------------------------------------------
function Write-JsonFile($Object, [string]$Path) {
  $json = $Object | ConvertTo-Json -Depth 100
  $json = $json -replace '\\u0026', '&' -replace '\\u003c', '<' -replace '\\u003e', '>' -replace '\\u0027', "'"
  [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine)
}

# ---------------------------------------------------------------------------
# Child-process helper: always invokes import-pix4d.ps1 (never re-implemented
# here), always passing -RepoRoot, and checks $LASTEXITCODE so callers can too.
#
# IMPORTANT: this must be called as a bare statement, NEVER as
# `$x = Invoke-Importer ...`. Capturing a function's return value in PowerShell
# also captures everything the function wrote to the success stream during its
# execution - including the nested child process's entire stdout - which would
# both swallow the importer's "verbatim" output and corrupt the exit-code
# check (comparing a mixed text+int array against 0 is not the same as
# comparing the exit code against 0). The exit code is exposed via
# $script:LastImporterExitCode instead, which callers read afterward.
# ---------------------------------------------------------------------------
function Invoke-Importer([string[]]$ImporterArgs) {
  $importerScript = Join-Path $RepoRoot "scripts\import-pix4d.ps1"
  $displayParts = @($ImporterArgs | ForEach-Object {
    if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
  })
  Write-Host ("> import-pix4d.ps1 {0}" -f ($displayParts -join " "))
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $importerScript @ImporterArgs
  $script:LastImporterExitCode = $LASTEXITCODE
}

# ---------------------------------------------------------------------------
# Environment check (§6.0).
# ---------------------------------------------------------------------------
function Test-Ogr2Ogr {
  $candidates = @(
    "ogr2ogr",
    "C:\Program Files\QGIS 3.44.6\bin\ogr2ogr.exe",
    "C:\Program Files\QGIS 3.34.15\bin\ogr2ogr.exe",
    "C:\OSGeo4W\bin\ogr2ogr.exe"
  )
  foreach ($c in $candidates) {
    if ($c -eq "ogr2ogr") {
      $cmd = Get-Command ogr2ogr -ErrorAction SilentlyContinue
      if ($cmd) { return $cmd.Source }
    } elseif (Test-Path $c) {
      return $c
    }
  }
  return $null
}

function Show-EnvironmentReport {
  Write-Host ""
  Write-Host "Environment check:" -ForegroundColor Green

  $ogrPath = Test-Ogr2Ogr
  $script:OgrAvailable = [bool]$ogrPath
  if ($script:OgrAvailable) {
    Write-Host ("  ogr2ogr: found ({0})" -f $ogrPath)
  } else {
    Write-Host "  ogr2ogr: NOT FOUND - zip imports will fail until QGIS is installed" -ForegroundColor Yellow
  }

  $gitCmd = Get-Command git -ErrorAction SilentlyContinue
  $gitUserName = ""
  $gitUserEmail = ""
  $isWorkTree = $false
  if ($gitCmd) {
    # These probes are EXPECTED to fail (with stderr output) when $RepoRoot is
    # not a git repository or has no identity configured - that is a normal,
    # informational outcome here, not an error. Under
    # $ErrorActionPreference = "Stop", PowerShell 5.1 turns a native command's
    # stderr output into a terminating error even when redirected to $null, so
    # temporarily relax it around just these probes.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    try {
      $gitUserName = ((& git -C $RepoRoot config --get user.name 2>$null) | Out-String).Trim()
      $gitUserEmail = ((& git -C $RepoRoot config --get user.email 2>$null) | Out-String).Trim()
      $wt = ((& git -C $RepoRoot rev-parse --is-inside-work-tree 2>$null) | Out-String).Trim()
    } finally {
      $ErrorActionPreference = $prevEap
    }
    $isWorkTree = ($wt -eq "true")
  }
  $script:IsWorkTree = $isWorkTree
  $gitIdentitySet = (-not [string]::IsNullOrWhiteSpace($gitUserName)) -and (-not [string]::IsNullOrWhiteSpace($gitUserEmail))
  $script:GitIdentitySet = $gitIdentitySet

  if (-not $gitCmd) {
    Write-Host "  git: NOT FOUND - publishing will be disabled" -ForegroundColor Yellow
  } elseif (-not $isWorkTree) {
    Write-Host "  git: found, but this folder is not a git repository - publishing will be disabled" -ForegroundColor Yellow
  } elseif (-not $gitIdentitySet) {
    Write-Host "  git: found, but user.name/user.email is not set - publishing will be disabled" -ForegroundColor Yellow
  } else {
    Write-Host ("  git: found (identity: {0} <{1}>)" -f $gitUserName, $gitUserEmail)
  }

  $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
  $script:NodeAvailable = [bool]$nodeCmd
  if ($script:NodeAvailable) {
    Write-Host "  node: found (coverage check available)"
  } else {
    Write-Host "  node: not found (coverage check will be skipped)" -ForegroundColor Yellow
  }

  $script:PublishEnabled = $isWorkTree -and $gitIdentitySet
}

# ---------------------------------------------------------------------------
# Customer selection (§4, shared step).
# ---------------------------------------------------------------------------
function Read-NewVineyardName {
  $reserved = @("customers", "icons", "images", "favicon.ico", "manifest.webmanifest", "service-worker.js")
  while ($true) {
    $name = Read-Answer "New vineyard name (letters and numbers only, Enter to cancel)"
    $name = $name.Trim()
    if ($name.Length -eq 0) {
      return $null
    }
    if ($name -notmatch '^[A-Za-z0-9]+$') {
      Write-Host "Names may only contain letters and numbers. Try again." -ForegroundColor Yellow
      continue
    }
    if ($reserved -contains $name) {
      Write-Host ("'{0}' is a reserved name. Choose another." -f $name) -ForegroundColor Yellow
      continue
    }
    return $name
  }
}

function Select-Customer {
  $custRoot = Join-Path $RepoRoot "customers"
  $dirs = @(Get-ChildItem -Path $custRoot -Directory | Sort-Object Name)

  while ($true) {
    Write-Host ""
    Write-Host "Select a vineyard:" -ForegroundColor Green
    for ($i = 0; $i -lt $dirs.Count; $i++) {
      Write-Host ("  {0}) {1}" -f ($i + 1), $dirs[$i].Name)
    }
    Write-Host "  N) New vineyard..."

    $choice = (Read-Answer "Choice").Trim()

    if ($choice.ToUpperInvariant() -eq "N") {
      $name = Read-NewVineyardName
      if ($null -eq $name) { continue }
      $newDir = Join-Path $custRoot $name
      New-Item -ItemType Directory -Path $newDir -Force | Out-Null
      Write-Host ("Created customers\{0}\" -f $name) -ForegroundColor Green
      Write-Host ("Future URL: https://maps.swagritech.com.au/{0}/" -f $name) -ForegroundColor Green
      return $name
    }

    $idx = 0
    if ([int]::TryParse($choice, [ref]$idx) -and $idx -ge 1 -and $idx -le $dirs.Count) {
      return $dirs[$idx - 1].Name
    }

    Write-Host "Please enter a number from the list, or N for a new vineyard." -ForegroundColor Yellow
  }
}

# ---------------------------------------------------------------------------
# §6.1 Variety interview.
# ---------------------------------------------------------------------------
function Set-AttributeVariety([string]$AttributesPath, [string]$Key, [string]$Variety) {
  if (Test-Path $AttributesPath) {
    $attrs = Get-Content -Raw $AttributesPath | ConvertFrom-Json
  } else {
    $attrs = New-Object PSObject
  }

  $existingProp = $attrs.PSObject.Properties | Where-Object { $_.Name -eq $Key }
  if ($existingProp) {
    $entry = $existingProp.Value
    if ($entry.PSObject.Properties.Name -contains "variety") {
      $entry.variety = $Variety
    } else {
      $entry | Add-Member -NotePropertyName "variety" -NotePropertyValue $Variety -Force
    }
  } else {
    $entry = [ordered]@{ variety = $Variety }
    $attrs | Add-Member -NotePropertyName $Key -NotePropertyValue $entry -Force
  }

  Write-JsonFile $attrs $AttributesPath
}

function Invoke-VarietyInterview([string]$Customer) {
  $commonGrapes = @(
    "Cabernet Sauvignon", "Cab Sauv", "Cab Franc", "Cabernet Franc", "Shiraz", "Merlot",
    "Malbec", "Petit Verdot", "Tempranillo", "Grenache", "Mataro", "Pinot Noir", "Pinot",
    "Pinot Gris", "Sangiovese", "Nebbiolo", "Zinfandel", "Chardonnay", "Sauvignon Blanc",
    "Semillon", "Chenin Blanc", "Riesling", "Vermentino", "Viognier", "Muscat"
  )

  $customerRoot = Join-Path $RepoRoot "customers\$Customer"
  $vineyardPath = Join-Path $customerRoot "vineyard.json"
  if (-not (Test-Path $vineyardPath)) { return }

  $manifest = Get-Content -Raw $vineyardPath | ConvertFrom-Json
  if ($null -eq $manifest.boundaries) { return }

  $gaps = @($manifest.blocks | Where-Object { [string]::IsNullOrEmpty([string]$_.variety) })

  Write-Host ""
  if ($gaps.Count -eq 0) {
    Write-Host "No variety gaps - every block already has a variety." -ForegroundColor Green
    return
  }

  Write-Host ("Variety check for '{0}':" -f $Customer) -ForegroundColor Green
  $attributesPath = Join-Path $customerRoot "attributes.json"
  $answered = $false

  foreach ($block in $gaps) {
    $key = [string]$block.key
    $displayName = [string]$block.displayName

    while ($true) {
      $ans = Read-Answer ("Variety for {0} (Enter to skip)" -f $displayName)
      $trimmed = $ans.Trim()
      if ($trimmed.Length -eq 0) { break }

      $accepted = $false
      if ($commonGrapes -contains $trimmed) {
        $accepted = $true
      } else {
        $keep = Read-YesNo ("`"{0}`" isn't in the common grape list - keep it as typed? [Y/n]" -f $trimmed)
        if ($keep) { $accepted = $true }
      }

      if ($accepted) {
        Set-AttributeVariety -AttributesPath $attributesPath -Key $key -Variety $trimmed
        $answered = $true
        break
      }
      # else: loop back and re-prompt this same block.
    }
  }

  if ($answered) {
    Write-Host ""
    Write-Host "Refreshing the manifest with your answers..." -ForegroundColor Green
    Invoke-Importer -ImporterArgs @("-SyncManifest", "-Customer", $Customer, "-RepoRoot", $RepoRoot)
    if ($script:LastImporterExitCode -ne 0) {
      Write-Host "Warning: re-sync after variety answers did not finish cleanly (see output above)." -ForegroundColor Yellow
    }
  }
}

# ---------------------------------------------------------------------------
# §6.2 Zone sanity scan (informational, regex-only, never parses/modifies).
# ---------------------------------------------------------------------------
function Invoke-ZoneScan([string]$Customer) {
  $customerRoot = Join-Path $RepoRoot "customers\$Customer"
  $blocksFolder = Join-Path $customerRoot "blocks"
  if (-not (Test-Path $blocksFolder)) { return }

  $rxFiles = @(Get-ChildItem -Path $blocksFolder -Recurse -File -Filter "*rx.geojson" -ErrorAction SilentlyContinue)
  foreach ($rf in $rxFiles) {
    $text = Get-Content -Raw -Path $rf.FullName
    $zoneMatches = [regex]::Matches($text, '"zone"\s*:\s*(-?\d+)')
    $badValues = @()
    foreach ($m in $zoneMatches) {
      $v = [int]$m.Groups[1].Value
      if ($v -lt 1 -or $v -gt 3) { $badValues += $v }
    }
    if ($badValues.Count -gt 0) {
      $rel = $rf.FullName.Substring($customerRoot.Length).TrimStart('\', '/')
      $vals = (@($badValues | Select-Object -Unique)) -join ", "
      Write-Host ("Warning: {0} has out-of-range zone value(s): {1} (expected 1-3)" -f $rel, $vals) -ForegroundColor Yellow
    }
  }
}

# ---------------------------------------------------------------------------
# §6.3 Missing-pair sanity (informational).
# ---------------------------------------------------------------------------
function Invoke-MissingPairScan([string]$Customer) {
  $customerRoot = Join-Path $RepoRoot "customers\$Customer"
  $vineyardPath = Join-Path $customerRoot "vineyard.json"
  if (-not (Test-Path $vineyardPath)) { return }
  $manifest = Get-Content -Raw $vineyardPath | ConvertFrom-Json

  foreach ($survey in @($manifest.surveys)) {
    $boundaryRel = [string]$survey.boundary
    $rxRel = [string]$survey.rx
    $boundaryFull = Join-Path $customerRoot ($boundaryRel -replace '/', '\')
    $rxFull = Join-Path $customerRoot ($rxRel -replace '/', '\')
    if (-not (Test-Path $boundaryFull)) {
      Write-Host ("Warning: survey {0} is missing its boundary file: {1}" -f $survey.token, $boundaryRel) -ForegroundColor Yellow
    }
    if (-not (Test-Path $rxFull)) {
      Write-Host ("Warning: survey {0} is missing its rx file: {1}" -f $survey.token, $rxRel) -ForegroundColor Yellow
    }
  }
}

# ---------------------------------------------------------------------------
# §6.4 Coverage report (informational, Node only).
# ---------------------------------------------------------------------------
function Invoke-CoverageReport([string]$Customer) {
  Write-Host ""
  if (-not $script:NodeAvailable) {
    Write-Host "(coverage check skipped - Node not installed)"
    return
  }
  $checkScript = Join-Path $RepoRoot "scripts\check-coverage.mjs"
  if (-not (Test-Path $checkScript)) { return }
  & node $checkScript $RepoRoot $Customer
}

# ---------------------------------------------------------------------------
# §8 Publish step.
# ---------------------------------------------------------------------------
function Invoke-PublishStep([string]$Customer, [string]$FlowLabel) {
  Write-Host ""
  if (-not $script:PublishEnabled) {
    if (-not $script:IsWorkTree) {
      Write-Host "Publish is turned off: this folder is not a git repository." -ForegroundColor Yellow
    } else {
      Write-Host "Publish is turned off: git user.name/user.email is not configured." -ForegroundColor Yellow
    }
    return
  }

  $customerPathspec = "customers/$Customer"
  # --untracked-files=all: a brand-new customer is one fully-untracked folder,
  # which git otherwise collapses to a single "customers/<C>/" line that the
  # per-file filter below would not recognise (real bug: first Rosabrook
  # publish silently reported "Nothing new to publish").
  $statusOut = @(& git -C $RepoRoot status --porcelain --untracked-files=all -- $customerPathspec)
  $statusOut = @($statusOut | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

  # Only §8's publishable paths count as changes. Untracked raw-source folders
  # (e.g. "customers/Fishbone/Fishbone NW/") also appear in git status under the
  # customer path and must be ignored, never offered for publishing.
  $publishablePaths = @($statusOut | ForEach-Object {
    $p = $_
    if ($p.Length -gt 3) { $p = $p.Substring(3) }
    if ($p -match '^(.*) -> (.*)$') { $p = $matches[2] }
    $p.Trim('"')
  } | Where-Object {
    ($_ -eq "customers/$Customer/vineyard.json") -or
    ($_ -eq "customers/$Customer/attributes.json") -or
    ($_ -eq "customers/$Customer/blocks.json") -or
    ($_ -like "customers/$Customer/blocks/*") -or
    ($_ -eq "customers/$Customer/${Customer}_Boundaries.geojson")
  })

  if ($publishablePaths.Count -eq 0) {
    Write-Host "Nothing new to publish."
    return
  }

  Write-Host "Changed files:"
  foreach ($p in $publishablePaths) {
    Write-Host ("  {0}" -f $p)
  }

  $publish = Read-YesNo "Publish these to the live map now? [Y/n]"
  if (-not $publish) {
    Write-Host "Saved locally, not published. Run the wizard again (option 3) to publish." -ForegroundColor Yellow
    return
  }

  $candidatePaths = @(
    "customers/$Customer/vineyard.json",
    "customers/$Customer/attributes.json",
    "customers/$Customer/blocks.json",
    "customers/$Customer/blocks",
    "customers/$Customer/${Customer}_Boundaries.geojson"
  )
  foreach ($p in $candidatePaths) {
    $full = Join-Path $RepoRoot ($p -replace '/', '\')
    if (Test-Path $full) {
      & git -C $RepoRoot add -- $p
    }
  }

  $commitMessages = @{
    "Flow1" = "Import NDVI for $Customer"
    "Flow2" = "Update $Customer block boundaries"
    "Flow3" = "Update $Customer block attributes"
  }
  $msg = $commitMessages[$FlowLabel]

  & git -C $RepoRoot commit -m $msg
  if ($LASTEXITCODE -ne 0) {
    Write-Host "Commit failed - see output above." -ForegroundColor Red
    return
  }

  $branch = ((& git -C $RepoRoot branch --show-current) | Out-String).Trim()
  & git -C $RepoRoot push origin $branch
  if ($LASTEXITCODE -eq 0) {
    Write-Host ("Live in ~1 minute: https://maps.swagritech.com.au/{0}/" -f $Customer) -ForegroundColor Green
  } else {
    Write-Host "Push failed. Your changes are committed locally but not published." -ForegroundColor Red
    Write-Host "Run the wizard again (option 3) to retry the push." -ForegroundColor Red
  }
}

function Invoke-GapInterviewAndPublish([string]$Customer, [string]$FlowLabel) {
  # A missing boundaries file is itself a gap: NDVI flights are often combined
  # groupings, but the drawn boundaries are the per-block truth - without them
  # the map has no per-block names/varieties and GPS can't announce crossings.
  $customerRoot = Join-Path $RepoRoot "customers\$Customer"
  $boundariesPresent = @(
    Get-ChildItem -Path $customerRoot -File -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -imatch '(^|_)boundaries\.geojson$' }
  )
  if ($boundariesPresent.Count -eq 0) {
    Write-Host ""
    Write-Host ("Gap: no block boundaries file is loaded for {0}." -f $Customer) -ForegroundColor Yellow
    Write-Host "The map will show NDVI flight areas only - no per-block names, varieties, or GPS block announcements."
    $loadNow = Read-YesNo "Load a boundaries GeoJSON now? [Y/n]"
    if ($loadNow) {
      Invoke-BoundariesLoad -Customer $Customer
      if (-not $script:BoundariesLoadOk) {
        Write-Host "You can load it any time: wizard option 2." -ForegroundColor Yellow
      }
    } else {
      Write-Host "You can load it any time: wizard option 2." -ForegroundColor Yellow
    }
  }

  Invoke-VarietyInterview -Customer $Customer
  Invoke-ZoneScan -Customer $Customer
  Invoke-MissingPairScan -Customer $Customer
  Invoke-CoverageReport -Customer $Customer
  Invoke-PublishStep -Customer $Customer -FlowLabel $FlowLabel
}

# ---------------------------------------------------------------------------
# §5.1 Flow 1 - Import an NDVI export.
# ---------------------------------------------------------------------------
function Invoke-Flow1 {
  if (-not $script:OgrAvailable) {
    Write-Host ""
    Write-Host "Cannot import zips: ogr2ogr/QGIS was not found. Install QGIS, then try again." -ForegroundColor Yellow
    return
  }

  $customer = Select-Customer
  if ([string]::IsNullOrWhiteSpace($customer)) { return }

  $downloads = Join-Path $env:USERPROFILE "Downloads"
  $zipPath = Select-FileViaDialogOrStdin -Title "Choose the Pix4D export zip" -Filter "Zip files (*.zip)|*.zip" `
    -InitialDirectory $downloads -StdinPrompt "Path to the Pix4D export zip (Enter to cancel)"
  if ([string]::IsNullOrWhiteSpace($zipPath)) {
    Write-Host "Cancelled. Back to the main menu." -ForegroundColor Yellow
    return
  }

  Write-Host ""
  Write-Host ("Dry run for '{0}'..." -f $customer) -ForegroundColor Green
  $dryArgs = @("-ZipPath", $zipPath, "-Customer", $customer, "-RepoRoot", $RepoRoot, "-DryRun")
  Invoke-Importer -ImporterArgs $dryArgs
  if ($script:LastImporterExitCode -ne 0) {
    Write-Host ""
    Write-Host "Dry run failed - nothing was changed. See docs/EXPORT_PROTOCOL.md for naming rules." -ForegroundColor Red
    return
  }

  Write-Host ""
  $go = Read-YesNo "Does the block mapping look right? Convert now [Y/n]"
  if (-not $go) {
    Write-Host "Cancelled. Nothing changed." -ForegroundColor Yellow
    return
  }

  Write-Host ""
  Write-Host ("Converting for '{0}'..." -f $customer) -ForegroundColor Green
  $liveArgs = @("-ZipPath", $zipPath, "-Customer", $customer, "-RepoRoot", $RepoRoot)
  Invoke-Importer -ImporterArgs $liveArgs
  if ($script:LastImporterExitCode -ne 0) {
    Write-Host ""
    Write-Host "Import failed - files were NOT published." -ForegroundColor Red
    Write-Host "See docs/EXPORT_PROTOCOL.md for naming rules." -ForegroundColor Red
    return
  }

  Invoke-GapInterviewAndPublish -Customer $customer -FlowLabel "Flow1"
}

# ---------------------------------------------------------------------------
# §5.2 Flow 2 - Update the boundaries file.
# ---------------------------------------------------------------------------
# Shared boundaries loader: file pick -> preview -> replace confirm -> copy to
# canonical name -> duplicate cleanup -> manifest sync. Used by Flow 2 and by
# the boundaries gap check inside every gap interview.
# IMPORTANT: call as a bare statement and read $script:BoundariesLoadOk after -
# capturing the call would also capture the nested importer's stdout (same
# trap as Invoke-Importer).
function Invoke-BoundariesLoad([string]$Customer) {
  $script:BoundariesLoadOk = $false
  $customerRoot = Join-Path $RepoRoot "customers\$Customer"
  $downloads = Join-Path $env:USERPROFILE "Downloads"
  $srcPath = Select-FileViaDialogOrStdin -Title "Choose the boundaries GeoJSON" -Filter "GeoJSON (*.geojson)|*.geojson" `
    -InitialDirectory $downloads -StdinPrompt "Path to the boundaries GeoJSON (Enter to cancel)"
  if ([string]::IsNullOrWhiteSpace($srcPath)) {
    Write-Host "Cancelled - no boundaries loaded." -ForegroundColor Yellow
    return
  }
  if (-not (Test-Path $srcPath)) {
    Write-Host ("File not found: {0}" -f $srcPath) -ForegroundColor Red
    return
  }

  $newJson = Get-Content -Raw $srcPath | ConvertFrom-Json
  $newFeatures = @($newJson.features)
  $names = @($newFeatures | ForEach-Object {
    if ($_.properties -and ($_.properties.PSObject.Properties.Name -contains "name")) { [string]$_.properties.name } else { "" }
  })
  $firstThree = @($names | Select-Object -First 3)
  $namesText = $firstThree -join ", "
  if ($names.Count -gt 3) { $namesText = $namesText + ", ..." }

  Write-Host ""
  Write-Host ("Found {0} block boundaries. Names: {1}" -f $newFeatures.Count, $namesText)

  $canonicalPath = Join-Path $customerRoot ("{0}_Boundaries.geojson" -f $Customer)
  if (Test-Path $canonicalPath) {
    $existingJson = Get-Content -Raw $canonicalPath | ConvertFrom-Json
    $existingCount = @($existingJson.features).Count
    $newInfo = Get-Item $srcPath
    $curInfo = Get-Item $canonicalPath
    Write-Host ("  New file: {0} features (modified {1})" -f $newFeatures.Count, $newInfo.LastWriteTime)
    Write-Host ("  Current:  {0} features (modified {1})" -f $existingCount, $curInfo.LastWriteTime)

    $replace = Read-YesNo ("Replace the current boundaries for {0}? [Y/n]" -f $Customer)
    if (-not $replace) {
      Write-Host "Cancelled. Nothing changed." -ForegroundColor Yellow
      return
    }
  }

  Copy-Item -Path $srcPath -Destination $canonicalPath -Force
  Write-Host ("Copied to {0}" -f $canonicalPath) -ForegroundColor Green

  $canonicalLeaf = Split-Path -Leaf $canonicalPath
  $others = @(
    Get-ChildItem -Path $customerRoot -File |
      Where-Object { $_.Name -imatch 'boundaries.*\.geojson$' -and $_.Name -ne $canonicalLeaf }
  )
  if ($others.Count -gt 0) {
    Write-Host ""
    Write-Host "Other boundaries files found at the top level:"
    foreach ($o in $others) { Write-Host ("  {0}" -f $o.Name) }
    $removeDupes = Read-YesNo "Remove the old boundaries file(s) so only one remains? [Y/n]"
    if ($removeDupes) {
      foreach ($o in $others) { Remove-Item -Path $o.FullName -Force }
      Write-Host "Removed." -ForegroundColor Green
    }
  }

  Write-Host ""
  Write-Host ("Syncing manifest for '{0}'..." -f $Customer) -ForegroundColor Green
  Invoke-Importer -ImporterArgs @("-SyncManifest", "-Customer", $Customer, "-RepoRoot", $RepoRoot)
  if ($script:LastImporterExitCode -ne 0) {
    Write-Host "Manifest sync failed - see output above." -ForegroundColor Red
    return
  }
  $script:BoundariesLoadOk = $true
}

function Invoke-Flow2 {
  $customer = Select-Customer
  if ([string]::IsNullOrWhiteSpace($customer)) { return }

  Invoke-BoundariesLoad -Customer $customer
  if (-not $script:BoundariesLoadOk) { return }

  Invoke-GapInterviewAndPublish -Customer $customer -FlowLabel "Flow2"
}

# ---------------------------------------------------------------------------
# §5.3 Flow 3 - Check gaps / publish pending.
# ---------------------------------------------------------------------------
function Invoke-Flow3 {
  $customer = Select-Customer
  if ([string]::IsNullOrWhiteSpace($customer)) { return }

  Write-Host ""
  Write-Host ("Checking gaps for '{0}'..." -f $customer) -ForegroundColor Green
  Invoke-Importer -ImporterArgs @("-SyncManifest", "-Customer", $customer, "-RepoRoot", $RepoRoot)
  if ($script:LastImporterExitCode -ne 0) {
    Write-Host "Manifest sync failed - see output above." -ForegroundColor Red
    return
  }

  Invoke-GapInterviewAndPublish -Customer $customer -FlowLabel "Flow3"
}

# ===========================================================================
# Main.
# ===========================================================================
try {
  if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
  }
  if (-not (Test-Path $RepoRoot)) {
    throw "Repo root not found: $RepoRoot"
  }
  $RepoRoot = (Resolve-Path $RepoRoot).Path

  $custRootCheck = Join-Path $RepoRoot "customers"
  $importerCheck = Join-Path $RepoRoot "scripts\import-pix4d.ps1"
  if (-not (Test-Path $custRootCheck) -or -not (Test-Path $importerCheck)) {
    throw ("This does not look like a vineyard-map-app repo root: {0} (expected customers\ and scripts\import-pix4d.ps1)" -f $RepoRoot)
  }

  Write-Host "NDVI Import Wizard" -ForegroundColor Green
  Write-Host ("Repo: {0}" -f $RepoRoot)

  Show-EnvironmentReport

  while ($true) {
    Write-Host ""
    Write-Host "What do you want to do?" -ForegroundColor Green
    Write-Host "  1) Import an NDVI export (zip)"
    Write-Host "  2) Update the block boundaries file for a vineyard"
    Write-Host "  3) Check gaps / publish pending changes"
    Write-Host "  Q) Quit"
    $choice = (Read-Answer "Choice [1]").Trim()
    if ($choice.Length -eq 0) { $choice = "1" }

    if ($choice -eq "1") {
      Invoke-Flow1
    } elseif ($choice -eq "2") {
      Invoke-Flow2
    } elseif ($choice -eq "3") {
      Invoke-Flow3
    } elseif ($choice -match '^[Qq]$') {
      break
    } else {
      Write-Host "Please enter 1, 2, 3, or Q." -ForegroundColor Yellow
    }
  }
}
catch {
  Write-Host ""
  Write-Host ("ERROR: " + $_.Exception.Message) -ForegroundColor Red
}
finally {
  Write-Host ""
  try { Read-Host "Press Enter to close" | Out-Null } catch { }
}
