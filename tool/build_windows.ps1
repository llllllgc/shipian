$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)

function Run-Flutter {
    param([string[]]$FlutterArgs)
    & flutter @FlutterArgs
    if ($LASTEXITCODE -ne 0) { throw "flutter command failed: $FlutterArgs" }
}

Run-Flutter -FlutterArgs @('pub', 'get')
Run-Flutter -FlutterArgs @('analyze')
Run-Flutter -FlutterArgs @('test')
Run-Flutter -FlutterArgs @('build', 'windows', '--release')
$release = 'build/windows/x64/runner/Release'
if (-not (Test-Path $release)) { throw 'The x64 Release directory was not generated.' }
New-Item -ItemType Directory -Force -Path 'dist' | Out-Null
Compress-Archive -Path "$release/*" -DestinationPath 'dist/ShiPian-Windows-x64.zip' -Force
Write-Host 'Created dist/ShiPian-Windows-x64.zip. Distribute the full bundle, not the EXE alone.'
