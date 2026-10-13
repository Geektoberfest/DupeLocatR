<#
.SYNOPSIS
    Packages DupeLocatR into a release ZIP and prints its SHA256 hash.

.DESCRIPTION
    Run this from the repo root before creating a GitHub Release.
    It produces DupeLocatR-<version>.zip and prints the SHA256 you need
    to paste into the winget manifest.

.EXAMPLE
    .\make-release-zip.ps1
    .\make-release-zip.ps1 -Version "1.1.0"
#>

param(
    [string]$Version = "1.0.0"
)

$repoRoot = $PSScriptRoot
$zipName  = "DupeLocatR-$Version.zip"
$zipPath  = Join-Path $repoRoot $zipName

# Files to include in the release ZIP
$files = @(
    (Join-Path $repoRoot "DupeLocatr.ps1"),
    (Join-Path $repoRoot "dlr.cmd"),
    (Join-Path $repoRoot "dlr")
)

# Validate all files exist
foreach ($f in $files) {
    if (-not (Test-Path -LiteralPath $f)) {
        Write-Error "Missing file: $f"
        exit 1
    }
}

# Remove stale zip if present
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}

# Create ZIP (flat - no subdirectory inside the archive)
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::Open($zipPath, 'Create')
try {
    foreach ($f in $files) {
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $zip,
            $f,
            [System.IO.Path]::GetFileName($f),
            [System.IO.Compression.CompressionLevel]::Optimal
        ) | Out-Null
    }
} finally {
    $zip.Dispose()
}

# Compute SHA256
$sha256 = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash

Write-Host ""
Write-Host "  +  Created: $zipPath" -ForegroundColor Green
Write-Host "     Size   : $('{0:N2} KB' -f ((Get-Item $zipPath).Length / 1KB))" -ForegroundColor Gray
Write-Host ""
Write-Host "  SHA256: $sha256" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor Yellow
Write-Host "   1. Push your code to GitHub"
Write-Host "   2. Create a release tagged  v$Version"
Write-Host "   3. Upload  $zipName  as a release asset"
Write-Host "   4. Paste the SHA256 above into:"
Write-Host "        winget\manifests\v\varadisthedev\DupeLocatR\$Version\varadisthedev.DupeLocatR.installer.yaml"
Write-Host "   5. Submit the winget manifest as a PR to microsoft/winget-pkgs"
Write-Host ""
