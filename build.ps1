# build.ps1 -- package game/ (recursively, so assets/ subfolders are included)
# into game.love, then fuse it onto love.exe to produce the distributable
# dist/YuGiOhRecompLauncher.exe. Run from anywhere:  powershell -File build.ps1
$ErrorActionPreference = 'Stop'
$root = 'C:\games\ygo-recomp-launcher'
$src  = Join-Path $root 'game'
$love = Join-Path $root 'game.love'
$exe  = Join-Path $root 'dist\YuGiOhRecompLauncher.exe'

# don't clobber a running instance
try { Stop-Process -Name 'YuGiOhRecompLauncher' -Force -ErrorAction Stop } catch {}

Add-Type -AssemblyName System.IO.Compression
$srcFull = (Resolve-Path $src).Path
$fs  = [System.IO.File]::Open($love, [System.IO.FileMode]::Create)
$zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
foreach ($f in (Get-ChildItem -Recurse -File $src)) {
    $rel = $f.FullName.Substring($srcFull.Length + 1) -replace '\\', '/'
    $e = $zip.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Optimal)
    $s = $e.Open()
    $b = [System.IO.File]::ReadAllBytes($f.FullName)
    $s.Write($b, 0, $b.Length); $s.Dispose()
}
$zip.Dispose(); $fs.Close()

$loveBytes = [System.IO.File]::ReadAllBytes((Join-Path $root 'runtime\love.exe'))
$gameBytes = [System.IO.File]::ReadAllBytes($love)
$out = New-Object byte[] ($loveBytes.Length + $gameBytes.Length)
[System.Array]::Copy($loveBytes, 0, $out, 0, $loveBytes.Length)
[System.Array]::Copy($gameBytes, 0, $out, $loveBytes.Length, $gameBytes.Length)
[System.IO.File]::WriteAllBytes($exe, $out)

Write-Output ("game.love: " + [math]::Round((Get-Item $love).Length/1KB,1) + " KB")
Write-Output ("dist exe:  " + [math]::Round((Get-Item $exe).Length/1KB,1) + " KB")
Write-Output "packed files:"
Get-ChildItem -Recurse -File $src | ForEach-Object { "  " + $_.FullName.Substring($srcFull.Length+1) }
