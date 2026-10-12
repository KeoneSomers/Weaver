# Packs zig-out into an MSIX for the Microsoft Store; see docs/microsoft-store.md.
# The package is left unsigned: the Store signs it after certification.
param(
    [string]$Version = '0.1.0',
    [int]$Build = 0,
    [string]$IdentityName,
    [string]$Publisher,
    [string]$PublisherDisplayName,
    [string]$Output
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot/..").Path
if (-not $Output) { $Output = Join-Path $root 'dist/Weaver-windows-x86_64.msix' }

# Without the identity Partner Center assigned, the package still builds and runs locally
# but the Store rejects the upload.
if (-not ($IdentityName -and $Publisher -and $PublisherDisplayName)) {
    Write-Warning 'Store identity not set; packaging with a development identity that cannot be submitted.'
    $IdentityName = 'Weaver.Development'
    $Publisher = 'CN=Weaver Development'
    $PublisherDisplayName = 'Weaver'
}

# The Store requires a non-zero first part and reserves the fourth, so 0.1.0 build 57
# becomes 1.1.57.0. The build number keeps every package newer than the last.
if ($Version -notmatch '^(\d+)\.(\d+)\.\d+') { throw "Version '$Version' is not major.minor.patch" }
$major = [int]$Matches[1] + 1
$minor = [int]$Matches[2]
if ($major -gt 65535 -or $minor -gt 65535 -or $Build -lt 0 -or $Build -gt 65535) { throw 'Each part of an MSIX version must be between 0 and 65535' }
$packageVersion = "$major.$minor.$Build.0"

$kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10/bin'
$sdk = Get-ChildItem -Path $kits -Directory -Filter '10.*' -ErrorAction SilentlyContinue |
    Where-Object { (Test-Path "$($_.FullName)/x64/makeappx.exe") -and (Test-Path "$($_.FullName)/x64/makepri.exe") } |
    Sort-Object { [version]$_.Name } | Select-Object -Last 1
if (-not $sdk) { throw 'makeappx.exe and makepri.exe were not found; install the Windows SDK' }
$makeappx = Join-Path $sdk.FullName 'x64/makeappx.exe'
$makepri = Join-Path $sdk.FullName 'x64/makepri.exe'

$work = Join-Path $root 'dist/msix'
$layout = Join-Path $work 'layout'
if (Test-Path $work) { Remove-Item -LiteralPath $work -Recurse -Force }
New-Item -ItemType Directory -Force $layout | Out-Null
Copy-Item -LiteralPath "$root/zig-out/bin/weaver.exe" -Destination $layout
Copy-Item -LiteralPath "$root/zig-out/licenses" -Destination $layout -Recurse
Copy-Item -LiteralPath "$root/packaging/windows/msix/Assets" -Destination $layout -Recurse

$manifest = [IO.File]::ReadAllText("$root/packaging/windows/msix/AppxManifest.xml")
$values = @{ IDENTITY_NAME = $IdentityName; PUBLISHER = $Publisher; PUBLISHER_DISPLAY_NAME = $PublisherDisplayName; VERSION = $packageVersion }
foreach ($key in $values.Keys) { $manifest = $manifest.Replace("{{$key}}", [Security.SecurityElement]::Escape($values[$key])) }
[IO.File]::WriteAllText("$layout/AppxManifest.xml", $manifest)

# resources.pri maps each logo named in the manifest to its scale and target-size variants.
# The default configuration splits resources into per-scale packs; one package needs one index.
$config = Join-Path $work 'priconfig.xml'
& $makepri createconfig /cf $config /dq en-US /pv 10.0.0 /o | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'makepri createconfig failed' }
$xml = [xml](Get-Content -LiteralPath $config -Raw)
foreach ($node in @($xml.SelectNodes('//packaging'))) { [void]$node.ParentNode.RemoveChild($node) }
$xml.Save($config)
& $makepri new /pr $layout /cf $config /mn "$layout/AppxManifest.xml" /of "$layout/resources.pri" /o | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'makepri new failed' }

New-Item -ItemType Directory -Force (Split-Path -Parent $Output) | Out-Null
& $makeappx pack /d $layout /p $Output /o | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'makeappx pack failed' }
Write-Host "Packaged $Output as $IdentityName $packageVersion"
