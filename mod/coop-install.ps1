# Changed Co-op installer / uninstaller.
# RGSS2 only loads the Scripts file from inside Game.rgss2a when the archive exists, so we APPEND one
# small entry (Coop\Boot.rvdata, our own bootstrap) to the end of the user's archive. The original bytes
# are untouched; uninstall truncates the archive back to its recorded original length.
param(
  [Parameter(Mandatory = $true)][string]$Game,
  [string]$Source = '',      # folder holding coop.rb / Boot.rvdata / coop.ini to copy into <Game>\Coop
  [switch]$Uninstall
)
$ErrorActionPreference = 'Stop'
$arc = Join-Path $Game 'Game.rgss2a'
$ini = Join-Path $Game 'Game.ini'
$coopDir = Join-Path $Game 'Coop'
$lenFile = Join-Path $coopDir 'archive.len'
$entryName = 'Coop\Boot.rvdata'

function Next-Key([uint64]$k) { return (($k * 7 + 3) -band [uint64]4294967295) }

function Scan-Archive([byte[]]$b) {
  if ([Text.Encoding]::ASCII.GetString($b, 0, 6) -ne 'RGSSAD' -or $b[7] -ne 1) { throw 'Not an RGSSAD v1 (.rgss2a) archive' }
  $pos = 8; [uint64]$key = [uint64]3735931646; $names = @{}
  while ($pos -lt $b.Length) {
    $start = $pos
    $len = [BitConverter]::ToUInt32($b, $pos) -bxor $key; $pos += 4; $key = Next-Key $key
    $nb = New-Object byte[] $len
    for ($i = 0; $i -lt $len; $i++) { $nb[$i] = $b[$pos + $i] -bxor ($key -band 0xFF); $key = Next-Key $key }
    $pos += $len
    $size = [BitConverter]::ToUInt32($b, $pos) -bxor $key; $pos += 4; $key = Next-Key $key
    $pos += $size
    $names[[Text.Encoding]::ASCII.GetString($nb)] = $start
  }
  return @{ Key = $key; Names = $names }
}

function Set-Scripts([string]$value) {
  $lines = Get-Content -LiteralPath $ini
  $lines = $lines | ForEach-Object { if ($_ -match '^Scripts=') { "Scripts=$value" } else { $_ } }
  Set-Content -LiteralPath $ini -Value $lines -Encoding ASCII
}

if (-not (Test-Path -LiteralPath $arc)) { throw "Game.rgss2a not found in $Game" }

if (-not $Uninstall -and $Source -and ((Resolve-Path $Source).Path -ne (Resolve-Path $coopDir -ErrorAction SilentlyContinue).Path)) {
  New-Item -ItemType Directory -Force -Path $coopDir | Out-Null
  Copy-Item -LiteralPath (Join-Path $Source 'coop.rb') -Destination $coopDir -Force
  Copy-Item -LiteralPath (Join-Path $Source 'Boot.rvdata') -Destination $coopDir -Force
  if (-not (Test-Path -LiteralPath (Join-Path $coopDir 'coop.ini'))) {
    Copy-Item -LiteralPath (Join-Path $Source 'coop.ini') -Destination $coopDir
  }
}

$bytes = [IO.File]::ReadAllBytes($arc)
$scan = Scan-Archive $bytes

# Remove a previous install: truncate only if our entry really sits at the end of the archive.
# (If Steam replaced Game.rgss2a in the meantime, our entry is simply gone and nothing is truncated.)
if ($scan.Names.ContainsKey($entryName)) {
  $orig = [int64]$scan.Names[$entryName]
  $fs = [IO.File]::Open($arc, 'Open', 'ReadWrite')
  try { $fs.SetLength($orig) } finally { $fs.Close() }
  $bytes = [IO.File]::ReadAllBytes($arc)
  $scan = Scan-Archive $bytes
}
if (Test-Path -LiteralPath $lenFile) { Remove-Item -LiteralPath $lenFile }

if ($Uninstall) {
  Set-Scripts 'Data\Scripts.rvdata'
  Write-Host 'Changed Co-op removed: Game.rgss2a and Game.ini are back to normal. You can delete the Coop folder.'
  return
}

$boot = [IO.File]::ReadAllBytes((Join-Path $coopDir 'Boot.rvdata'))
[uint64]$key = $scan.Key
$out = New-Object IO.MemoryStream
$nameBytes = [Text.Encoding]::ASCII.GetBytes($entryName)
$out.Write([BitConverter]::GetBytes([uint32]($nameBytes.Length -bxor $key)), 0, 4); $key = Next-Key $key
foreach ($c in $nameBytes) { $out.WriteByte([byte]($c -bxor ($key -band 0xFF))); $key = Next-Key $key }
$out.Write([BitConverter]::GetBytes([uint32]($boot.Length -bxor $key)), 0, 4); $key = Next-Key $key
[uint64]$dk = $key
$enc = New-Object byte[] $boot.Length
for ($i = 0; $i -lt $boot.Length; $i += 4) {
  $kb = [BitConverter]::GetBytes([uint32]$dk)
  for ($j = 0; $j -lt 4 -and ($i + $j) -lt $boot.Length; $j++) { $enc[$i + $j] = $boot[$i + $j] -bxor $kb[$j] }
  $dk = Next-Key $dk
}
$out.Write($enc, 0, $enc.Length)

Set-Content -LiteralPath $lenFile -Value $bytes.Length -Encoding ASCII
$fs = [IO.File]::Open($arc, 'Append', 'Write')
try { $data = $out.ToArray(); $fs.Write($data, 0, $data.Length) } finally { $fs.Close() }
Set-Scripts 'Coop\Boot.rvdata'
Write-Host "Changed Co-op installed ($($data.Length) bytes appended to Game.rgss2a, original length $($bytes.Length) saved)."
