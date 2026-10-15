#!/usr/bin/env bash
# FTC / PedroPathing Gradle environment repair for Windows Git Bash.
# Run in the FTC project root: bash repair_ftc_pedro_windows.sh [--refresh] [--install-sdk] [--gradle-version X.Y.Z]
set -uo pipefail

REFRESH=0
INSTALL_SDK=0
GRADLE_VERSION=""
while (($#)); do
  arg="$1"; shift
  case "$arg" in
    --gradle-version) if (($# == 0)); then echo "Missing value for --gradle-version"; exit 2; fi; GRADLE_VERSION="$1"; shift ;;
    --refresh) REFRESH=1 ;;
    --install-sdk) INSTALL_SDK=1 ;;
    -h|--help) echo 'Usage: bash repair_ftc_pedro_windows.sh [--refresh] [--install-sdk] [--gradle-version X.Y.Z]'; exit 0 ;;
    *) echo "Unknown option: $arg"; exit 2 ;;
  esac
done

if ! command -v cygpath >/dev/null 2>&1 || ! command -v powershell.exe >/dev/null 2>&1; then
  echo 'ERROR: This script requires Git Bash on Windows (cygpath + powershell.exe).'
  exit 1
fi

if [[ ! -f settings.gradle && ! -f settings.gradle.kts ]]; then
  echo 'ERROR: Run this from the FTC project root (containing settings.gradle or settings.gradle.kts).'
  exit 1
fi

PROJECT_WIN=$(cygpath -w "$PWD")
STAMP=$(date +%Y%m%d-%H%M%S)
LOG="$PWD/gradle-repair-$STAMP.log"
BACKUPS="$PWD/.gradle-repair-backups/$STAMP"
mkdir -p "$BACKUPS"
exec > >(tee -a "$LOG") 2>&1
say() { printf '\n== %s ==\n' "$*"; }
warn() { echo "WARNING: $*"; }
psquote() { local s=${1//\'/\'\'}; printf "'%s'" "$s"; }

say 'Project and tools'
echo "Project: $PROJECT_WIN"
[[ -f gradle/wrapper/gradle-wrapper.properties ]] && grep -E '^distributionUrl=' gradle/wrapper/gradle-wrapper.properties || true

# Prefer an existing JDK 17 for FTC projects. Never install or upgrade JDK automatically.
JDK=''
CANDIDATES=()
[[ -n "${JAVA_HOME:-}" ]] && CANDIDATES+=("$JAVA_HOME")
[[ -n "${LOCALAPPDATA:-}" ]] && {
  for j in "$LOCALAPPDATA"/Programs/Android\ Studio/jbr "$LOCALAPPDATA"/Programs/Eclipse\ Adoptium/jdk-17*; do [[ -d "$j" ]] && CANDIDATES+=("$j"); done
}
for j in /c/Program\ Files/Eclipse\ Adoptium/jdk-17* /c/Program\ Files/Java/jdk-17* /c/Program\ Files/Microsoft/jdk-17* /c/Program\ Files/Android/Android\ Studio/jbr; do
  [[ -d "$j" ]] && CANDIDATES+=("$j")
done
for candidate in "${CANDIDATES[@]}"; do
  dir="$candidate"
  [[ "$dir" == *:\\* ]] && dir=$(cygpath -u "$dir")
  [[ -f "$dir/bin/java.exe" ]] || continue
  version=$("$dir/bin/java.exe" -version 2>&1 | head -n 1)
  echo "Found Java: $dir ($version)"
  if [[ "$version" == *'"17.'* ]]; then JDK="$dir"; break; fi
done
if [[ -n "$JDK" ]]; then
  export JAVA_HOME="$(cygpath -w "$JDK")"
  export PATH="$JDK/bin:$PATH"
  echo "Using JDK 17: $JAVA_HOME"
else
  warn 'JDK 17 not found. Gradle may fail if the project requires Java 17.'
  warn 'Install JDK 17 or select it under Android Studio > Settings > Build Tools > Gradle.'
  if command -v java >/dev/null 2>&1; then java -version 2>&1 | head -n 3; fi
fi

say 'Android SDK'
SDK=''
for candidate in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" \
   "${LOCALAPPDATA:-}/Android/Sdk" "/c/Users/${USERNAME:-}/AppData/Local/Android/Sdk"; do
  [[ -n "$candidate" ]] || continue
  dir="$candidate"
  [[ "$dir" == *:\\* ]] && dir=$(cygpath -u "$dir")
  if [[ -d "$dir/platforms" || -d "$dir/platform-tools" || -d "$dir/cmdline-tools" ]]; then SDK="$dir"; break; fi
done
if [[ -z "$SDK" ]]; then
  echo 'ERROR: Android SDK not found. Open Android Studio > SDK Manager and install the Android SDK.'
  exit 1
fi
SDK_WIN=$(cygpath -w "$SDK")
export ANDROID_HOME="$SDK_WIN"
export ANDROID_SDK_ROOT="$SDK_WIN"
echo "SDK: $SDK_WIN"

# Replace ONLY sdk.dir, keep any unrelated project-specific settings.
if [[ -f local.properties ]]; then cp -p local.properties "$BACKUPS/local.properties"; fi
SDK_PROPERTY="$(cygpath -m "$SDK" | sed 's/:/\\:/g')"
tmp=$(mktemp)
if [[ -f local.properties ]]; then grep -v -E '^[[:space:]]*sdk\.dir[[:space:]]*=' local.properties > "$tmp" || true; fi
printf 'sdk.dir=%s\n' "$SDK_PROPERTY" >> "$tmp"
cat "$tmp" > local.properties
rm -f "$tmp"
echo 'Updated local.properties (backup saved, if one existed).'

say 'Project dependencies (informational)'
if command -v grep >/dev/null 2>&1; then
  grep -RnE 'com\.pedropathing|maven\.pedropathing\.com|mavenCentral\(\)' --include='*.gradle' --include='*.gradle.kts' . \
    --exclude-dir=.gradle --exclude-dir=build --exclude-dir=.git 2>/dev/null | head -n 35 || true
fi
echo 'Dependency and Gradle plugin versions are intentionally NOT modified.'

say 'Repair missing Gradle wrapper'
WRAPPER_PROPS=gradle/wrapper/gradle-wrapper.properties
if [[ -f "$WRAPPER_PROPS" ]]; then
  FOUND_VERSION=$(sed -nE 's@.*gradle-([0-9]+\.[0-9]+(\.[0-9]+)?)-(bin|all)\.zip.*@\1@p' "$WRAPPER_PROPS" | head -n1)
  [[ -n "$FOUND_VERSION" ]] && echo "Project-pinned Gradle version: $FOUND_VERSION"
  if [[ -n "$GRADLE_VERSION" && -n "$FOUND_VERSION" && "$GRADLE_VERSION" != "$FOUND_VERSION" ]]; then
    echo "ERROR: --gradle-version $GRADLE_VERSION conflicts with project wrapper version $FOUND_VERSION."
    echo 'Preserving the project Gradle version. Remove the flag or supply its exact version.'
    exit 1
  fi
  [[ -z "$GRADLE_VERSION" ]] && GRADLE_VERSION="$FOUND_VERSION"
fi
if [[ ! -f gradlew.bat || ! -s gradle/wrapper/gradle-wrapper.jar || ! -f "$WRAPPER_PROPS" ]]; then
  if [[ -z "$GRADLE_VERSION" ]]; then
    echo 'ERROR: Wrapper missing and no Gradle version could be determined.'
    echo 'Find the compatible Gradle version from your FTC project, then run:'
    echo '  bash repair_ftc_pedro_windows.sh --gradle-version X.Y.Z'
    exit 1
  fi
  if [[ ! "$GRADLE_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    echo "ERROR: Invalid Gradle version: $GRADLE_VERSION"; exit 1
  fi
  echo "Bootstrapping official Gradle $GRADLE_VERSION distribution (download may be required)..."
  mkdir -p "$BACKUPS/wrapper-bootstrap"
  BOOTSTRAP_SCRIPT="$BACKUPS/wrapper-bootstrap/rebuild.ps1"
  cat > "$BOOTSTRAP_SCRIPT" <<'POWERSHELL'
$ErrorActionPreference = 'Stop'
$version = $env:FTC_REPAIR_GRADLE_VERSION
$project = $env:FTC_REPAIR_PROJECT
$base = $env:FTC_REPAIR_BOOTSTRAP
$zip = Join-Path $base "gradle-$version-bin.zip"
$expanded = Join-Path $base 'extracted'
$work = Join-Path $base 'generator'
New-Item -ItemType Directory -Force $base,$expanded,$work | Out-Null
$url = "https://services.gradle.org/distributions/gradle-$version-bin.zip"
if (!(Test-Path $zip)) {
  Write-Host "Downloading $url"
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
}
$exe = Join-Path $expanded "gradle-$version/bin/gradle.bat"
if (!(Test-Path $exe)) { Expand-Archive -Path $zip -DestinationPath $expanded -Force }
if (!(Test-Path $exe)) { throw "Could not locate downloaded Gradle executable: $exe" }
Set-Content -LiteralPath (Join-Path $work 'settings.gradle') -Value "rootProject.name = 'wrapper-generator'"
Set-Content -LiteralPath (Join-Path $work 'build.gradle') -Value ''
Push-Location $work
try {
  & $exe ':wrapper' '--gradle-version' $version '--distribution-type' 'bin' '--no-daemon'
  if ($LASTEXITCODE -ne 0) { throw "Gradle wrapper generator failed (exit $LASTEXITCODE)" }
} finally { Pop-Location }
foreach ($rel in @('gradlew.bat','gradlew','gradle/wrapper/gradle-wrapper.jar','gradle/wrapper/gradle-wrapper.properties')) {
  $src = Join-Path $work $rel
  $dst = Join-Path $project $rel
  if (!(Test-Path $src)) { throw "Generated wrapper missing: $src" }
  if ($rel -eq 'gradle/wrapper/gradle-wrapper.properties' -and (Test-Path $dst)) { continue }
  if (Test-Path $dst) { continue }
  $parent = Split-Path $dst -Parent
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  Copy-Item -LiteralPath $src -Destination $dst
  Write-Host "Created $rel"
}
POWERSHELL
  export FTC_REPAIR_GRADLE_VERSION="$GRADLE_VERSION"
  export FTC_REPAIR_PROJECT="$PROJECT_WIN"
  export FTC_REPAIR_BOOTSTRAP="$(cygpath -w "$BACKUPS/wrapper-bootstrap")"
  if ! MSYS_NO_PATHCONV=1 powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$BOOTSTRAP_SCRIPT")"; then
    echo 'ERROR: Could not regenerate Gradle wrapper; see log.'; exit 1
  fi
fi
if [[ ! -f gradlew.bat || ! -s gradle/wrapper/gradle-wrapper.jar || ! -f "$WRAPPER_PROPS" ]]; then
  echo 'ERROR: Wrapper repair incomplete.'; exit 1
fi
say 'Gradle build'

# Windows-native gradlew.bat is launched through PowerShell to preserve paths with spaces.
PSDIR=$(psquote "$PROJECT_WIN")
# Use the current process environment inherited by PowerShell, and redirect output to this script's log.
run_gradle() {
  local args="" a
  for a in "$@"; do args+=" $(psquote "$a")"; done
  local command="Set-Location -LiteralPath $PSDIR; & '.\\gradlew.bat' $args; exit \$LASTEXITCODE"
  MSYS_NO_PATHCONV=1 powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$command"
}

# Stop the daemon; avoid deleting the global Gradle cache.
run_gradle --stop || warn 'Gradle daemon stop failed; continuing.'
if ((INSTALL_SDK)); then
  say 'SDK package installation'
  SDKM=''
  for candidate in "$SDK/cmdline-tools/latest/bin/sdkmanager.bat" "$SDK/tools/bin/sdkmanager.bat"; do
    [[ -f "$candidate" ]] && { SDKM="$candidate"; break; }
  done
  if [[ -z "$SDKM" ]]; then
    warn 'sdkmanager.bat missing. Install Android SDK Command-line Tools in Android Studio SDK Manager.'
  else
    # User opts into package installs; install only platform detected from compileSdk.
    API=$(grep -RhE 'compileSdk(Version)?[[:space:]]*=?[[:space:]]*[0-9]+' --include='*.gradle' --include='*.gradle.kts' TeamCode FtcRobotController build.gradle build.gradle.kts 2>/dev/null | grep -Eo '[0-9]+' | head -n1 || true)
    if [[ -n "$API" ]]; then
      echo "Installing SDK platform android-$API and matching build-tools via sdkmanager if necessary."
      M=$(cygpath -w "$SDKM")
      MSYS_NO_PATHCONV=1 powershell.exe -NoProfile -Command "& $(psquote "$M") 'platforms;android-$API'; exit \$LASTEXITCODE" || warn 'SDK platform installation failed.'
    else
      warn 'Cannot determine compileSdk automatically; install the matching platform in SDK Manager.'
    fi
  fi
fi

ARGS=(:TeamCode:assembleDebug --stacktrace --no-daemon)
((REFRESH)) && ARGS+=(--refresh-dependencies)
echo "Running: gradlew.bat ${ARGS[*]}"
if run_gradle "${ARGS[@]}"; then
  say 'SUCCESS'
  echo 'TeamCode assembleDebug passed.'
  echo "Log: $LOG"
  exit 0
else
  STATUS=$?
  say 'BUILD STILL FAILING'
  echo "Gradle exit code: $STATUS"
  echo "Log: $LOG"
  echo 'Check the FIRST root-cause error in the log (for example: incompatible Gradle/JDK, SDK platform missing, or unresolved Pedro dependency).'
  echo 'If dependencies seem stale, rerun with --refresh.'
  echo 'If SDK platform is missing, rerun with --install-sdk.'
  exit "$STATUS"
fi
