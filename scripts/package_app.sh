#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "${script_directory}/.." && pwd)"
application_bundle="${repository_root}/.build/release/Watercolor Studio.app"
contents_directory="${application_bundle}/Contents"

cd "${repository_root}"
swift build -c release --product WatercolorStudio
swift build -c release --product WatercolorStudioMCP

rm -rf "${application_bundle}"
mkdir -p "${contents_directory}/MacOS" "${contents_directory}/Resources" "${contents_directory}/Helpers"
cp ".build/release/WatercolorStudio" "${contents_directory}/MacOS/WatercolorStudio"
cp ".build/release/WatercolorStudioMCP" "${contents_directory}/Helpers/WatercolorStudioMCP"
cp "Resources/Info.plist" "${contents_directory}/Info.plist"
cp "Resources/WatercolorStudio.icns" "${contents_directory}/Resources/WatercolorStudio.icns"
