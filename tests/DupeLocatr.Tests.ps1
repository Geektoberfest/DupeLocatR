Describe 'DupeLocatr' {
BeforeAll {
    $script:AppScript = Join-Path $PSScriptRoot '..\DupeLocatr.ps1'
    . $script:AppScript
}

BeforeEach {
    $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:TestRoot | Out-Null

    $Script:RootPath = $script:TestRoot
    $Script:LogPath = Join-Path $script:TestRoot 'dupeLocatr_log.txt'
    $Script:ScriptSelf = Join-Path $script:TestRoot 'not-the-app.ps1'
    $Script:ExcludeFolders = @($Script:DupeFolderName, '.git', '.svn', 'node_modules', '$RECYCLE.BIN', 'System Volume Information', '.vs', '.vscode', '__pycache__')
    $Script:MinFileSizeBytes = 1
    $Script:SmallFileLimitBytes = 1MB
    $Script:LargeFileLimitBytes = 500MB
    $Script:SampleBytes = 65536
    $Script:HashAlgo = 'MD5'
    $Script:CategoryFilter = 'All'
    $Script:MaxThreads = 1
}

AfterEach {
    if (Test-Path -LiteralPath $script:TestRoot) {
        Remove-Item -LiteralPath $script:TestRoot -Recurse -Force
    }
}

Describe 'DupeLocatr scanning' {
    It 'finds files recursively and skips excluded folders' {
        $includedDir = Join-Path $script:TestRoot 'photos with spaces'
        $excludedDir = Join-Path $script:TestRoot '.git'
        $similarDir = Join-Path $script:TestRoot 'dupeLocatr_personal'
        New-Item -ItemType Directory -Path $includedDir | Out-Null
        New-Item -ItemType Directory -Path $excludedDir | Out-Null
        New-Item -ItemType Directory -Path $similarDir | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $script:TestRoot 'root.txt'), 'root')
        [System.IO.File]::WriteAllText((Join-Path $includedDir 'photo.txt'), 'photo')
        [System.IO.File]::WriteAllText((Join-Path $excludedDir 'ignored.txt'), 'ignored')
        [System.IO.File]::WriteAllText((Join-Path $similarDir 'personal.txt'), 'personal')

        $files = @(Get-CandidateFiles)

        $files.Count | Should -Be 3
        $files.Name | Should -Contain 'root.txt'
        $files.Name | Should -Contain 'photo.txt'
        $files.Name | Should -Contain 'personal.txt'
        $files.Name | Should -Not -Contain 'ignored.txt'
    }

    It 'uses the platform file-name rules for excluded directories' {
        Update-ExcludeSet

        Test-IsExcludedDirName '.git' | Should -BeTrue
        Test-IsExcludedDirName '.GIT' | Should -Be (Test-UseCaseInsensitivePaths)
    }

    It 'does not follow linked directories on Unix' {
        if (Test-IsWindows) { return }
        $outsideDir = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $outsideDir | Out-Null
        try {
            [System.IO.File]::WriteAllText((Join-Path $outsideDir 'outside.txt'), 'outside')
            New-Item -ItemType SymbolicLink -Path (Join-Path $script:TestRoot 'linked') -Target $outsideDir | Out-Null

            @(Get-CandidateFiles).Count | Should -Be 0
        }
        finally {
            Remove-Item -LiteralPath $outsideDir -Recurse -Force
        }
    }
}

Describe 'DupeLocatr hashing' {
    It 'returns the expected MD5 for a file' {
        $filePath = Join-Path $script:TestRoot 'known.txt'
        [System.IO.File]::WriteAllText($filePath, 'hello')

        Get-FullFileHash -Path $filePath -Algorithm MD5 | Should -Be '5D41402ABC4B2A76B9719D911017C592'
    }
}

Describe 'DupeLocatr move action' {
    It 'stages duplicate files without overwriting matching names' {
        $firstDir = Join-Path $script:TestRoot 'first'
        $secondDir = Join-Path $script:TestRoot 'second'
        New-Item -ItemType Directory -Path $firstDir | Out-Null
        New-Item -ItemType Directory -Path $secondDir | Out-Null
        $keepPath = Join-Path $script:TestRoot 'keep.txt'
        $firstPath = Join-Path $firstDir 'copy.txt'
        $secondPath = Join-Path $secondDir 'copy.txt'
        foreach ($filePath in @($keepPath, $firstPath, $secondPath)) {
            [System.IO.File]::WriteAllText($filePath, 'same contents')
        }
        $group = [PSCustomObject]@{
            Hash           = 'ABC123'
            SizeEach       = 13
            KeepFile       = Get-Item -LiteralPath $keepPath
            DuplicateFiles = @((Get-Item -LiteralPath $firstPath), (Get-Item -LiteralPath $secondPath))
        }
        Mock Read-Host { 'Y' }

        Invoke-MoveDuplicates -Results @($group)

        Test-Path -LiteralPath $keepPath | Should -BeTrue
        Test-Path -LiteralPath $firstPath | Should -BeFalse
        Test-Path -LiteralPath $secondPath | Should -BeFalse
        $stagedFiles = @(Get-ChildItem -LiteralPath (Join-Path $script:TestRoot $Script:DupeFolderName) -File)
        $stagedFiles.Count | Should -Be 2
        ($stagedFiles.Name | Select-Object -Unique).Count | Should -Be 2
    }
}

Describe 'DupeLocatr deletion action' {
    It 'does not delete files on Unix without a Recycle Bin' {
        if (Test-IsWindows) { return }
        $filePath = Join-Path $script:TestRoot 'keep.txt'
        [System.IO.File]::WriteAllText($filePath, 'keep me')
        Mock Read-Host { '' }

        Invoke-DeleteDuplicates -Results @([PSCustomObject]@{ DuplicateFiles = @((Get-Item -LiteralPath $filePath)) })

        Test-Path -LiteralPath $filePath | Should -BeTrue
    }
}

Describe 'DupeLocatr keep strategy' {
    BeforeEach {
        $nestedDir = Join-Path $script:TestRoot 'nested'
        $deepDir = Join-Path $nestedDir 'deep'
        New-Item -ItemType Directory -Path $deepDir | Out-Null

        $script:FirstPath = Join-Path $script:TestRoot 'a.txt'
        $script:OldestPath = Join-Path $nestedDir 'oldest.txt'
        $script:DeepPath = Join-Path $deepDir 'newest.txt'
        foreach ($filePath in @($script:FirstPath, $script:OldestPath, $script:DeepPath)) {
            [System.IO.File]::WriteAllText($filePath, 'same contents')
        }
        (Get-Item -LiteralPath $script:OldestPath).LastWriteTime = [datetime]'2020-01-01'
        (Get-Item -LiteralPath $script:FirstPath).LastWriteTime = [datetime]'2022-01-01'
        (Get-Item -LiteralPath $script:DeepPath).LastWriteTime = [datetime]'2024-01-01'
    }

    It 'keeps the alphabetically first path by default' {
        $Script:KeepStrategy = 'First'

        $results = @(Find-Duplicates)

        $results.Count | Should -Be 1
        $results[0].KeepFile.FullName | Should -Be $script:FirstPath
        $results[0].SizeEach | Should -Be ([System.IO.File]::ReadAllBytes($script:FirstPath).Length)
    }

    It 'keeps the oldest file when configured' {
        $Script:KeepStrategy = 'Oldest'

        $results = @(Find-Duplicates)

        $results[0].KeepFile.FullName | Should -Be $script:OldestPath
    }

    It 'keeps the newest file when configured' {
        $Script:KeepStrategy = 'Newest'

        $results = @(Find-Duplicates)

        $results[0].KeepFile.FullName | Should -Be $script:DeepPath
    }

    It 'keeps the shortest path when configured' {
        $Script:KeepStrategy = 'ShortestPath'

        $results = @(Find-Duplicates)

        $results[0].KeepFile.FullName | Should -Be $script:FirstPath
    }
}
}
