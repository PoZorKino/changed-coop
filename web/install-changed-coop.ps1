# Changed Co-op - online co-op mod for Changed (Steam), installer.
#   Install / update:  irm https://tool.dexx.moe/install-changed-coop.ps1 | iex
#   Uninstall:         $coopUninstall=1; irm https://tool.dexx.moe/install-changed-coop.ps1 | iex
#   Custom folder:     $coopGame='D:\Games\Changed'; irm https://tool.dexx.moe/install-changed-coop.ps1 | iex
function Install-ChangedCoop {
  $ErrorActionPreference = 'Stop'
  $zipUrl = 'https://tool.dexx.moe/changed-coop.zip'

  function Find-Changed {
    if ($coopGame) { return $coopGame }
    $roots = @()
    foreach ($k in 'HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam') {
      $p = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
      if ($p.SteamPath) { $roots += $p.SteamPath }
      if ($p.InstallPath) { $roots += $p.InstallPath }
    }
    $libs = @()
    foreach ($r in $roots | Select-Object -Unique) {
      $libs += $r
      $vdf = Join-Path $r 'steamapps\libraryfolders.vdf'
      if (Test-Path -LiteralPath $vdf) {
        foreach ($m in [regex]::Matches((Get-Content -LiteralPath $vdf -Raw), '"path"\s+"([^"]+)"')) {
          $libs += $m.Groups[1].Value -replace '\\\\', '\'
        }
      }
    }
    foreach ($l in $libs | Select-Object -Unique) {
      $g = Join-Path $l 'steamapps\common\Changed'
      if (Test-Path -LiteralPath (Join-Path $g 'Game.rgss2a')) { return $g }
    }
    return $null
  }

  $game = Find-Changed
  if (-not $game) {
    Write-Host 'Could not find Changed in your Steam libraries.' -ForegroundColor Yellow
    Write-Host "Run again with the folder set, e.g.:  `$coopGame='D:\SteamLibrary\steamapps\common\Changed'; irm https://tool.dexx.moe/install-changed-coop.ps1 | iex"
    return
  }
  Write-Host "Changed found: $game"
  if (Get-Process -Name Game -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$game*" }) {
    Write-Host 'Close the game first, then run this again.' -ForegroundColor Yellow
    return
  }

  $tmp = Join-Path $env:TEMP ('changed-coop-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $tmp | Out-Null
  try {
    $zip = Join-Path $tmp 'changed-coop.zip'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing -Uri $zipUrl -OutFile $zip
    Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $tmp 'coop-install.ps1'), '-Game', $game)
    if ($coopUninstall) { $psArgs += '-Uninstall' } else { $psArgs += @('-Source', (Join-Path $tmp 'Coop')) }
    & powershell.exe @psArgs
    if ($LASTEXITCODE -eq 0 -and -not $coopUninstall) {
      Write-Host ''
      Write-Host 'Done. Start Changed from Steam and pick CO-OP on the title screen.' -ForegroundColor Green
      Write-Host 'Host: Host game -> tell friends the Room code.  Friends: type the Room code -> Join game.'
    }
  } finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
}
Install-ChangedCoop
