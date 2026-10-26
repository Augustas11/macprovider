#!/usr/bin/env bash
# Run only on the build host. CI, releases and candidates share this exact path.
set -euo pipefail
scripts_root="$(cd "$(dirname "$0")" && pwd)"
app="$(cd "$1" && pwd)"
packages="$2"
python3 "$scripts_root/verify-app-package-lock.py" "$app"
resolved="$app/Malibu.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
mkdir -p "$(dirname "$resolved")"
cp "$app/Package.resolved" "$resolved"
xcodebuild -resolvePackageDependencies \
  -project "$app/Malibu.xcodeproj" -scheme Malibu \
  -clonedSourcePackagesDirPath "$packages" \
  -onlyUsePackageVersionsFromResolvedFile -disableAutomaticPackageResolution
python3 "$scripts_root/verify-app-package-lock.py" "$app" "$resolved" "$packages"
