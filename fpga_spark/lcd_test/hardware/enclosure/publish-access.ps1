param(
    [string]$ProjectRoot = $PSScriptRoot
)

$root = [System.IO.Path]::GetFullPath($ProjectRoot)
$outputFolders = @("STEP", "STL", "3MF", "DXF")
$failures = @()
$authenticatedUsers = "*S-1-5-11"

foreach ($folder in $outputFolders) {
    $path = Join-Path $root $folder
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        continue
    }

    # The CAD generator can replace individual files with owner-only ACLs.
    # Grant read/execute/traverse through the whole published subtree so an
    # ordinary SOLIDWORKS process can both enumerate folders and open files.
    & icacls $path /grant "${authenticatedUsers}:(OI)(CI)(RX)" /T /C | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $failures += $path
    }

    Get-ChildItem -LiteralPath $path -File -Recurse | ForEach-Object {
        & icacls $_.FullName /grant "${authenticatedUsers}:(R)" | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $failures += $_.FullName
        }
    }
}

if ($failures.Count -gt 0) {
    throw "Failed to grant Authenticated Users read access: $($failures -join ', ')"
}

Write-Output "Granted Authenticated Users read/execute/traverse access under $root"
