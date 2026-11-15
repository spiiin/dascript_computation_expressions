# Shared by runners, never changes the caller's working directory.
$script:CeSourceRoot=$PSScriptRoot
function Get-CeSource([string]$File) {
    foreach($folder in @('','packages/computation','packages/computation_task','examples','examples/builders','tests','tests/repro','support','benchmarks')) {
        $candidate=Join-Path (Join-Path $script:CeSourceRoot $folder) $File
        if(Test-Path -LiteralPath $candidate -PathType Leaf){return [IO.Path]::GetFullPath($candidate)}
    }
    throw "CE source not found: $File"
}
