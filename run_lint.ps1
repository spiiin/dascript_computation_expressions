param(
    [string]$Daslang=$env:DASLANG_EXE,
    # Folders or files to lint, relative to the repository.
    [string[]]$Paths=@('packages')
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'sdk_paths.ps1')
$Daslang = Resolve-CeDaslang $Daslang
# The linter takes its policy from the SDK's own folder unless told otherwise.
# Point it at this repository's policy, so a run means the same with any SDK.
$previousConfig=$env:DAS_LINT_CONFIG_PATH
$env:DAS_LINT_CONFIG_PATH=Join-Path $PSScriptRoot '.lint_config'
Push-Location $PSScriptRoot
try {
    # Windows PowerShell turns a native stderr line into a terminating error under 'Stop'.
    $ErrorActionPreference='Continue'
    # --no-cache and -no-module-cache keep the run from leaving a .cache folder behind.
    $lines=@(& $Daslang -no-module-cache -tool lint @Paths --quiet --no-cache 2>&1)
    $code=$LASTEXITCODE
} finally {
    $ErrorActionPreference='Stop'
    Pop-Location
    $env:DAS_LINT_CONFIG_PATH=$previousConfig
}
$lines | ForEach-Object { Write-Host "$_" }
$summary=@($lines | Where-Object { "$_" -match '^\d+ files, \d+ issue\(s\), \d+ error\(s\)' }) | Select-Object -Last 1
if(-not $summary){throw "Lint did not finish (exit $code)."}
# A finding is a warning (exit 2); a file that does not compile is an error.
if($code -ne 0 -or "$summary" -notmatch '^\d+ files, 0 issue\(s\), 0 error\(s\)'){throw "Lint is not clean: $summary"}
Write-Host "Lint clean: $summary"
