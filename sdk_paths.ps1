# Resolve once, before changing directories or invoking Python fixtures.
function Resolve-CeDaslang([string]$Daslang = $env:DASLANG_EXE) {
    if (-not $Daslang) {
        $command = Get-Command daslang.exe, daslang -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) { $Daslang = $command.Source }
        else { throw 'Specify -Daslang, set DASLANG_EXE, or add daslang to PATH. See README.md for SDK installation.' }
    }
    if (Test-Path -LiteralPath $Daslang -PathType Leaf) {
        return (Resolve-Path -LiteralPath $Daslang).Path
    }
    $command = Get-Command $Daslang -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    throw "Daslang executable not found: $Daslang"
}
