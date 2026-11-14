param([string]$Daslang=$env:DASLANG_EXE,[switch]$Jit,[switch]$Example)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'sdk_paths.ps1')
$Daslang = Resolve-CeDaslang $Daslang
$arguments=@((Join-Path $PSScriptRoot 'support/task_tcp_fixture.py'),'--daslang',$Daslang)
if($Jit){$arguments+='--jit'}
if($Example){$arguments+=@('--script',(Join-Path $PSScriptRoot 'examples/task_tcp_demo.das'))}
& python @arguments
if($LASTEXITCODE -ne 0){throw 'Real TCP Task checks failed'}
