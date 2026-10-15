#Requires -Version 5.1
<#
.SYNOPSIS
  Repairs common FTC/PedroPathing Gradle issues on Windows.
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\repair_ftc_pedro_windows.ps1
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\repair_ftc_pedro_windows.ps1 -GradleVersion 8.10.2 -RefreshDependencies
#>
[CmdletBinding()]
param(
  [string]$ProjectPath = (Get-Location).Path,
  [string]$GradleVersion,
  [switch]$RefreshDependencies,
  [switch]$SkipBuild,
  [switch]$InstallSdk
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
function Say($message) { Write-Host "[FTC Repair] $message" -ForegroundColor Cyan }
function Warn($message) { Write-Warning $message }
function Find-JavaHome {
  $candidates = @($env:JAVA_HOME, $env:STUDIO_JDK, "$env:ProgramFiles\Android\Android Studio\jbr", "$env:ProgramFiles\Microsoft\jdk-17", "$env:ProgramFiles\Eclipse Adoptium")
  foreach ($candidate in $candidates) {
    if (-not $candidate -or -not (Test-Path $candidate)) { continue }
    if (Test-Path (Join-Path $candidate 'bin\java.exe')) { return $candidate }
    if (Test-Path $candidate -PathType Container) {
      $found = Get-ChildItem $candidate -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName 'bin\java.exe') } | Select-Object -First 1
      if ($found) { return $found.FullName }
    }
  }
  return $null
}
function Find-Sdk {
  foreach ($p in @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT, "$env:LOCALAPPDATA\Android\Sdk")) {
    if ($p -and (Test-Path $p -PathType Container)) { return (Resolve-Path $p).Path }
  }
  return $null
}
function Backup-IfPresent($path) {
  if (Test-Path $path) {
    $target = "$path.bak-$stamp"
    Copy-Item -LiteralPath $path -Destination $target -Force
    Say "Backup: $target"
  }
}
function Run-Native([string]$exe, [string[]]$arguments) {
  $oldPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try { & $exe @arguments 2>&1 | Tee-Object -FilePath $log -Append } finally { $ErrorActionPreference = $oldPreference }
  if ($LASTEXITCODE -ne 0) { throw "Command failed (exit $LASTEXITCODE): $exe $($arguments -join ' ')" }
}
$ProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path
if (-not ((Test-Path (Join-Path $ProjectPath 'settings.gradle')) -or (Test-Path (Join-Path $ProjectPath 'settings.gradle.kts')))) {
  throw "Not an FTC Gradle project root: $ProjectPath. Pass -ProjectPath pointing at the directory containing settings.gradle."
}
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $ProjectPath "ftc-gradle-repair-$stamp.log"
Start-Transcript -Path $log -Append | Out-Null
try {
  Set-Location $ProjectPath
  Say "Project: $ProjectPath"
  $jdk = Find-JavaHome
  if ($jdk) {
    $env:JAVA_HOME = $jdk
    $env:PATH = "$(Join-Path $jdk 'bin');$env:PATH"
    Say "Java: $jdk"
    & (Join-Path $jdk 'bin\java.exe') -version 2>&1 | Out-Host
  } else {
    Warn 'No JDK found. Install Android Studio (bundled JBR), or JDK 17 compatible with your Android Gradle Plugin.'
  }
  $sdk = Find-Sdk
  if ($sdk) {
    Say "Android SDK: $sdk"
    $env:ANDROID_HOME = $sdk
    $localProps = Join-Path $ProjectPath 'local.properties'
    $escapedSdk = ($sdk -replace '\\','/') -replace ':','\\:'
    $line = "sdk.dir=$escapedSdk"
    if (Test-Path $localProps) {
      $existing = Get-Content $localProps
      $currentSdk = @($existing | Where-Object { $_ -match '^\s*sdk\.dir\s*=' })
      if ($currentSdk.Count -eq 0) {
        Backup-IfPresent $localProps
        Add-Content -Path $localProps -Value $line
        Say 'Added sdk.dir to local.properties'
      } else {
        Say 'local.properties already has sdk.dir (left unchanged).'
      }
    } else {
      Set-Content -Path $localProps -Value $line -Encoding ASCII
      Say 'Created local.properties'
    }
    if ($InstallSdk) {
      $sdkManager = Join-Path $sdk 'cmdline-tools\latest\bin\sdkmanager.bat'
      if (Test-Path $sdkManager) {
        Say 'Listing SDK packages; install project-required platforms/build-tools using sdkmanager as needed.'
        & $sdkManager '--list_installed' | Out-Host
      } else { Warn 'sdkmanager not found. Install Android SDK Command-line Tools in Android Studio SDK Manager.' }
    }
  } else { Warn 'Android SDK not found. Install/configure it in Android Studio -> SDK Manager.' }

  $wrapperDir = Join-Path $ProjectPath 'gradle\wrapper'
  $props = Join-Path $wrapperDir 'gradle-wrapper.properties'
  $wrapperJar = Join-Path $wrapperDir 'gradle-wrapper.jar'
  $wrapperBat = Join-Path $ProjectPath 'gradlew.bat'
  $wrapperSh = Join-Path $ProjectPath 'gradlew'
  $existingVersion = $null
  if (Test-Path $props) {
    $distributionLine = Get-Content $props | Where-Object { $_ -match '^\s*distributionUrl\s*=' } | Select-Object -First 1
    if ($distributionLine -and $distributionLine -match 'gradle-([0-9]+\.[0-9]+(?:\.[0-9]+)?)-(?:bin|all)\.zip') {
      $existingVersion = $Matches[1]
      Say "Configured Gradle: $existingVersion"
    }
  }
  if ($GradleVersion -and $existingVersion -and $GradleVersion -ne $existingVersion) {
    throw "Requested Gradle $GradleVersion differs from existing wrapper $existingVersion. Refusing automatic upgrade/downgrade. Edit the project configuration intentionally first."
  }
  $version = if ($existingVersion) { $existingVersion } else { $GradleVersion }
  $missing = @()
  if (-not (Test-Path $wrapperBat)) { $missing += 'gradlew.bat' }
  if (-not (Test-Path $wrapperSh)) { $missing += 'gradlew' }
  if (-not (Test-Path $wrapperJar)) { $missing += 'gradle-wrapper.jar' }
  if (-not (Test-Path $props)) { $missing += 'gradle-wrapper.properties' }
  if ($missing.Count -gt 0) {
    Say "Missing wrapper components: $($missing -join ', ')"
    if (-not $version) { throw 'Gradle version unknown. Supply -GradleVersion X.Y.Z matching the Android Gradle Plugin version in your project.' }
    if ($version -notmatch '^\d+\.\d+(?:\.\d+)?$') { throw 'Invalid Gradle version.' }
    if (-not $jdk) { throw 'Cannot generate wrapper without Java. Install Android Studio/JDK and retry.' }
    $temp = Join-Path $env:TEMP "ftc-gradle-repair-$stamp"
    New-Item -ItemType Directory -Force -Path $temp | Out-Null
    try {
      $zip = Join-Path $temp "gradle-$version-bin.zip"
      $url = "https://services.gradle.org/distributions/gradle-$version-bin.zip"
      Say "Downloading official Gradle distribution $version"
      Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
      $checksumUrl = "$url.sha256"
      try {
        $expected = ((Invoke-WebRequest -Uri $checksumUrl -UseBasicParsing).Content.Trim() -split '\s+')[0].ToLowerInvariant()
        $actual = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($expected -ne $actual) { throw 'Gradle distribution SHA256 mismatch!' }
        Say 'Official SHA256 checksum verified.'
      } catch { throw "Unable to verify Gradle distribution: $_" }
      Expand-Archive -Path $zip -DestinationPath $temp -Force
      $gradleExe = Join-Path $temp "gradle-$version\bin\gradle.bat"
      if (-not (Test-Path $gradleExe)) { throw 'Downloaded Gradle distribution has no gradle.bat.' }
      foreach ($f in @($wrapperBat, $wrapperSh, $wrapperJar, $props)) { Backup-IfPresent $f }
      Say 'Regenerating wrapper through the official Gradle :wrapper task.'
      Run-Native $gradleExe @(':wrapper', '--gradle-version', $version, '--no-daemon')
    } finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
  }
  foreach ($f in @($wrapperBat, $wrapperJar, $props)) {
    if (-not (Test-Path $f)) { throw "Wrapper repair incomplete, missing: $f" }
  }
  Say 'Gradle Wrapper files present.'
  Run-Native $wrapperBat @('--version')
  if (-not $SkipBuild) {
    $args = @(':TeamCode:assembleDebug', '--stacktrace', '--no-daemon')
    if ($RefreshDependencies) { $args += '--refresh-dependencies' }
    Say 'Testing TeamCode Debug build...'
    Run-Native $wrapperBat $args
    Say 'SUCCESS: TeamCode assembled.'
  }
  Say "Done. Log: $log"
} catch {
  Write-Host "[FTC Repair ERROR] $_" -ForegroundColor Red
  Write-Host "Log: $log" -ForegroundColor Yellow
  exit 1
} finally { Stop-Transcript | Out-Null }
