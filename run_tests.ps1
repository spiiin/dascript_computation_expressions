param(
    [string]$Daslang=$env:DASLANG_EXE,
    # Folders or files to test, relative to the repository.
    [string[]]$Paths=@('tests'),
    # Only the tests whose name starts with this text.
    [string]$Names='',
    # Print the output of failed tests only.
    [switch]$Quiet,
    # The whole run is stopped after this many seconds.
    [int]$TimeoutSec=1800
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'sdk_paths.ps1')
$Daslang = Resolve-CeDaslang $Daslang
# dastest ships with the SDK: next to bin/ in a release, two folders up in a source build.
$dastest=$null
$folder=Split-Path $Daslang -Parent
foreach($step in 1..3){
    $candidate=Join-Path $folder 'dastest/dastest.das'
    if(Test-Path -LiteralPath $candidate -PathType Leaf){$dastest=$candidate;break}
    $folder=Split-Path $folder -Parent
    if(-not $folder){break}
}
if(-not $dastest){throw "No dastest/dastest.das found above $Daslang."}
$arguments=@('-no-module-cache')
# --persistent-heap: the lifetime tests compare the heap with a baseline, and
#   only this heap gives memory back when a value is deleted.
# --isolated-mode: one process per file, several at a time; a crash or a hang
#   in one test does not take the others with it.
$arguments+=@($dastest,'--','--persistent-heap','--isolated-mode','--timeout',"$TimeoutSec")
if($Quiet){$arguments+='--failures-only'}
if($Names){$arguments+=@('--test-names',$Names)}
foreach($path in $Paths){$arguments+=@('--test',$path)}
Push-Location $PSScriptRoot
try {
    & $Daslang @arguments
    $code=$LASTEXITCODE
} finally { Pop-Location }
if($code -ne 0){throw "dastest reported failures (exit $code)."}
