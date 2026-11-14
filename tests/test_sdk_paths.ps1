$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../sdk_paths.ps1')
$temp = Join-Path ([IO.Path]::GetTempPath()) ('ce-sdk-paths-' + [guid]::NewGuid().ToString('N'))
$oldPath = $env:PATH
$oldExe = $env:DASLANG_EXE
function Assert-Equal($actual, $expected) {
    if ($actual -ne $expected) { throw "Expected '$expected', got '$actual'" }
}
try {
    New-Item -ItemType Directory -Path $temp | Out-Null
    $explicit = Join-Path $temp 'explicit compiler.exe'
    $environment = Join-Path $temp 'environment.exe'
    $fromPath = Join-Path $temp 'daslang.exe'
    foreach ($file in @($explicit, $environment, $fromPath)) {
        New-Item -ItemType File -Path $file | Out-Null
    }
    $env:PATH = $temp
    $env:DASLANG_EXE = $environment
    Assert-Equal (Resolve-CeDaslang $explicit) $explicit
    Assert-Equal (Resolve-CeDaslang) $environment
    $env:DASLANG_EXE = ''
    Assert-Equal (Resolve-CeDaslang) $fromPath
    Assert-Equal (Resolve-CeDaslang 'daslang.exe') $fromPath
    $failed = $false
    try { Resolve-CeDaslang (Join-Path $temp 'missing.exe') | Out-Null }
    catch { $failed = $_.Exception.Message -like 'Daslang executable not found:*' }
    if (-not $failed) { throw 'Invalid explicit path silently fell back to PATH' }
    $env:PATH = ''
    $failed = $false
    try { Resolve-CeDaslang | Out-Null }
    catch { $failed = $_.Exception.Message -like 'Specify -Daslang*' }
    if (-not $failed) { throw 'Missing SDK did not produce installation guidance' }
    Write-Host 'SDK resolution checks OK'
} finally {
    $env:PATH = $oldPath
    $env:DASLANG_EXE = $oldExe
    # Only these freshly created files are removed; no recursive deletion.
    foreach ($file in @($explicit, $environment, $fromPath)) {
        if ($file -and (Test-Path -LiteralPath $file)) { Remove-Item -LiteralPath $file }
    }
    Remove-Item -LiteralPath $temp -ErrorAction SilentlyContinue
}
