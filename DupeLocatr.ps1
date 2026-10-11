

param(
    [string]$Path = (Get-Location).Path,
    [Alias('h','?')][switch]$Help
)

# ======================================================================
#  CONFIG / STATE
# ======================================================================
$Script:RootPath = (Resolve-Path -LiteralPath $Path).Path
$Script:DupeFolderName = "encounted_duplicates"
$Script:HashAlgo = "MD5"          # MD5 (fast, default) or SHA256 (slower/stronger)
$Script:KeepStrategy = "First"        # First | Oldest | Newest | ShortestPath
$Script:CategoryFilter = "All"          # All | Images | Videos | Music | Text | Documents | Archives
$Script:MinFileSizeBytes = 1            # ignore 0-byte files by default
$Script:SmallFileLimitBytes = 10MB      # < 10 MB  → direct full hash (no sampling needed)
$Script:LargeFileLimitBytes = 500MB     # > 500 MB → 5-point sampling before full hash
$Script:SampleBytes = 65536             # 64 KB per sample window
$Script:ExcludeFolders = @(
    $Script:DupeFolderName, '.git', '.svn', 'node_modules',
    '$RECYCLE.BIN', 'System Volume Information', '.vs', '.vscode', '__pycache__'
)
$Script:LogPath = Join-Path $Script:RootPath "dupeLocatr_log.txt"
$Script:ScriptSelf = $PSCommandPath
$Script:LastResults = $null
$Script:MaxThreads = 0            # 0 = Auto (min(8, ProcessorCount)); 1 disables parallelism
$Script:ExcludeSet = $null        # built by Update-ExcludeSet

$Script:Categories = @{
    'Images'    = @('.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tiff', '.tif', '.webp', '.heic', '.heif', '.svg', '.ico', '.raw', '.cr2', '.nef', '.arw', '.dng')
    'Videos'    = @('.mp4', '.mkv', '.avi', '.mov', '.wmv', '.flv', '.webm', '.m4v', '.mpg', '.mpeg', '.3gp', '.ts', '.vob')
    'Music'     = @('.mp3', '.wav', '.flac', '.aac', '.ogg', '.wma', '.m4a', '.opus', '.aiff', '.mid')
    'Text'      = @('.txt', '.md', '.log', '.csv', '.json', '.xml', '.yaml', '.yml', '.ini', '.cfg')
    'Documents' = @('.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.odt', '.rtf')
    'Archives'  = @('.zip', '.rar', '.7z', '.tar', '.gz', '.bz2')
}

try { $Host.UI.RawUI.WindowTitle = "DupeLocatr" } catch {}

# ======================================================================
#  HELPERS
# ======================================================================
function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    elseif ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    else { return "$Bytes bytes" }
}

function Write-Banner {
    Clear-Host
    $art = @'
       __                 __                 __      
  ____/ /_  ______  ___  / /___  _________ _/ /______
 / __  / / / / __ \/ _ \/ / __ \/ ___/ __ `/ __/ ___/
/ /_/ / /_/ / /_/ /  __/ / /_/ / /__/ /_/ / /_/ /    
\__,_/\__,_/ .___/\___/_/\____/\___/\__,_/\__/_/     
          /_/                                                                                                                                                                            
'@
    $lines = $art -split "`r`n|`n"
    # $colors = @('Magenta', 'Cyan', 'Blue', 'Green', 'Yellow', 'Red')
    for ($i = 0; $i -lt $lines.Count; $i++) {
        Write-Host $lines[$i] -ForegroundColor Gray #$colors[$i % $colors.Count]
    }
    # Write-Host ""
}

function Update-ExcludeSet {
    $Script:ExcludeSet = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]($Script:ExcludeFolders | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }),
        [System.StringComparer]::OrdinalIgnoreCase
    )
}

function Test-IsExcludedDirName {
    param([string]$Name)
    if (-not $Script:ExcludeSet) { Update-ExcludeSet }
    return $Script:ExcludeSet.Contains($Name)
}

function Test-IsExcludedFile {
    param([string]$FullPath)
    if ($Script:ScriptSelf -and $FullPath -eq $Script:ScriptSelf) { return $true }
    if ($FullPath -eq $Script:LogPath) { return $true }
    if ($FullPath -like "*dupeLocatr_*") { return $true }
    return $false
}

function Test-CategoryMatch {
    param([string]$Extension)
    if ($Script:CategoryFilter -eq 'All') { return $true }
    if (-not $Extension) { return $false }
    $ext = $Extension.ToLower()
    return ($Script:Categories[$Script:CategoryFilter] -contains $ext)
}

# Read exactly $Count bytes from $Stream starting at $Offset, padding with zeros if near EOF.
function Read-SampleBlock {
    param([System.IO.FileStream]$Stream, [long]$Offset, [int]$Count)
    $buf = New-Object byte[] $Count
    $stream.Seek($Offset, [System.IO.SeekOrigin]::Begin) | Out-Null
    $read = 0
    while ($read -lt $Count) {
        $n = $stream.Read($buf, $read, $Count - $read)
        if ($n -le 0) { break }
        $read += $n
    }
    return $buf
}

# Returns a short MD5-based key string built from sampled bytes, or $null on error.
# Tier logic:
#   < SmallFileLimitBytes  → returns sentinel "SMALL" (caller routes to direct full hash)
#   SmallFileLimitBytes..LargeFileLimitBytes → first + last sample
#   > LargeFileLimitBytes  → first + middle + last + 2 deterministic-random samples
function Get-SampledKey {
    param(
        [string]$Path,
        [long]$FileLength,
        [long]$SmallFileLimitBytes = $Script:SmallFileLimitBytes,
        [long]$LargeFileLimitBytes = $Script:LargeFileLimitBytes,
        [int]$SampleBytes = $Script:SampleBytes
    )

    # Tier 1: small file – signal to skip sampling entirely
    if ($FileLength -lt $SmallFileLimitBytes) { return "SMALL" }

    $s = $SampleBytes
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $md5 = [System.Security.Cryptography.MD5]::Create()

            if ($FileLength -le $LargeFileLimitBytes) {
                # Tier 2: medium file – first + last blocks
                $first = Read-SampleBlock -Stream $stream -Offset 0                           -Count $s
                $last  = Read-SampleBlock -Stream $stream -Offset ([Math]::Max(0, $FileLength - $s)) -Count $s
                $md5.TransformBlock($first, 0, $first.Length, $null, 0) | Out-Null
                $md5.TransformFinalBlock($last,  0, $last.Length)        | Out-Null
            }
            else {
                # Tier 3: large file – first + middle + last + 2 deterministic random offsets
                $mid     = [Math]::Max(0, ($FileLength / 2) - ($s / 2))
                # Seed two pseudo-random offsets from file length so same-size files hit same spots
                $rng     = [System.Random]::new([int]($FileLength % [int]::MaxValue))
                $rand1   = [long]($rng.NextDouble() * ($FileLength - $s))
                $rand2   = [long]($rng.NextDouble() * ($FileLength - $s))

                $blocks = @(
                    (Read-SampleBlock -Stream $stream -Offset 0                                   -Count $s),
                    (Read-SampleBlock -Stream $stream -Offset $mid                                -Count $s),
                    (Read-SampleBlock -Stream $stream -Offset ([Math]::Max(0,$FileLength - $s))   -Count $s),
                    (Read-SampleBlock -Stream $stream -Offset $rand1                              -Count $s),
                    (Read-SampleBlock -Stream $stream -Offset $rand2                              -Count $s)
                )
                for ($bi = 0; $bi -lt $blocks.Count - 1; $bi++) {
                    $md5.TransformBlock($blocks[$bi], 0, $blocks[$bi].Length, $null, 0) | Out-Null
                }
                $last = $blocks[$blocks.Count - 1]
                $md5.TransformFinalBlock($last, 0, $last.Length) | Out-Null
            }

            return [System.BitConverter]::ToString($md5.Hash) -replace '-', ''
        }
        finally {
            $stream.Dispose()
        }
    }
    catch {
        return $null
    }
}

# Direct streaming hash of an entire file (replaces the Get-FileHash cmdlet for Stage 3).
# Takes no $Script: dependencies so it can run unchanged inside a worker runspace.
function Get-FullFileHash {
    param([string]$Path, [string]$Algorithm = 'MD5')

    $bufferSize = 1MB
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $hasher = if ($Algorithm -eq 'SHA256') {
                [System.Security.Cryptography.SHA256]::Create()
            } else {
                [System.Security.Cryptography.MD5]::Create()
            }
            # Double-buffer so the final chunk (which needs TransformFinalBlock,
            # not TransformBlock) is known before it's processed.
            $buf = New-Object byte[] $bufferSize
            $read = $stream.Read($buf, 0, $bufferSize)
            while ($true) {
                $next = New-Object byte[] $bufferSize
                $nextRead = $stream.Read($next, 0, $bufferSize)
                if ($nextRead -le 0) {
                    $hasher.TransformFinalBlock($buf, 0, $read) | Out-Null
                    break
                }
                $hasher.TransformBlock($buf, 0, $read, $null, 0) | Out-Null
                $buf = $next
                $read = $nextRead
            }
            return [System.BitConverter]::ToString($hasher.Hash) -replace '-', ''
        }
        finally {
            $stream.Dispose()
        }
    }
    catch {
        return $null
    }
}

# ======================================================================
#  SCANNING ENGINE
# ======================================================================
function Get-CandidateFiles {
    Write-Host "  Scanning folders under: $Script:RootPath" -ForegroundColor Cyan
    Update-ExcludeSet
    $found = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    $counter = 0

    $stack = New-Object System.Collections.Generic.Stack[System.IO.DirectoryInfo]
    $stack.Push([System.IO.DirectoryInfo]::new($Script:RootPath))

    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()

        try { $subDirs = $dir.GetDirectories() } catch { $subDirs = @() }
        foreach ($subDir in $subDirs) {
            if (-not (Test-IsExcludedDirName $subDir.Name)) {
                $stack.Push($subDir)
            }
        }

        try { $files = $dir.GetFiles() } catch { $files = @() }
        foreach ($file in $files) {
            $counter++
            if ($counter % 150 -eq 0) {
                Write-Progress -Activity "DupeLocatr | Enumerating files" -Status "$counter files found so far..."
            }
            if (-not (Test-IsExcludedFile $file.FullName)) {
                if ($file.Length -ge $Script:MinFileSizeBytes) {
                    if (Test-CategoryMatch $file.Extension) {
                        $found.Add($file)
                    }
                }
            }
        }
    }

    Write-Progress -Activity "DupeLocatr | Enumerating files" -Completed
    Write-Host "  Total files considered: $($found.Count)" -ForegroundColor Gray
    return $found
}

function Group-FilesBySize {
    param([System.Collections.Generic.List[System.IO.FileInfo]]$Files)
    $buckets = New-Object 'System.Collections.Generic.Dictionary[long,System.Collections.Generic.List[System.IO.FileInfo]]'
    foreach ($f in $Files) {
        $list = $null
        if (-not $buckets.TryGetValue($f.Length, [ref]$list)) {
            $list = New-Object System.Collections.Generic.List[System.IO.FileInfo]
            $buckets[$f.Length] = $list
        }
        $list.Add($f)
    }
    $candidates = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    foreach ($list in $buckets.Values) {
        if ($list.Count -gt 1) {
            foreach ($item in $list) { $candidates.Add($item) }
        }
    }
    return $candidates
}

# Builds a RunspacePool whose worker runspaces have Read-SampleBlock / Get-SampledKey /
# Get-FullFileHash predefined, so parallel workers can call them without re-declaring them.
function New-DlrRunspacePool {
    param([int]$MaxThreads)
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $iss.Commands.Add([System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new('Read-SampleBlock', ${function:Read-SampleBlock}))
    $iss.Commands.Add([System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new('Get-SampledKey', ${function:Get-SampledKey}))
    $iss.Commands.Add([System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new('Get-FullFileHash', ${function:Get-FullFileHash}))
    $pool = [runspacefactory]::CreateRunspacePool(1, [Math]::Max(1, $MaxThreads), $iss, $Host)
    $pool.ApartmentState = 'MTA'
    $pool.Open()
    return $pool
}

# Runs $Worker (a scriptblock taking one FileInfo positional arg and returning a result
# object) over $Files, either sequentially (small file counts, or MaxThreads<=1) or in
# parallel via a RunspacePool. Aggregation always happens back on the calling thread.
function Invoke-DlrParallelStage {
    param(
        [System.Collections.Generic.List[System.IO.FileInfo]]$Files,
        [scriptblock]$Worker,
        [string]$ActivityName,
        [int]$MaxThreads,
        [int]$MinParallelThreshold = 32
    )

    $total = $Files.Count
    $results = New-Object System.Collections.Generic.List[psobject]
    if ($total -eq 0) { return $results }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    if ($total -lt $MinParallelThreshold -or $MaxThreads -le 1) {
        $i = 0
        foreach ($f in $Files) {
            $i++
            if ($sw.ElapsedMilliseconds -ge 200 -or $i -eq $total) {
                Write-Progress -Activity $ActivityName -Status "$i / $total : $($f.Name)" -PercentComplete ([Math]::Round(($i / $total) * 100))
                $sw.Restart()
            }
            $results.Add((& $Worker $f))
        }
        Write-Progress -Activity $ActivityName -Completed
        return $results
    }

    $pool = New-DlrRunspacePool -MaxThreads $MaxThreads
    try {
        $workerText = $Worker.ToString()
        $pending = New-Object System.Collections.Generic.List[psobject]
        foreach ($f in $Files) {
            $ps = [powershell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($workerText).AddArgument($f)
            $handle = $ps.BeginInvoke()
            $pending.Add([PSCustomObject]@{ PS = $ps; Handle = $handle })
        }

        $completedCount = 0
        while ($pending.Count -gt 0) {
            for ($idx = $pending.Count - 1; $idx -ge 0; $idx--) {
                $item = $pending[$idx]
                if ($item.Handle.IsCompleted) {
                    try {
                        $out = $item.PS.EndInvoke($item.Handle)
                        foreach ($o in $out) { $results.Add($o) }
                    }
                    catch {
                        # A single file's worker failing (deleted mid-scan, path too long, etc.)
                        # must not abort the rest of the scan - just drop that file's result.
                    }
                    $item.PS.Dispose()
                    $pending.RemoveAt($idx)
                    $completedCount++
                }
            }
            if ($sw.ElapsedMilliseconds -ge 200 -or $pending.Count -eq 0) {
                Write-Progress -Activity $ActivityName -Status "$completedCount / $total" -PercentComplete ([Math]::Round(($completedCount / $total) * 100))
                $sw.Restart()
            }
            if ($pending.Count -gt 0) { Start-Sleep -Milliseconds 25 }
        }
        Write-Progress -Activity $ActivityName -Completed
    }
    finally {
        $pool.Close()
        $pool.Dispose()
    }
    return $results
}

function Find-Duplicates {
    $allFiles = Get-CandidateFiles
    if ($allFiles.Count -eq 0) {
        Write-Host "  No files found to compare." -ForegroundColor Yellow
        return $null
    }

    # ---- Stage 1: group by size (instant) ----
    Write-Host "  Stage 1/3: grouping by file size..." -ForegroundColor Cyan
    $sizeCandidates = Group-FilesBySize -Files $allFiles

    if ($sizeCandidates.Count -eq 0) {
        Write-Host "  Every file has a unique size - nothing to compare further." -ForegroundColor Yellow
        return $null
    }
    Write-Host "  $($sizeCandidates.Count) file(s) share a size with at least one other file." -ForegroundColor Gray

    $resolvedMaxThreads = if ($Script:MaxThreads -gt 0) { $Script:MaxThreads } else { [Math]::Min(8, [Environment]::ProcessorCount) }

    # ---- Stage 2: tiered sampling (small files bypass directly to Stage 3) ----
    Write-Host "  Stage 2/3: tiered content sampling..." -ForegroundColor Cyan
    $directQueue = New-Object System.Collections.Generic.List[System.IO.FileInfo]  # < 10 MB
    $sampleMap   = @{}                                                              # >= 10 MB

    # $Script:SmallFileLimitBytes / LargeFileLimitBytes / SampleBytes aren't visible inside a
    # worker runspace (Get-SampledKey's parameter defaults would silently resolve to $null
    # there), so bake the current values in as literals instead of relying on the defaults.
    $stage2Worker = [scriptblock]::Create(@"
param(`$f)
`$key = Get-SampledKey -Path `$f.FullName -FileLength `$f.Length -SmallFileLimitBytes $($Script:SmallFileLimitBytes) -LargeFileLimitBytes $($Script:LargeFileLimitBytes) -SampleBytes $($Script:SampleBytes)
[PSCustomObject]@{ File = `$f; Result = `$key }
"@)
    $sampleResults = Invoke-DlrParallelStage -Files $sizeCandidates -Worker $stage2Worker -ActivityName "DupeLocatr | Tiered sampling" -MaxThreads $resolvedMaxThreads

    foreach ($r in $sampleResults) {
        $f = $r.File
        $sampleKey = $r.Result
        if ($sampleKey -eq "SMALL") {
            # Tier 1: small file → queue for direct full hash
            $directQueue.Add($f)
        }
        elseif ($null -ne $sampleKey) {
            # Tier 2 / Tier 3: medium or large file → group by sample fingerprint
            $key = "$($f.Length)_$sampleKey"
            if (-not $sampleMap.ContainsKey($key)) {
                $sampleMap[$key] = New-Object System.Collections.Generic.List[System.IO.FileInfo]
            }
            $sampleMap[$key].Add($f)
        }
    }

    $fullCandidates = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    # Direct-queue small files always advance to full hash
    foreach ($item in $directQueue) { $fullCandidates.Add($item) }
    # Medium/large files only advance if their sample fingerprint is shared
    foreach ($key in $sampleMap.Keys) {
        if ($sampleMap[$key].Count -gt 1) {
            foreach ($item in $sampleMap[$key]) { $fullCandidates.Add($item) }
        }
    }

    if ($fullCandidates.Count -eq 0) {
        Write-Host "  Sampling found no content matches." -ForegroundColor Yellow
        return $null
    }
    $smallCount  = $directQueue.Count
    $sampleCount = $fullCandidates.Count - $smallCount
    Write-Host "  $smallCount small file(s) queued for direct hash; $sampleCount larger file(s) passed sample check." -ForegroundColor Gray

    # ---- Stage 3: full hash confirmation ----
    Write-Host "  Stage 3/3: confirming with a full $Script:HashAlgo hash..." -ForegroundColor Cyan
    $fullMap = @{}

    # $Script:HashAlgo isn't visible inside a worker runspace, so bake it in as a literal.
    $hashAlgoLiteral = $Script:HashAlgo
    $stage3Worker = [scriptblock]::Create(
        "param(`$f) `$h = Get-FullFileHash -Path `$f.FullName -Algorithm '$hashAlgoLiteral'; [PSCustomObject]@{ File = `$f; Result = `$h }"
    )
    $hashResults = Invoke-DlrParallelStage -Files $fullCandidates -Worker $stage3Worker -ActivityName "DupeLocatr | Verifying duplicates" -MaxThreads $resolvedMaxThreads

    foreach ($r in $hashResults) {
        $f = $r.File
        $h = $r.Result
        if ($h) {
            $key = "$($f.Length)_$h"
            if (-not $fullMap.ContainsKey($key)) {
                $fullMap[$key] = New-Object System.Collections.Generic.List[System.IO.FileInfo]
            }
            $fullMap[$key].Add($f)
        }
    }

    # ---- Build result groups ----
    $results = @()
    foreach ($key in $fullMap.Keys) {
        $group = $fullMap[$key]
        if ($group.Count -gt 1) {
            $sorted = switch ($Script:KeepStrategy) {
                'Oldest' { $group | Sort-Object LastWriteTime }
                'Newest' { $group | Sort-Object LastWriteTime -Descending }
                'ShortestPath' { $group | Sort-Object { $_.FullName.Length } }
                default { $group | Sort-Object FullName }
            }
            $keep = $sorted[0]
            $dupes = @($sorted | Select-Object -Skip 1)
            $results += [PSCustomObject]@{
                Hash           = $key
                SizeEach       = $keep.Length
                KeepFile       = $keep
                DuplicateFiles = $dupes
            }
        }
    }
    return $results
}

# ======================================================================
#  REPORTING
# ======================================================================
function Write-DuplicateLog {
    param($Results)
    $lines = @()
    $lines += "DupeLocatr scan log - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $lines += "Root: $Script:RootPath"
    $lines += "Hash algorithm: $Script:HashAlgo | Keep strategy: $Script:KeepStrategy | Category filter: $Script:CategoryFilter"
    $lines += "-----------------------------------------------------------"
    $n = 1
    foreach ($grp in $Results) {
        $lines += "Group $n (size each: $(Format-Size $grp.SizeEach))"
        $lines += "  KEEP: $($grp.KeepFile.FullName)"
        foreach ($d in $grp.DuplicateFiles) { $lines += "  DUPE: $($d.FullName)" }
        $n++
    }
    $lines += ""
    Add-Content -LiteralPath $Script:LogPath -Value $lines -Encoding UTF8
}

function Show-DetailedList {
    param($Results)
    Clear-Host
    Write-Host "  ---- Duplicate Details ----" -ForegroundColor Magenta
    $n = 1
    foreach ($grp in $Results) {
        Write-Host ""
        Write-Host "  Group $n  (size each: $(Format-Size $grp.SizeEach))" -ForegroundColor Cyan
        Write-Host "    KEEP  -> $($grp.KeepFile.FullName)" -ForegroundColor Green
        foreach ($d in $grp.DuplicateFiles) {
            Write-Host "    DUPE  -> $($d.FullName)" -ForegroundColor Yellow
        }
        $n++
    }
    Write-Host ""
    Read-Host "  Press Enter to go back" | Out-Null
}

function Export-DuplicateReport {
    param($Results, [ValidateSet('CSV', 'JSON')][string]$Format = 'CSV')
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $outPath = Join-Path $Script:RootPath ("dupeLocatr_report_{0}.{1}" -f $stamp, $Format.ToLower())

    if ($Format -eq 'CSV') {
        $rows = @()
        $n = 1
        foreach ($grp in $Results) {
            # Group keys are "<size>_<hash>"; export just the hash
            $hash = ($grp.Hash -split '_', 2)[1]
            $rows += [PSCustomObject]@{ Group = $n; Hash = $hash; SizeBytes = $grp.SizeEach; Role = 'KEEP'; Path = $grp.KeepFile.FullName }
            foreach ($d in $grp.DuplicateFiles) {
                $rows += [PSCustomObject]@{ Group = $n; Hash = $hash; SizeBytes = $grp.SizeEach; Role = 'DUPLICATE'; Path = $d.FullName }
            }
            $n++
        }
        $rows | Export-Csv -LiteralPath $outPath -NoTypeInformation -Encoding UTF8
    }
    else {
        $groups = @()
        $n = 1
        foreach ($grp in $Results) {
            $groups += [ordered]@{
                group      = $n
                hash       = ($grp.Hash -split '_', 2)[1]
                sizeBytes  = $grp.SizeEach
                keep       = $grp.KeepFile.FullName
                duplicates = @($grp.DuplicateFiles | ForEach-Object { $_.FullName })
            }
            $n++
        }
        $report = [ordered]@{
            generated     = (Get-Date -Format 's')
            root          = $Script:RootPath
            hashAlgorithm = $Script:HashAlgo
            keepStrategy  = $Script:KeepStrategy
            groups        = $groups
        }
        # -InputObject keeps single-item arrays as arrays; write UTF-8 without a BOM
        $json = ConvertTo-Json -InputObject $report -Depth 5
        [System.IO.File]::WriteAllText($outPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    }

    Write-Host ""
    Write-Host "  Report saved to: $outPath" -ForegroundColor Green
    Start-Sleep -Seconds 1
}

# ======================================================================
#  ACTIONS  (both ask for confirmation before touching anything)
# ======================================================================
function Invoke-MoveDuplicates {
    param($Results)

    $allDupes = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    foreach ($grp in $Results) { foreach ($d in $grp.DuplicateFiles) { $allDupes.Add($d) } }
    $count = $allDupes.Count
    $totalSize = ($allDupes | Measure-Object Length -Sum).Sum

    Write-Host ""
    Write-Host "  This will MOVE $count duplicate file(s) ($(Format-Size $totalSize)) into:" -ForegroundColor Yellow
    Write-Host "    $(Join-Path $Script:RootPath $Script:DupeFolderName)" -ForegroundColor Yellow
    $confirm = Read-Host "  Type Y to continue, anything else to cancel"
    if ($confirm -ne 'Y' -and $confirm -ne 'y') {
        Write-Host "  Cancelled. No files were moved." -ForegroundColor Gray
        Start-Sleep -Seconds 1
        return
    }

    $destFolder = Join-Path $Script:RootPath $Script:DupeFolderName
    if (-not (Test-Path -LiteralPath $destFolder)) {
        New-Item -ItemType Directory -Path $destFolder | Out-Null
    }

    $i = 0
    $moved = 0
    $errors = 0
    foreach ($f in $allDupes) {
        $i++
        Write-Progress -Activity "DupeLocatr | Moving duplicates" -Status "$i / $count : $($f.Name)" -PercentComplete ([Math]::Round(($i / $count) * 100))

        $destName = $f.Name
        $destPath = Join-Path $destFolder $destName
        if (Test-Path -LiteralPath $destPath) {
            $parentTag = ($f.Directory.Name -replace '[^\w\-]', '_')
            $destName = "{0}__{1}" -f $parentTag, $f.Name
            $destPath = Join-Path $destFolder $destName
            $dupCounter = 1
            while (Test-Path -LiteralPath $destPath) {
                $destName = "{0}__{1}__{2}" -f $parentTag, $dupCounter, $f.Name
                $destPath = Join-Path $destFolder $destName
                $dupCounter++
            }
        }

        try {
            robocopy $f.DirectoryName $destFolder $f.Name /MOV /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
            $movedRaw = Join-Path $destFolder $f.Name
            if ((Test-Path -LiteralPath $movedRaw) -and ($destName -ne $f.Name)) {
                Rename-Item -LiteralPath $movedRaw -NewName $destName -ErrorAction SilentlyContinue
            }
            if ((Test-Path -LiteralPath $movedRaw) -or (Test-Path -LiteralPath $destPath)) {
                $moved++
            }
            else {
                $errors++
            }
        }
        catch {
            $errors++
        }
    }
    Write-Progress -Activity "DupeLocatr | Moving duplicates" -Completed

    Write-Host ""
    Write-Host "  Done. Moved $moved file(s), $errors error(s)." -ForegroundColor Green
    Add-Content -LiteralPath $Script:LogPath -Value "Action: MOVE - $moved moved, $errors errors - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Read-Host "  Press Enter to continue" | Out-Null
}

function Invoke-DeleteDuplicates {
    param($Results)

    $hasVB = $true
    try { Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop } catch { $hasVB = $false }

    $allDupes = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    foreach ($grp in $Results) { foreach ($d in $grp.DuplicateFiles) { $allDupes.Add($d) } }
    $count = $allDupes.Count
    $totalSize = ($allDupes | Measure-Object Length -Sum).Sum

    Write-Host ""
    Write-Host "  This will send $count duplicate file(s) ($(Format-Size $totalSize)) to the Recycle Bin." -ForegroundColor Red
    Write-Host "  They can be restored from the Recycle Bin afterward if you change your mind." -ForegroundColor Gray
    $confirm = Read-Host "  Type YES (all caps) to confirm, anything else cancels"
    if ($confirm -cne 'YES') {
        Write-Host "  Cancelled. No files were deleted." -ForegroundColor Gray
        Start-Sleep -Seconds 1
        return
    }

    $i = 0
    $deleted = 0
    $errors = 0
    foreach ($f in $allDupes) {
        $i++
        Write-Progress -Activity "DupeLocatr | Deleting duplicates" -Status "$i / $count : $($f.Name)" -PercentComplete ([Math]::Round(($i / $count) * 100))
        try {
            if ($hasVB) {
                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
                    $f.FullName,
                    [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                    [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
                )
            }
            else {
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
            }
            $deleted++
        }
        catch {
            $errors++
        }
    }
    Write-Progress -Activity "DupeLocatr | Deleting duplicates" -Completed

    Write-Host ""
    Write-Host "  Done. Deleted $deleted file(s), $errors error(s)." -ForegroundColor Green
    Add-Content -LiteralPath $Script:LogPath -Value "Action: DELETE - $deleted deleted, $errors errors - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Read-Host "  Press Enter to continue" | Out-Null
}

# ======================================================================
#  MENUS
# ======================================================================
function Show-ScanResults {
    param($Results)

    if (-not $Results -or $Results.Count -eq 0) {
        Write-Host ""
        Write-Host "  No duplicate files found. This folder looks clean." -ForegroundColor Green
        Read-Host "  Press Enter to return to the menu" | Out-Null
        return
    }

    $Script:LastResults = $Results
    $totalDupeFiles = ($Results | ForEach-Object { $_.DuplicateFiles.Count } | Measure-Object -Sum).Sum
    $totalDupeSize = ($Results | ForEach-Object { $_.DuplicateFiles.Count * $_.SizeEach } | Measure-Object -Sum).Sum
    Write-DuplicateLog -Results $Results

    $done = $false
    while (-not $done) {
        Write-Host ""
        Write-Host "  ===================== SCAN COMPLETE =====================" -ForegroundColor Magenta
        Write-Host "   Duplicate groups found : $($Results.Count)" -ForegroundColor White
        Write-Host "   Duplicate files found  : $totalDupeFiles" -ForegroundColor Yellow
        Write-Host "   Space that can be freed: $(Format-Size $totalDupeSize)" -ForegroundColor Yellow
        Write-Host "  ===========================================================" -ForegroundColor Magenta
        Write-Host ""
        Write-Host "  What would you like to do?" -ForegroundColor Cyan
        Write-Host "   [1] View the detailed list"
        Write-Host "   [2] Move duplicates to '$Script:DupeFolderName' folder (safe, undoable)"
        Write-Host "   [3] Delete duplicates (sent to Recycle Bin, recoverable)"
        Write-Host "   [4] Export report (CSV or JSON)"
        Write-Host "   [5] Return to main menu"
        $choice = Read-Host "  Choose an option (1-5)"
        switch ($choice) {
            '1' { Show-DetailedList -Results $Results }
            '2' { Invoke-MoveDuplicates -Results $Results; $done = $true }
            '3' { Invoke-DeleteDuplicates -Results $Results; $done = $true }
            '4' {
                $fmt = Read-Host "  Export as [1] CSV or [2] JSON (Enter to cancel)"
                switch ($fmt) {
                    '1' { Export-DuplicateReport -Results $Results -Format CSV }
                    '2' { Export-DuplicateReport -Results $Results -Format JSON }
                }
            }
            '5' { $done = $true }
            default { Write-Host "  Invalid choice." -ForegroundColor Red }
        }
    }
}

function Show-SettingsMenu {
    $back = $false
    while (-not $back) {
        Clear-Host
        Write-Host "  ---- Settings ----" -ForegroundColor Magenta
        Write-Host "   [1] Hash algorithm        : $Script:HashAlgo"
        Write-Host "   [2] Keep strategy         : $Script:KeepStrategy"
        Write-Host "   [3] Category filter       : $Script:CategoryFilter"
        Write-Host "   [4] Excluded folders      : $($Script:ExcludeFolders -join ', ')"
        Write-Host "   [5] Duplicate folder name : $Script:DupeFolderName"
        $threadLabel = if ($Script:MaxThreads -gt 0) { "$Script:MaxThreads" } else { "Auto (min(8, $([Environment]::ProcessorCount)))" }
        Write-Host "   [6] Parallel threads      : $threadLabel"
        Write-Host "   [7] Back to main menu"
        Write-Host ""
        $c = Read-Host "  Choose an option (1-7)"
        switch ($c) {
            '1' {
                Write-Host "   a) MD5 (fast, default)"
                Write-Host "   b) SHA256 (slower, stronger)"
                $h = Read-Host "  Choose"
                if ($h -eq 'b') { $Script:HashAlgo = 'SHA256' } else { $Script:HashAlgo = 'MD5' }
            }
            '2' {
                Write-Host "   a) First (alphabetically first path) - default"
                Write-Host "   b) Oldest (earliest modified date kept)"
                Write-Host "   c) Newest (latest modified date kept)"
                Write-Host "   d) ShortestPath (keep the shallowest copy)"
                $k = Read-Host "  Choose"
                switch ($k) {
                    'b' { $Script:KeepStrategy = 'Oldest' }
                    'c' { $Script:KeepStrategy = 'Newest' }
                    'd' { $Script:KeepStrategy = 'ShortestPath' }
                    default { $Script:KeepStrategy = 'First' }
                }
            }
            '3' {
                Write-Host "   Categories: All, Images, Videos, Music, Text, Documents, Archives"
                $cat = Read-Host "  Type a category"
                if ($cat -eq 'All' -or $Script:Categories.ContainsKey($cat)) {
                    $Script:CategoryFilter = $cat
                }
                else {
                    Write-Host "  Unknown category, keeping '$Script:CategoryFilter'." -ForegroundColor Red
                    Start-Sleep -Seconds 1
                }
            }
            '4' {
                $newList = Read-Host "  Enter comma-separated folder names to exclude (replaces current list)"
                if ($newList) {
                    $Script:ExcludeFolders = @(($newList -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                    $Script:ExcludeFolders += $Script:DupeFolderName
                    Update-ExcludeSet
                }
            }
            '5' {
                $newName = Read-Host "  Enter new duplicate folder name"
                if ($newName) { $Script:DupeFolderName = $newName }
            }
            '6' {
                Write-Host "   Enter a thread count, or leave blank / type 'auto' for automatic (min(8, CPU cores))."
                Write-Host "   Enter 1 to disable parallelism entirely."
                $t = Read-Host "  Choose"
                if ([string]::IsNullOrWhiteSpace($t) -or $t -eq 'auto') {
                    $Script:MaxThreads = 0
                }
                elseif ($t -match '^\d+$' -and [int]$t -gt 0) {
                    $Script:MaxThreads = [int]$t
                }
                else {
                    Write-Host "  Invalid value, keeping current setting." -ForegroundColor Red
                    Start-Sleep -Seconds 1
                }
            }
            '7' { $back = $true }
            default { Write-Host "  Invalid choice." -ForegroundColor Red; Start-Sleep -Seconds 1 }
        }
    }
}

function Show-Help {
    Write-Host "  COMMANDS" -ForegroundColor Magenta
    Write-Host "   dlr                  Scan the current directory" -ForegroundColor White
    Write-Host "   dlr <folder>         Scan a specific folder, e.g. dlr D:\Photos" -ForegroundColor White
    Write-Host "   dlr help | -h | /?   Show this help" -ForegroundColor White
    Write-Host ""
    Write-Host "  Without the shim:  powershell -File DupeLocatr.ps1 [-Path <folder>] [-Help]" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  MENU" -ForegroundColor Magenta
    Write-Host "   [1] Start duplicate scan   [2] Settings   [3] View log   [4] Help   [5] Exit" -ForegroundColor White
    Write-Host ""
}

function Show-MainMenu {
    $exit = $false
    while (-not $exit) {
        Write-Banner
        Write-Host "  Target folder: $Script:RootPath" -ForegroundColor Gray
        Write-Host "  *We will also scan every subfolder in the current directory" -ForegroundColor Green
        Write-Host ""
        Write-Host "   [1] Start duplicate scan"
        Write-Host "   [2] Settings"
        Write-Host "   [3] View log file"
        Write-Host "   [4] About / help"
        Write-Host "   [5] Exit"
        Write-Host ""
        $choice = Read-Host "  Choose an option (1-5)"
        switch ($choice) {
            '1' {
                Clear-Host
                Write-Banner
                $results = Find-Duplicates
                Show-ScanResults -Results $results
            }
            '2' { Show-SettingsMenu }
            '3' {
                Clear-Host
                Write-Host "  ---- Log File ----" -ForegroundColor Magenta
                if (Test-Path -LiteralPath $Script:LogPath) {
                    Get-Content -LiteralPath $Script:LogPath | ForEach-Object { Write-Host $_ }
                }
                else {
                    Write-Host "  No log file yet. Run a scan first." -ForegroundColor Yellow
                }
                Write-Host ""
                Read-Host "  Press Enter to go back" | Out-Null
            }
            '4' {
                Clear-Host
                Write-Banner
                Write-Host "  DupeLocatr finds duplicates in three stages:" -ForegroundColor White
                Write-Host "   1. Group by file size (instant - no I/O)" -ForegroundColor White
                Write-Host "   2. Tiered content sampling:" -ForegroundColor White
                Write-Host "       < 10 MB   : skip sampling, direct full hash" -ForegroundColor White
                Write-Host "      10-500 MB  : first + last 64 KB sample" -ForegroundColor White
                Write-Host "      > 500 MB   : first + middle + last + 2 random 64 KB samples" -ForegroundColor White
                Write-Host "   3. Full hash only on files that passed stage 2" -ForegroundColor White
                Write-Host ""
                Write-Host "  Excluded folders (.git, node_modules, etc.) are skipped during the" -ForegroundColor White
                Write-Host "  folder walk itself, not scanned then discarded." -ForegroundColor White
                Write-Host "  Stages 2 and 3 run in parallel across multiple threads for large" -ForegroundColor White
                Write-Host "  scans (configurable in Settings)." -ForegroundColor White
                Write-Host ""
                Write-Host "  It never deletes or moves anything without asking first." -ForegroundColor White
                Write-Host "  Deletions go to the Recycle Bin, not permanent removal." -ForegroundColor White
                Write-Host "  Moves use robocopy and land in the '$Script:DupeFolderName' folder." -ForegroundColor White
                Write-Host ""
                Show-Help
                Read-Host "  Press Enter to go back" | Out-Null
            }
            '5' { $exit = $true }
            default { Write-Host "  Invalid choice." -ForegroundColor Red; Start-Sleep -Seconds 1 }
        }
    }
    Write-Host ""
    Write-Host "  Goodbye!" -ForegroundColor Cyan
    Start-Sleep -Milliseconds 500
}

# ======================================================================
#  ENTRY POINT
# ======================================================================
if ($Help) { Show-Help; return }
Show-MainMenu
