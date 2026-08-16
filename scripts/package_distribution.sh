#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "${script_directory}/.." && pwd)"

if [[ -z "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    echo "DEVELOPER_ID_APPLICATION is required for a signed distribution build." >&2
    exit 2
fi
if [[ -z "${NOTARYTOOL_PROFILE:-}" ]]; then
    echo "NOTARYTOOL_PROFILE is required for notarization." >&2
    exit 2
fi

for required_tool in codesign ditto spctl xcrun; do
    if ! command -v "${required_tool}" >/dev/null 2>&1; then
        echo "Required distribution tool is unavailable: ${required_tool}" >&2
        exit 2
    fi
done

local_application="${repository_root}/.build/release/Watercolor Studio.app"
distribution_directory="${repository_root}/.build/distribution"
final_application="${distribution_directory}/Watercolor Studio.app"
working_directory=""

cleanup() {
    if [[ -n "${working_directory}" && -d "${working_directory}" ]]; then
        rm -rf "${working_directory}"
    fi
}
trap cleanup EXIT

cd "${repository_root}"
"${repository_root}/scripts/package_app.sh"

if [[ ! -x "${local_application}/Contents/MacOS/WatercolorStudio" ]]; then
    echo "Local release packaging did not produce the expected executable." >&2
    exit 3
fi

mkdir -p "${distribution_directory}"
working_directory="$(mktemp -d "${distribution_directory}/.package.XXXXXX")"
staged_application="${working_directory}/Watercolor Studio.app"
notarization_archive="${working_directory}/Watercolor Studio.zip"
cp -R "${local_application}" "${staged_application}"

codesign \
    --force \
    --deep \
    --options runtime \
    --timestamp \
    --sign "${DEVELOPER_ID_APPLICATION}" \
    "${staged_application}"
codesign --verify --deep --strict --verbose=2 "${staged_application}"

ditto -c -k --keepParent "${staged_application}" "${notarization_archive}"
xcrun notarytool submit \
    "${notarization_archive}" \
    --wait \
    --keychain-profile "${NOTARYTOOL_PROFILE}"
xcrun stapler staple "${staged_application}"
xcrun stapler validate "${staged_application}"

codesign --verify --deep --strict --verbose=2 "${staged_application}"
spctl --assess --type execute --verbose=4 "${staged_application}"

if [[ -e "${final_application}" ]]; then
    rm -rf "${final_application}"
fi
mv "${staged_application}" "${final_application}"

echo "Signed and notarized distribution created at: ${final_application}"
