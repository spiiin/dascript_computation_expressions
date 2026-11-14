param([string]$Daslang=$env:DASLANG_EXE,[switch]$Jit)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'sdk_paths.ps1')
$Daslang = Resolve-CeDaslang $Daslang
$arguments=@((Join-Path $PSScriptRoot 'support/task_http_fixture.py'),'--daslang',$Daslang)
if($Jit){$arguments+='--jit'}
& python @arguments
if($LASTEXITCODE -ne 0){throw 'Task HTTP checks failed'}
