param([string]$Zig = "$env:USERPROFILE/.zvm/0.17.0/zig.exe")
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot/..").Path
Set-Location $root
$env:ZIG_GLOBAL_CACHE_DIR = Join-Path $root '.zig-cache/global'
if (!(Test-Path $Zig)) { throw 'Install Zig 0.17.0 using zvm install 0.17.0, then pass -Zig <path>.' }
New-Item -ItemType Directory -Force vendor,.tools | Out-Null
if (!(Test-Path vendor/knots/build.zig)) {
    git clone https://github.com/knots-ui/knots.git vendor/knots
    if ($LASTEXITCODE) { throw 'Knots download failed' }
    git -C vendor/knots checkout 88bd83b4dc79f3178c9ca5345d5cb3c1c536f58f
    if ($LASTEXITCODE) { throw 'Knots checkout failed' }
}
foreach ($patchName in @('knots-native-dialogs.patch', 'knots-owned-completions.patch', 'knots-pointer-targets.patch')) {
    $knotsPatch = Join-Path $root "patches/$patchName"
    git -C vendor/knots apply --reverse --check $knotsPatch 2>$null
    if ($LASTEXITCODE) {
        git -C vendor/knots apply --check $knotsPatch
        if ($LASTEXITCODE) { throw "Knots patch does not match the pinned source: $patchName" }
        git -C vendor/knots apply $knotsPatch
        if ($LASTEXITCODE) { throw "Knots patch failed: $patchName" }
    }
}
if (!(Test-Path vendor/libgit2/CMakeLists.txt)) {
    git clone --depth 1 --branch v1.9.7 https://github.com/libgit2/libgit2.git vendor/libgit2
    if ($LASTEXITCODE) { throw 'libgit2 download failed' }
}
if (!(Test-Path vendor/nfd/src/include/nfd.h)) {
    git clone --depth 1 --branch v1.4.1 https://github.com/btzy/nativefiledialog-extended.git vendor/nfd
    if ($LASTEXITCODE) { throw 'Native file dialog download failed' }
}
if ((git -C vendor/nfd rev-parse HEAD) -ne '65b2f070a0fcfee0d453a64e770a217ab0b6ff4f') { throw 'Native file dialog revision differs from the pinned version' }
$cmake = if (Test-Path .tools/python/cmake/data/bin/cmake.exe) { (Resolve-Path .tools/python/cmake/data/bin/cmake.exe).Path } else { 'cmake' }
$ninja = if (Test-Path .tools/python/bin/ninja.exe) { (Resolve-Path .tools/python/bin/ninja.exe).Path } else { 'ninja' }
$compiler = Join-Path $root .tools/zig-cc.cmd
Set-Content -LiteralPath $compiler -Value "@echo off`r`n`"$Zig`" cc -fno-sanitize=undefined %*" -Encoding ascii
$dlltool = Join-Path $root .tools/dlltool.cmd
$archiver = Join-Path $root .tools/zig-ar.cmd
Set-Content -LiteralPath $dlltool -Value "@echo off`r`n`"$Zig`" dlltool %*" -Encoding ascii
Set-Content -LiteralPath $archiver -Value "@echo off`r`n`"$Zig`" ar %*" -Encoding ascii
# Zig's RC frontend downloads an additional compiler package. DLL version resources
# are optional; avoid requiring windres for the bundled libgit2 dependency.
$gitCmake = Join-Path $root vendor/libgit2/src/libgit2/CMakeLists.txt
$gitCmakeText = Get-Content -LiteralPath $gitCmake -Raw
$gitCmakeText = $gitCmakeText.Replace('if(WIN32 AND NOT CYGWIN)', 'if(WIN32 AND NOT CYGWIN AND NOT WEAVER_SKIP_RC)')
Set-Content -LiteralPath $gitCmake -Value $gitCmakeText -NoNewline
& $cmake -S vendor/libgit2 -B .tools/git2-build -G Ninja "-DCMAKE_MAKE_PROGRAM=$ninja" "-DCMAKE_C_COMPILER=$compiler" "-DCMAKE_AR=$archiver" "-DDLLTOOL=$dlltool" "-DCMAKE_INSTALL_PREFIX=$root/.tools/git2" -DCMAKE_BUILD_TYPE=Release -DWEAVER_SKIP_RC=ON -DBUILD_TESTS=OFF -DBUILD_CLI=OFF -DBUILD_EXAMPLES=OFF -DUSE_BUNDLED_ZLIB=ON -DREGEX_BACKEND=builtin -DUSE_SSH=exec -DUSE_HTTPS=WinHTTP
if ($LASTEXITCODE) { throw 'libgit2 configuration failed' }
& $cmake --build .tools/git2-build --parallel 4
if ($LASTEXITCODE) { throw 'libgit2 build failed' }
& $cmake --install .tools/git2-build
if ($LASTEXITCODE) { throw 'libgit2 installation failed' }
if (Test-Path .tools/git2/lib/libgit2.dll.a) { Copy-Item -LiteralPath .tools/git2/lib/libgit2.dll.a -Destination .tools/git2/lib/git2.lib }
Write-Host 'Dependencies ready. Build with zig build; run with zig build run.'
