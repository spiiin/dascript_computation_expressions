param(
    [string]$Daslang=$env:DASLANG_EXE,
    [ValidateRange(100,600000)][int]$TimeoutMs=15000,
    [switch]$Jit
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'sdk_paths.ps1')
$Daslang = Resolve-CeDaslang $Daslang
$arguments=@((Join-Path $PSScriptRoot 'support/task_keyboard_console.py'),
    '--daslang',$Daslang,'--script',(Join-Path $PSScriptRoot 'examples/task_keyboard_demo.das'),
    '--timeout-ms',"$TimeoutMs")
if($Jit){$arguments+='--jit'}
& python @arguments
if($LASTEXITCODE -ne 0){throw 'Interactive Task keyboard demo failed'}
