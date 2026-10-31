# DesignBridge Ferry installer - Windows (macOS/Linux: install.sh).
#
#   irm https://raw.githubusercontent.com/hadelekan/designbridge-releases/main/ferry/install.ps1 | iex
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/hadelekan/designbridge-releases/main/ferry/install.ps1))) -Uninstall
#
# Downloads the compiled ferry.exe, verifies its sha256, puts it in
# %LOCALAPPDATA%\DesignBridge\bin, then hands over to `ferry install` (HKCU Run key +
# designbridge:// scheme) and `ferry wake`. Per-user, no admin.
#
# No code signing needed: Invoke-WebRequest doesn't write the Mark-of-the-Web stream, so
# SmartScreen never prompts (Unblock-File clears it anyway). `irm | iex` isn't a script
# file, so the execution policy doesn't apply either. Exception: Smart App Control blocks
# every unsigned exe - detected and reported below.
#
# Env overrides: FERRY_DOWNLOAD_BASE, FERRY_VERSION (default latest), FERRY_INSTALL_DIR,
# DB_FERRY_TOKEN (same as -Token).
param(
  [string]$Token = $env:DB_FERRY_TOKEN,
  [string]$Version = $(if ($env:FERRY_VERSION) { $env:FERRY_VERSION } else { 'latest' }),
  [switch]$Uninstall
)

function Write-Ferry([string]$Message) { Write-Host "[ferry] $Message" }

function Stop-Ferry([string]$Exe) {
  # A previous daemon locks the exe and would keep serving the old build.
  # Stop-Process returns before the handle is released, so wait for the exit.
  $procs = @(Get-Process -Name ferry -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $Exe })
  foreach ($p in $procs) {
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    $p.WaitForExit(5000) | Out-Null
  }
}

function Set-UserPath([string]$Dir, [bool]$Present) {
  # Raw registry value: [Environment]::GetEnvironmentVariable would expand %VARS% and the
  # write-back would silently rewrite the user's PATH.
  $key = Get-Item 'HKCU:\Environment'
  $raw = $key.GetValue('Path', '', 'DoNotExpandEnvironmentNames')
  $parts = @($raw -split ';' | Where-Object { $_ -and $_ -ne $Dir })
  if ($Present) { $parts += $Dir }
  $next = $parts -join ';'
  if ($next -eq $raw) { return }
  Set-ItemProperty 'HKCU:\Environment' -Name Path -Value $next -Type ExpandString
  # SetEnvironmentVariable broadcasts WM_SETTINGCHANGE so new terminals see the change.
  [Environment]::SetEnvironmentVariable('DESIGNBRIDGE_PATH_REFRESH', '1', 'User')
  [Environment]::SetEnvironmentVariable('DESIGNBRIDGE_PATH_REFRESH', $null, 'User')
}

function Test-SmartAppControl {
  try {
    $state = Get-ItemPropertyValue 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' `
      -Name VerifiedAndReputablePolicyState -ErrorAction Stop
    return $state -eq 1
  } catch { return $false }
}

function Install-Ferry {
  $ErrorActionPreference = 'Stop'
  $ProgressPreference = 'SilentlyContinue' # the PS 5.1 progress bar makes downloads crawl
  [Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

  $base = if ($env:FERRY_DOWNLOAD_BASE) { $env:FERRY_DOWNLOAD_BASE } else { 'https://raw.githubusercontent.com/hadelekan/designbridge-releases/main/ferry' }
  $dir = if ($env:FERRY_INSTALL_DIR) { $env:FERRY_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'DesignBridge\bin' }
  $exe = Join-Path $dir 'ferry.exe'

  if ($Uninstall) {
    if (-not (Test-Path $exe)) { throw "ferry is not installed at $exe" }
    & $exe uninstall
    Stop-Ferry $exe
    Remove-Item $exe -Force
    if (-not (Get-ChildItem $dir -ErrorAction SilentlyContinue)) { Remove-Item $dir -Force }
    # `ferry uninstall` removed its windowless launcher from the parent DesignBridge folder;
    # drop that folder too once it's empty (the default install dir lives inside it).
    $parent = Split-Path $dir -Parent
    if ((Split-Path $parent -Leaf) -eq 'DesignBridge' -and -not (Get-ChildItem $parent -Force -ErrorAction SilentlyContinue)) {
      Remove-Item $parent -Force
    }
    Set-UserPath $dir $false
    Write-Ferry 'ferry removed'
    return
  }

  # x64 only: Windows on ARM runs it under emulation.
  if (-not [Environment]::Is64BitOperatingSystem) { throw 'ferry needs 64-bit Windows' }
  $asset = 'ferry-windows-x64.exe'

  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("ferry-" + [guid]::NewGuid())
  New-Item -ItemType Directory -Path $tmp | Out-Null
  try {
    Write-Ferry "downloading $asset ($Version)"
    Invoke-WebRequest -UseBasicParsing -Uri "$base/$Version/$asset" -OutFile (Join-Path $tmp $asset)
    Invoke-WebRequest -UseBasicParsing -Uri "$base/$Version/SHA256SUMS" -OutFile (Join-Path $tmp 'SHA256SUMS')

    $line = Get-Content (Join-Path $tmp 'SHA256SUMS') |
      Where-Object { ($_ -split '\s+')[1] -eq $asset } | Select-Object -First 1
    if (-not $line) { throw "$asset is not listed in SHA256SUMS" }
    $expected = ($line -split '\s+')[0]
    $actual = (Get-FileHash (Join-Path $tmp $asset) -Algorithm SHA256).Hash.ToLower()
    if ($expected -ne $actual) { throw "checksum mismatch for $asset (expected $expected, got $actual)" }

    Stop-Ferry $exe
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    if (Test-Path $exe) { Remove-Item $exe -Force }
    Move-Item (Join-Path $tmp $asset) $exe
    Unblock-File $exe
  } finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }

  if (Test-SmartAppControl) {
    Write-Ferry 'Smart App Control is on and blocks unsigned apps - ferry may not start.'
  }

  # `ferry install` registers its own absolute path, so it must run from the final location.
  if ($Token) { & $exe install --token $Token } else { & $exe install }
  if ($LASTEXITCODE -ne 0) { throw "ferry install failed (exit $LASTEXITCODE)" }

  & $exe wake *> $null
  if ($LASTEXITCODE -eq 0) {
    Write-Ferry 'ferry is running - click Connect in the Figma plugin (Account -> Local connections)'
  } else {
    Write-Ferry "installed, but it did not start: run & '$exe' status to see why"
  }

  Set-UserPath $dir $true
}

Install-Ferry
