param([Parameter(Mandatory)][string]$Destination)
$ErrorActionPreference='Stop'
$Destination=[IO.Path]::GetFullPath($Destination)
# Never overwrite an application checkout or an earlier export.
if(Test-Path -LiteralPath $Destination){throw 'Destination must be a new directory.'}
$modules=@(Get-Content (Join-Path $PSScriptRoot 'public_modules.json') -Raw | ConvertFrom-Json)
$actual=@(Get-ChildItem (Join-Path $PSScriptRoot 'lib') -File -Filter '*.das'|Select-Object -ExpandProperty Name)
if(@(Compare-Object $modules $actual).Count){throw 'public_modules.json does not match lib/'}
foreach($name in $modules) {
    if([IO.Path]::GetFileName($name) -ne $name -or -not(Test-Path -LiteralPath (Join-Path $PSScriptRoot ("lib/"+$name)))){throw "Invalid module: $name"}
}
# Verify that the distribution contains the transitive local require closure.
foreach($name in $modules) {
    foreach($match in [regex]::Matches([IO.File]::ReadAllText((Join-Path $PSScriptRoot ("lib/"+$name))),'(?m)^require\s+([\w./]+)')) {
        $dependency=$match.Groups[1].Value
        if($dependency.StartsWith('daslib/') -or $dependency -eq 'strings' -or $dependency -eq 'math' -or $dependency -eq 'dashv/dashv_boost'){continue}
        $dependency=[IO.Path]::GetFileNameWithoutExtension($dependency)+'.das'
        if($dependency -notin $modules){throw "Missing public dependency: $dependency (from $name)"}
    }
}
New-Item -ItemType Directory -Path (Join-Path $Destination 'lib') -Force | Out-Null
foreach($name in $modules){Copy-Item -LiteralPath (Join-Path $PSScriptRoot ("lib/"+$name)) -Destination (Join-Path $Destination 'lib')}
foreach($name in @('main.das','identity_builder.das')){
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "integration_example/$name") -Destination $Destination
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'INTEGRATION.md') -Destination (Join-Path $Destination 'README.md')
foreach($name in @('INTEGRATION.md','PUBLIC_API.md','COMPUTATION.md','CE_SEMANTICS.md','BUILDER_PROTOCOL.md','RELIABILITY.md')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $Destination
}
New-Item -ItemType Directory -Path (Join-Path $Destination 'aot_host') -Force | Out-Null
foreach($name in @('main.cpp','CMakeLists.txt','recover_064.h')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "aot_host/$name") -Destination (Join-Path $Destination "aot_host/$name")
}
# References to examples/tests remain useful in the compact distribution.
foreach($document in Get-ChildItem -LiteralPath $Destination -Filter '*.md' -File) {
    $content=[IO.File]::ReadAllText($document.FullName)
    $content=[regex]::Replace($content,'\[([^\]]+)\]\(([^)]+)\)',{
        param($match)
        $target=$match.Groups[2].Value
        $file=($target -split '#',2)[0]
        if($file -and $target -notmatch '^[a-z]+:' -and -not(Test-Path -LiteralPath (Join-Path $Destination $file))) {
            return '['+$match.Groups[1].Value+'](https://github.com/spiiin/dascript_computation_expressions/blob/main/'+$target+')'
        }
        return $match.Value
    })
    [IO.File]::WriteAllText($document.FullName,$content)
}
$modules | ForEach-Object {[pscustomobject]@{File="lib/$_";Sha256=(Get-FileHash -LiteralPath (Join-Path $Destination "lib/$_")).Hash}} |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Destination 'manifest.json')
Write-Host "Exported $($modules.Count) library modules and a standalone integration example to $Destination"
