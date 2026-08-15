#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "${script_directory}/.." && pwd)"
application_bundle="${repository_root}/.build/release/Watercolor Studio.app"
contents_directory="${application_bundle}/Contents"

cd "${repository_root}"
swift build -c release --product WatercolorStudio

rm -rf "${application_bundle}"
mkdir -p "${contents_directory}/MacOS" "${contents_directory}/Resources"
cp ".build/release/WatercolorStudio" "${contents_directory}/MacOS/WatercolorStudio"
cp "Resources/Info.plist" "${contents_directory}/Info.plist"
