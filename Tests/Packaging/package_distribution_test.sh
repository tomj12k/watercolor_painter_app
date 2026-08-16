#!/usr/bin/env bash
set -euo pipefail

test_directory="$(mktemp -d "${TMPDIR:-/tmp}/watercolor-distribution-test.XXXXXX")"
test_directory="$(cd "${test_directory}" && pwd)"
trap 'rm -rf "${test_directory}"' EXIT

source_repository="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source_distribution_script="${source_repository}/scripts/package_distribution.sh"

if [[ ! -x "${source_distribution_script}" ]]; then
    echo "Missing executable scripts/package_distribution.sh" >&2
    exit 1
fi

make_fixture() {
    local fixture_name="$1"
    fixture_repository="${test_directory}/${fixture_name}"
    fixture_log="${fixture_repository}/commands.log"
    fixture_bin="${fixture_repository}/fake-bin"
    fixture_final="${fixture_repository}/.build/distribution/Watercolor Studio.app"

    mkdir -p \
        "${fixture_repository}/scripts" \
        "${fixture_repository}/Resources" \
        "${fixture_repository}/.build/release" \
        "${fixture_bin}"
    cp "${source_repository}/scripts/package_app.sh" "${fixture_repository}/scripts/package_app.sh"
    cp "${source_distribution_script}" "${fixture_repository}/scripts/package_distribution.sh"
    cp "${source_repository}/Resources/Info.plist" "${fixture_repository}/Resources/Info.plist"
    cp "${source_repository}/Resources/WatercolorStudio.icns" "${fixture_repository}/Resources/WatercolorStudio.icns"
    printf '#!/usr/bin/env bash\nexit 0\n' > "${fixture_repository}/.build/release/WatercolorStudio"
    chmod +x \
        "${fixture_repository}/scripts/package_app.sh" \
        "${fixture_repository}/scripts/package_distribution.sh" \
        "${fixture_repository}/.build/release/WatercolorStudio"

    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -euo pipefail' \
        'tool_name="$(basename "$0")"' \
        'printf "%s" "${tool_name}" >> "${COMMAND_LOG}"' \
        'for tool_argument in "$@"; do printf "|%s" "${tool_argument}" >> "${COMMAND_LOG}"; done' \
        'printf "\n" >> "${COMMAND_LOG}"' \
        'failure_stage=""' \
        'case "${tool_name}" in' \
        '  codesign)' \
        '    if [[ " $* " == *" --sign "* ]]; then' \
        '      failure_stage="codesign-sign"' \
        '    else' \
        '      verify_count="$(grep -c "^codesign|--verify" "${COMMAND_LOG}" || true)"' \
        '      if [[ "${verify_count}" -eq 1 ]]; then failure_stage="codesign-verify"; else failure_stage="codesign-post-verify"; fi' \
        '    fi' \
        '    ;;' \
        '  xcrun)' \
        '    if [[ "${1:-}" == "notarytool" ]]; then failure_stage="notarytool"; elif [[ "${2:-}" == "staple" ]]; then failure_stage="stapler-staple"; else failure_stage="stapler-validate"; fi' \
        '    ;;' \
        '  spctl) failure_stage="spctl" ;;' \
        '  ditto) failure_stage="ditto" ;;' \
        'esac' \
        'if [[ -n "${FAIL_STAGE:-}" && "${FAIL_STAGE}" == "${failure_stage}" ]]; then exit 70; fi' \
        'if [[ "${tool_name}" == "ditto" ]]; then' \
        '  archive_path=""' \
        '  for tool_argument in "$@"; do archive_path="${tool_argument}"; done' \
        '  : > "${archive_path}"' \
        'fi' \
        'if [[ "${tool_name}" == "spctl" && -e "${TEST_FINAL_BUNDLE}" && "${ALLOW_EXISTING_FINAL:-}" != "1" ]]; then' \
        '  echo "Final bundle was published before assessment" >&2' \
        '  exit 71' \
        'fi' \
        > "${fixture_bin}/fake-tool"
    chmod +x "${fixture_bin}/fake-tool"
    for tool_name in swift codesign xcrun spctl ditto; do
        ln -s fake-tool "${fixture_bin}/${tool_name}"
    done
}

run_distribution() {
    env \
        PATH="${fixture_bin}:${PATH}" \
        COMMAND_LOG="${fixture_log}" \
        TEST_FINAL_BUNDLE="${fixture_final}" \
        "$@" \
        "${fixture_repository}/scripts/package_distribution.sh"
}

make_fixture "missing-credentials"
if env \
    -u DEVELOPER_ID_APPLICATION \
    -u NOTARYTOOL_PROFILE \
    PATH="${fixture_bin}:${PATH}" \
    COMMAND_LOG="${fixture_log}" \
    TEST_FINAL_BUNDLE="${fixture_final}" \
    "${fixture_repository}/scripts/package_distribution.sh";
then
    echo "Distribution unexpectedly accepted missing credentials" >&2
    exit 1
fi
[[ ! -e "${fixture_final}" ]]
[[ ! -s "${fixture_log}" ]]

make_fixture "missing-notary-profile"
if run_distribution \
    DEVELOPER_ID_APPLICATION="Developer ID Application: Watercolor Test (ABCDE12345)" \
    NOTARYTOOL_PROFILE="";
then
    echo "Distribution unexpectedly accepted a missing notary profile" >&2
    exit 1
fi
[[ ! -e "${fixture_final}" ]]
[[ ! -s "${fixture_log}" ]]

make_fixture "successful-distribution"
run_distribution \
    DEVELOPER_ID_APPLICATION="Developer ID Application: Watercolor Test (ABCDE12345)" \
    NOTARYTOOL_PROFILE="watercolor-test-profile"
[[ -d "${fixture_final}" ]]
[[ -x "${fixture_final}/Contents/MacOS/WatercolorStudio" ]]
command_lines=()
while IFS= read -r command_line; do
    command_lines[${#command_lines[@]}]="${command_line}"
done < "${fixture_log}"
[[ "${#command_lines[@]}" -eq 9 ]]
[[ "${command_lines[0]}" == "swift|build|-c|release|--product|WatercolorStudio" ]]
[[ "${command_lines[1]}" == codesign*"|--options|runtime|--timestamp|--sign|Developer ID Application: Watercolor Test (ABCDE12345)"* ]]
[[ "${command_lines[2]}" == codesign*"|--verify|--deep|--strict"* ]]
[[ "${command_lines[3]}" == ditto*"|-c|-k|--keepParent"* ]]
[[ "${command_lines[4]}" == xcrun'|notarytool|submit|'*"|--wait|--keychain-profile|watercolor-test-profile" ]]
[[ "${command_lines[5]}" == xcrun'|stapler|staple|'* ]]
[[ "${command_lines[6]}" == xcrun'|stapler|validate|'* ]]
[[ "${command_lines[7]}" == codesign*"|--verify|--deep|--strict"* ]]
[[ "${command_lines[8]}" == spctl'|--assess|--type|execute|'* ]]
published_entries="$(find "${fixture_repository}/.build/distribution" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')"
[[ "${published_entries}" == "1" ]]

make_fixture "failed-publication-restores-existing"
mkdir -p "${fixture_final}/Contents"
printf 'known-good-distribution\n' > "${fixture_final}/Contents/SENTINEL"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'destination_path="${2:-}"' \
    'if [[ "${destination_path}" == "${TEST_FINAL_BUNDLE}" ]]; then' \
    '  count_file="${COMMAND_LOG}.publication-count"' \
    '  publication_count=0' \
    '  if [[ -f "${count_file}" ]]; then publication_count="$(cat "${count_file}")"; fi' \
    '  publication_count=$((publication_count + 1))' \
    '  printf "%s\n" "${publication_count}" > "${count_file}"' \
    '  if [[ "${publication_count}" -eq 1 ]]; then exit 72; fi' \
    'fi' \
    'exec /bin/mv "$@"' \
    > "${fixture_bin}/mv"
chmod +x "${fixture_bin}/mv"
if run_distribution \
    DEVELOPER_ID_APPLICATION="Developer ID Application: Watercolor Test (ABCDE12345)" \
    NOTARYTOOL_PROFILE="watercolor-test-profile" \
    ALLOW_EXISTING_FINAL="1";
then
    echo "Distribution unexpectedly survived publication failure" >&2
    exit 1
fi
if [[ ! -f "${fixture_final}/Contents/SENTINEL" ]] || \
   [[ "$(cat "${fixture_final}/Contents/SENTINEL")" != "known-good-distribution" ]];
then
    echo "Known-good distribution was not restored after publication failure" >&2
    exit 1
fi
if [[ -e "${fixture_final}/Contents/MacOS/WatercolorStudio" ]]; then
    echo "Failed replacement remained published" >&2
    exit 1
fi
staging_entries="$(find "${fixture_repository}/.build/distribution" -mindepth 1 -maxdepth 1 -name '.package.*' -print | wc -l | tr -d ' ')"
if [[ "${staging_entries}" != "0" ]]; then
    echo "Publication failure left staging directories behind" >&2
    exit 1
fi
run_distribution \
    DEVELOPER_ID_APPLICATION="Developer ID Application: Watercolor Test (ABCDE12345)" \
    NOTARYTOOL_PROFILE="watercolor-test-profile" \
    ALLOW_EXISTING_FINAL="1"
if [[ ! -x "${fixture_final}/Contents/MacOS/WatercolorStudio" ]] || \
   [[ -e "${fixture_final}/Contents/SENTINEL" ]];
then
    echo "Successful publication did not replace the previous distribution" >&2
    exit 1
fi
published_entries="$(find "${fixture_repository}/.build/distribution" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')"
if [[ "${published_entries}" != "1" ]]; then
    echo "Successful replacement left publication residue" >&2
    exit 1
fi

for failure_stage in codesign-sign codesign-verify ditto notarytool stapler-staple stapler-validate codesign-post-verify spctl; do
    make_fixture "failure-${failure_stage}"
    if run_distribution \
        DEVELOPER_ID_APPLICATION="Developer ID Application: Watercolor Test (ABCDE12345)" \
        NOTARYTOOL_PROFILE="watercolor-test-profile" \
        FAIL_STAGE="${failure_stage}";
    then
        echo "Distribution unexpectedly survived ${failure_stage} failure" >&2
        exit 1
    fi
    [[ ! -e "${fixture_final}" ]]
done

grep -Eq '^\.PHONY:.*distribution' "${source_repository}/Makefile"
grep -Fxq 'distribution:' "${source_repository}/Makefile"
grep -Fq 'scripts/package_distribution.sh' "${source_repository}/Makefile"
grep -Fq 'make app' "${source_repository}/README.md"
grep -Fq 'local-only' "${source_repository}/README.md"
grep -Fq 'make distribution' "${source_repository}/README.md"
grep -Fq 'DEVELOPER_ID_APPLICATION' "${source_repository}/README.md"
grep -Fq 'NOTARYTOOL_PROFILE' "${source_repository}/README.md"
grep -Fq 'codesign --verify' "${source_repository}/README.md"
grep -Fq 'notarytool submit' "${source_repository}/README.md"
grep -Fq 'stapler validate' "${source_repository}/README.md"
grep -Fq 'spctl --assess' "${source_repository}/README.md"

echo "package_distribution_test: PASS"
