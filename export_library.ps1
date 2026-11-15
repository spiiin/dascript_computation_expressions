param([Parameter(Mandatory)][string]$Destination,[string[]]$Packages=@('computation','computation_task'))
$ErrorActionPreference='Stop'
$Destination=[IO.Path]::GetFullPath($Destination)
# Never overwrite an application checkout or an earlier export.
if(Test-Path -LiteralPath $Destination){throw 'Destination must be a new directory.'}
foreach($package in $Packages){if($package -notin @('computation','computation_task')){throw "Unknown package: $package"}}
if('computation' -notin $Packages){throw 'The computation package is required: computation_task builds on it.'}
# A package's .das_module names exactly the modules in its folder.
function Get-CePackageModules([string]$Package) {
    $folder=Join-Path $PSScriptRoot "packages/$Package"
    $actual=@(Get-ChildItem $folder -File -Filter '*.das'|ForEach-Object {$_.BaseName}|Sort-Object)
    $descriptor=[IO.File]::ReadAllText((Join-Path $folder '.das_module'))
    $list=[regex]::Match($descriptor,'(?s)_modules = \[(.*?)\]')
    if(-not $list.Success){throw "packages/$Package/.das_module has no module list"}
    $declared=@([regex]::Matches($list.Groups[1].Value,'"(\w+)"')|ForEach-Object {$_.Groups[1].Value}|Sort-Object)
    if(@(Compare-Object $declared $actual).Count){throw "packages/$Package/.das_module does not match the folder"}
    return $actual
}
$modules=[ordered]@{}
foreach($package in $Packages){$modules[$package]=@(Get-CePackageModules $package)}
# The export contains the whole local require closure: a module requires its
# own package by ./name.das and the other one by ../package/name.das.
foreach($package in $Packages) {
    foreach($name in $modules[$package]) {
        $source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot "packages/$package/$name.das"))
        foreach($match in [regex]::Matches($source,'(?m)^require\s+(\.\.?/[\w./]+)')) {
            $dependency=$match.Groups[1].Value
            $owner=$package
            if($dependency -match '^\.\./(\w+)/(\w+)\.das$'){$owner=$Matches[1];$dependency=$Matches[2]}
            elseif($dependency -match '^\./(\w+)\.das$'){$dependency=$Matches[1]}
            else{throw "Unexpected local require in ${package}/${name}: $dependency"}
            if($owner -notin $Packages -or $dependency -notin $modules[$owner]){throw "Missing dependency: $owner/$dependency (from $package/$name)"}
        }
    }
}
# The layout an application uses: packages side by side in its modules/ folder.
$rows=@()
foreach($package in $Packages) {
    $target=Join-Path $Destination "modules/$package"
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    foreach($name in $modules[$package]){Copy-Item -LiteralPath (Join-Path $PSScriptRoot "packages/$package/$name.das") -Destination $target}
    foreach($name in @('.das_module','.das_package')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot "packages/$package/$name") -Destination $target}
    foreach($name in $modules[$package]) {
        $rows+=[pscustomobject]@{File="modules/$package/$name.das";Sha256=(Get-FileHash -LiteralPath (Join-Path $target "$name.das")).Hash}
    }
}
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
$rows | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Destination 'manifest.json')
Write-Host "Exported $($rows.Count) modules of $($Packages -join ', ') and a standalone integration example to $Destination"
