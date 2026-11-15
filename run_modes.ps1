param(
    [ValidateSet('Interpreter','Jit','AotGenerate','All')][string]$Mode='All',
    [string]$Daslang=$env:DASLANG_EXE,
    [switch]$IncludeKnownIssues,
    [string]$OutputDirectory=(Join-Path $PSScriptRoot 'mode-results')
)
. (Join-Path $PSScriptRoot 'source_paths.ps1')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'sdk_paths.ps1')
$Daslang = Resolve-CeDaslang $Daslang
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$rows=[Collections.Generic.List[object]]::new()
$modes=if($Mode -eq 'All'){@('Interpreter','Jit','AotGenerate')}else{@($Mode)}
# This is an explicit cross-mode subset, not the full interpreter regression.
$tests=@((Get-Content (Join-Path $PSScriptRoot 'mode_tests.json') -Raw | ConvertFrom-Json) | ForEach-Object {$_})
Push-Location $PSScriptRoot
try {
    foreach($currentMode in $modes) {
        $files=@($tests)
        foreach($file in $files) {
            $stem="$currentMode-$([IO.Path]::GetFileNameWithoutExtension($file))"
            $log=Join-Path $OutputDirectory ($stem+'.log')
            $cpp=Join-Path $OutputDirectory ($stem+'.cpp')
             $arguments=@((Get-CeSource $file),'-no-module-cache')
            if($currentMode -eq 'Jit'){$arguments+=@('-jit','-jit-no-cache')}
            if($currentMode -eq 'AotGenerate'){$arguments=@('-aot',(Get-CeSource $file),$cpp)}
            $watch=[Diagnostics.Stopwatch]::StartNew()
            & $Daslang @arguments *> $log
            $code=$LASTEXITCODE
            $watch.Stop()
            $status=if($code -eq 0){if($currentMode -eq 'AotGenerate'){'generated_not_executed'}else{'passed'}}else{'failed'}
            $rows.Add([pscustomobject]@{Mode=$currentMode;File=$file;Status=$status;ExitCode=$code;ElapsedMs=$watch.Elapsed.TotalMilliseconds;Log=$log})
            Write-Host "$currentMode $file : $status (exit $code)"
        }
    }
} finally {
    Pop-Location
    [ordered]@{Compiler=$Daslang;CompilerSha256=(Get-FileHash $Daslang).Hash;RecordedAt=[DateTimeOffset]::Now.ToString('o');
        Scope='explicit subset; AOT generation is NOT runtime execution';Results=@($rows.ToArray())} |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'summary.json')
}
if(@($rows | Where-Object Status -eq 'failed').Count){throw 'Unexpected mode failure; see summary.json'}
if($modes -contains 'AotGenerate'){Write-Warning 'AOT C++ generated only. Compile/link into a host with strict AOT linking and run separately before claiming AOT runtime support.'}
