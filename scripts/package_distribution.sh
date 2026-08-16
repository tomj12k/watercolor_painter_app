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
previous_application=""
failed_application=""
publication_started=false
publication_complete=false
had_previous_application=false

cleanup() {
    local exit_status=$?
    local restoration_failed=false
    trap - EXIT INT TERM HUP
    set +e

    if [[ "${publication_started}" == true && "${publication_complete}" != true ]]; then
        if [[ "${had_previous_application}" == true && ! -e "${previous_application}" ]]; then
            if [[ ! -e "${final_application}" ]]; then
                echo "The previous verified distribution could not be located after publication failed." >&2
                restoration_failed=true
            fi
        else
            if [[ -e "${final_application}" ]]; then
                if ! mv "${final_application}" "${failed_application}" || \
                   [[ -e "${final_application}" ]] || \
                   [[ ! -e "${failed_application}" ]];
                then
                    echo "Failed to quarantine the incomplete distribution at: ${final_application}" >&2
                    restoration_failed=true
                fi
            fi

            if [[ "${had_previous_application}" == true && "${restoration_failed}" != true ]]; then
                if ! mv "${previous_application}" "${final_application}" || \
                   [[ ! -e "${final_application}" ]] || \
                   [[ -e "${previous_application}" ]];
                then
                    echo "Failed to restore the previous verified distribution at: ${previous_application}" >&2
                    restoration_failed=true
                fi
            fi
        fi
    fi

    if [[ "${restoration_failed}" != true && -n "${working_directory}" && -d "${working_directory}" ]]; then
        rm -rf "${working_directory}"
    fi

    if [[ "${restoration_failed}" == true ]]; then
        exit 5
    fi
    exit "${exit_status}"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

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

previous_application="${working_directory}/Previous Watercolor Studio.app"
failed_application="${working_directory}/Failed Watercolor Studio.app"
if [[ -e "${final_application}" ]]; then
    had_previous_application=true
    publication_started=true
    mv "${final_application}" "${previous_application}"
else
    publication_started=true
fi
mv "${staged_application}" "${final_application}"
publication_complete=true

if [[ -e "${previous_application}" ]]; then
    rm -rf "${previous_application}"
fi

echo "Signed and notarized distribution created at: ${final_application}"
