param([string]$Daslang=$env:DASLANG_EXE,[switch]$Jit)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'sdk_paths.ps1')
$Daslang = Resolve-CeDaslang $Daslang
$arguments=@((Join-Path $PSScriptRoot 'tests/test_task_glfw_keyboard.das'),'-no-module-cache')
if($Jit){$arguments+=@('-jit','-jit-no-cache')}
& $Daslang @arguments
if($LASTEXITCODE -ne 0){throw 'GLFW keyboard checks failed'}
& (Join-Path $PSScriptRoot 'run_task_glfw_keyboard.ps1') -Daslang $Daslang -Jit:$Jit -SmokeTest -TimeoutMs 1000
