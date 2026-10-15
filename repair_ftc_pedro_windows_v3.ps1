#Requires -Version 5.1
<#
.SYNOPSIS
  Repairs the Gradle wrapper and local Java/Android SDK configuration for a Windows FTC/PedroPathing project.
.DESCRIPTION
  Run from the FTC project root (the folder with settings.gradle).
  Uses a temporary, empty Gradle project to regenerate missing wrapper files. Does NOT
  upgrade Gradle, edit FTC/PedroPathing dependencies, or delete the Gradle cache.
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\repair_ftc_pedro_windows_v3.ps1
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\repair_ftc_pedro_windows_v3.ps1 -RefreshDependencies
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\repair_ftc_pedro_windows_v3.ps1 -GradleVersion 8.10.2
#>
[CmdletBinding()]
param(
    [string]$ProjectPath = (Get-Location).Path,
    [string]$GradleVersion,
    [switch]$RefreshDependencies,
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Info([string]$Message) { Write-Host "[FTC Repair] $Message" -ForegroundColor Cyan }
function Warning([string]$Message) { Write-Warning $Message }

function Backup-File([string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $backup = "$Path.bak-$script:stamp"
        Copy-Item -LiteralPath $Path -Destination $backup -Force
        Info "Backup: $backup"
    }
}

# External programs can legitimately write to stderr. PowerShell 5.1's native stderr
# redirection can create ErrorRecords, which are fatal under ErrorActionPreference=Stop.
# Run Java's version probe with independently redirected stdout/stderr instead.
function Get-JavaMajor([string]$JavaExe) {
    $stdoutFile = Join-Path $env:TEMP ("ftc-java-out-" + [guid]::NewGuid().ToString('N') + '.txt')
    $stderrFile = Join-Path $env:TEMP ("ftc-java-err-" + [guid]::NewGuid().ToString('N') + '.txt')
    try {
        $process = Start-Process -FilePath $JavaExe -ArgumentList '-version' -Wait -PassThru -NoNewWindow `
            -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
        $versionText = (Get-Content -LiteralPath $stdoutFile -Raw -ErrorAction SilentlyContinue) + "`n" +
                       (Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue)
        if ($process.ExitCode -ne 0) { return $null }
        if ($versionText -match '(?:openjdk|java) version "(\d+)(?:\.(\d+))?') {
            $major = [int]$Matches[1]
            if ($major -eq 1) { $major = [int]$Matches[2] }
            return $major
        }
        return $null
    } catch {
        return $null
    } finally {
        Remove-Item -LiteralPath $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

function Find-JdkCandidates {
    $roots = @(
        $env:JAVA_HOME,
        $env:STUDIO_JDK,
        "$env:ProgramFiles\Android\Android Studio\jbr",
        "$env:ProgramFiles\Eclipse Adoptium",
        "$env:ProgramFiles\Microsoft",
        "$env:ProgramFiles\Java",
        "$env:ProgramFiles\Zulu",
        "$env:ProgramFiles\Amazon Corretto",
        "$env:LOCALAPPDATA\Programs\Eclipse Adoptium",
        "$env:USERPROFILE\.jdks"
    )
    $homes = New-Object System.Collections.ArrayList
    foreach ($root in $roots) {
        if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        [void]$homes.Add($root)
        foreach ($child in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            [void]$homes.Add($child.FullName)
        }
    }
    $seen = @{}
    # $HOME is a read-only automatic variable in PowerShell (case-insensitive),
    # so never use $home as a loop variable.
    foreach ($jdkHome in $homes) {
        $java = Join-Path $jdkHome 'bin\java.exe'
        if (-not (Test-Path -LiteralPath $java -PathType Leaf)) { continue }
        $key = $jdkHome.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $major = Get-JavaMajor $java
        if ($null -ne $major) {
            [pscustomobject]@{ Home = $jdkHome; Major = $major; Java = $java }
        }
    }
}

function Find-AndroidSdk {
    $candidates = @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT, "$env:LOCALAPPDATA\Android\Sdk")
    foreach ($path in $candidates) {
        if ($path -and (Test-Path -LiteralPath $path -PathType Container)) {
            return (Resolve-Path -LiteralPath $path).Path
        }
    }
    return $null
}

function Invoke-Native([string]$Exe, [string[]]$Arguments, [string]$WorkingDirectory) {
    Info "Running: $(Split-Path -Path $Exe -Leaf) $($Arguments -join ' ')"
    Push-Location -LiteralPath $WorkingDirectory
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # Capture Gradle diagnostics in the transcript and a separate command log.
        # Native stderr must NOT be treated as a terminating PowerShell exception.
        & $Exe @Arguments 2>&1 | Tee-Object -FilePath $script:commandLog -Append | Out-Host
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
        Pop-Location
    }
    if ($exitCode -ne 0) {
        throw "Command failed with exit code $exitCode. Read $script:commandLog for the Gradle error."
    }
}

$ProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path
if (-not (Test-Path -LiteralPath (Join-Path $ProjectPath 'settings.gradle')) -and
    -not (Test-Path -LiteralPath (Join-Path $ProjectPath 'settings.gradle.kts'))) {
    throw "Not a Gradle project root: $ProjectPath. Use -ProjectPath to specify the directory containing settings.gradle."
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $ProjectPath "ftc-gradle-repair-$stamp.log"
$commandLog = Join-Path $ProjectPath "ftc-gradle-commands-$stamp.log"
Start-Transcript -Path $log -Append | Out-Null

try {
    Info "Project: $ProjectPath"
    $wrapperDir = Join-Path $ProjectPath 'gradle\wrapper'
    $wrapperProps = Join-Path $wrapperDir 'gradle-wrapper.properties'
    $wrapperJar = Join-Path $wrapperDir 'gradle-wrapper.jar'
    $wrapperBat = Join-Path $ProjectPath 'gradlew.bat'
    $wrapperSh = Join-Path $ProjectPath 'gradlew'

    # Read the version already chosen by the project. Never guess or silently upgrade it.
    $existingVersion = $null
    $distributionType = 'bin'
    if (Test-Path -LiteralPath $wrapperProps) {
        $propsText = Get-Content -LiteralPath $wrapperProps -Raw
        if ($propsText -match 'gradle-(\d+\.\d+(?:\.\d+)?)-(bin|all)\.zip') {
            $existingVersion = $Matches[1]
            $distributionType = $Matches[2]
            Info "Gradle version from wrapper properties: $existingVersion"
        }
    }
    if ($GradleVersion -and $existingVersion -and $GradleVersion -ne $existingVersion) {
        throw "Gradle version mismatch: existing $existingVersion, requested $GradleVersion. No version changes were made."
    }
    $version = if ($existingVersion) { $existingVersion } else { $GradleVersion }
    if (-not $version -or $version -notmatch '^\d+\.\d+(?:\.\d+)?$') {
        throw 'Could not determine the Gradle version. Inspect gradle\wrapper\gradle-wrapper.properties or pass -GradleVersion X.Y.Z matching your FTC project.'
    }
    $gradleNumber = [version]$version

    # Many recent Android Studio installations bundle JBR 21. Gradle <8.5 cannot
    # run on Java 21, even if "java -version" succeeds.
    $jdks = @(Find-JdkCandidates)
    if ($jdks.Count -eq 0) {
        throw 'No usable JDK found. Install JDK 17 and/or Android Studio, then retry.'
    }
    $selectedJdk = $null
    if ($gradleNumber -lt [version]'7.3') {
        $selectedJdk = $jdks | Where-Object { $_.Major -eq 11 } | Select-Object -First 1
        if (-not $selectedJdk) {
            throw "Gradle $version is old; this repair expects JDK 11 for that version. Install JDK 11, or migrate Gradle/AGP deliberately. Found JDK versions: $(($jdks.Major | Sort-Object -Unique) -join ', ')"
        }
    } else {
        $selectedJdk = $jdks | Where-Object { $_.Major -eq 17 } | Select-Object -First 1
        if (-not $selectedJdk -and $gradleNumber -ge [version]'8.5') {
            $selectedJdk = $jdks | Where-Object { $_.Major -eq 21 } | Select-Object -First 1
        }
        if (-not $selectedJdk) {
            throw "Gradle $version needs a compatible Java runtime. Install JDK 17 (recommended). Android Studio's JBR 21 cannot run Gradle before 8.5. Found: $(($jdks.Major | Sort-Object -Unique) -join ', ')"
        }
    }
    $env:JAVA_HOME = $selectedJdk.Home
    $env:Path = "$(Join-Path $selectedJdk.Home 'bin');$env:Path"
    Info "Java: JDK $($selectedJdk.Major) at $($selectedJdk.Home)"
    Info 'Java version check passed (stderr output is handled safely).'

    $sdk = Find-AndroidSdk
    if ($sdk) {
        $env:ANDROID_HOME = $sdk
        Info "Android SDK: $sdk"
        $localProperties = Join-Path $ProjectPath 'local.properties'
        # Java properties files require escaping the Windows drive-letter colon.
        $sdkProperty = 'sdk.dir=' + (($sdk -replace '\\', '/') -replace ':', '\:')
        if (Test-Path -LiteralPath $localProperties) {
            $lines = @(Get-Content -LiteralPath $localProperties)
            $sdkLines = @($lines | Where-Object { $_ -match '^\s*sdk\.dir\s*=' })
            if ($sdkLines.Count -eq 0) {
                Backup-File $localProperties
                Add-Content -LiteralPath $localProperties -Value $sdkProperty
                Info 'Added sdk.dir to local.properties.'
            } else {
                # Preserve the user's existing SDK path if it is defined. Fixing a
                # stale path should be a separate deliberate operation.
                Info 'local.properties already defines sdk.dir; leaving it unchanged.'
            }
        } else {
            Set-Content -LiteralPath $localProperties -Value $sdkProperty -Encoding ASCII
            Info 'Created local.properties.'
        }
    } else {
        Warning 'Android SDK was not found. Install/configure the Android SDK in Android Studio > SDK Manager.'
    }

    $missing = @()
    if (-not (Test-Path -LiteralPath $wrapperBat)) { $missing += 'gradlew.bat' }
    if (-not (Test-Path -LiteralPath $wrapperSh)) { $missing += 'gradlew' }
    if (-not (Test-Path -LiteralPath $wrapperJar)) { $missing += 'gradle-wrapper.jar' }
    if (-not (Test-Path -LiteralPath $wrapperProps)) { $missing += 'gradle-wrapper.properties' }

    if ($missing.Count -gt 0) {
        Info "Missing wrapper files: $($missing -join ', ')"
        $tempRoot = Join-Path $env:TEMP "ftc-wrapper-bootstrap-$stamp"
        $bootstrap = Join-Path $tempRoot 'isolated-project'
        New-Item -ItemType Directory -Path $bootstrap -Force | Out-Null
        try {
            $distributionZip = Join-Path $tempRoot "gradle-$version-bin.zip"
            $url = "https://services.gradle.org/distributions/gradle-$version-bin.zip"
            Info "Downloading Gradle $version from official server..."
            Invoke-WebRequest -Uri $url -OutFile $distributionZip -UseBasicParsing
            $expectedSha = ((Invoke-WebRequest -Uri "$url.sha256" -UseBasicParsing).Content -split '\s+')[0].Trim().ToLowerInvariant()
            $actualSha = (Get-FileHash -LiteralPath $distributionZip -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($expectedSha -notmatch '^[0-9a-f]{64}$' -or $expectedSha -ne $actualSha) {
                throw 'Gradle distribution SHA-256 verification failed. No wrapper files were copied.'
            }
            Info 'SHA-256 verified.'
            Expand-Archive -LiteralPath $distributionZip -DestinationPath $tempRoot -Force
            $gradleBat = Join-Path $tempRoot "gradle-$version\bin\gradle.bat"
            if (-not (Test-Path -LiteralPath $gradleBat)) { throw 'Missing gradle.bat in downloaded distribution.' }

            # Crucial: generate in an EMPTY project so existing FTC/AGP/Pedro
            # configuration errors do not prevent the :wrapper task from running.
            Set-Content -LiteralPath (Join-Path $bootstrap 'settings.gradle') -Value "rootProject.name = 'ftc-wrapper-bootstrap'" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $bootstrap 'build.gradle') -Value '// Temporary Gradle wrapper bootstrap; no FTC plugins.' -Encoding ASCII
            Info 'Generating wrapper in a temporary isolated Gradle project...'
            Invoke-Native $gradleBat @('wrapper', '--gradle-version', $version, '--distribution-type', $distributionType, '--no-daemon') $bootstrap

            $generatedWrapper = Join-Path $bootstrap 'gradle\wrapper'
            New-Item -ItemType Directory -Path $wrapperDir -Force | Out-Null
            $copies = @(
                @{ Source = (Join-Path $bootstrap 'gradlew.bat'); Target = $wrapperBat },
                @{ Source = (Join-Path $bootstrap 'gradlew'); Target = $wrapperSh },
                @{ Source = (Join-Path $generatedWrapper 'gradle-wrapper.jar'); Target = $wrapperJar },
                @{ Source = (Join-Path $generatedWrapper 'gradle-wrapper.properties'); Target = $wrapperProps }
            )
            foreach ($item in $copies) {
                if (-not (Test-Path -LiteralPath $item.Source)) {
                    throw "Gradle did not generate $($item.Source)."
                }
                if (-not (Test-Path -LiteralPath $item.Target)) {
                    Copy-Item -LiteralPath $item.Source -Destination $item.Target
                    Info "Restored: $($item.Target)"
                }
            }
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    } else {
        Info 'All four Gradle wrapper components are already present.'
    }

    foreach ($f in @($wrapperBat, $wrapperJar, $wrapperProps)) {
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { throw "Wrapper is still incomplete: $f" }
    }
    Info 'Checking Gradle wrapper version...'
    Invoke-Native $wrapperBat @('--version') $ProjectPath

    if (-not $SkipBuild) {
        $buildArguments = @(':TeamCode:assembleDebug', '--stacktrace', '--no-daemon')
        if ($RefreshDependencies) { $buildArguments += '--refresh-dependencies' }
        Info 'Building :TeamCode:assembleDebug. Initial builds can take several minutes.'
        Invoke-Native $wrapperBat $buildArguments $ProjectPath
        Info 'SUCCESS: TeamCode Debug build completed.'
    }
    Info "Done. Transcript: $log"
    Info "Gradle output: $commandLog"
} catch {
    Write-Host "[FTC Repair ERROR] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Transcript: $log" -ForegroundColor Yellow
    Write-Host "Gradle output: $commandLog" -ForegroundColor Yellow
    exit 1
} finally {
    Stop-Transcript | Out-Null
}
