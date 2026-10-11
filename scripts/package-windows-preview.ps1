param([string]$Version = '0.1.0-preview')
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot/..").Path
$bundle = Join-Path $root "dist/Weaver-$Version-windows-x86_64"
New-Item -ItemType Directory -Force $bundle | Out-Null
Copy-Item -LiteralPath "$root/zig-out/bin/weaver.exe" -Destination $bundle
Copy-Item -LiteralPath "$root/zig-out/licenses" -Destination $bundle -Recurse -Force
Copy-Item -LiteralPath "$root/README.md" -Destination $bundle
Copy-Item -LiteralPath "$root/docs" -Destination $bundle -Recurse -Force
Set-Content -LiteralPath "$bundle/PREVIEW.txt" -Value "Weaver $Version is an unsigned development preview. Git, Git LFS and curl are runtime prerequisites. Signing, platform installers and release credentials require the setup in docs/releases.md."
Compress-Archive -LiteralPath $bundle -DestinationPath "$root/dist/Weaver-$Version-windows-x86_64.zip" -Force
