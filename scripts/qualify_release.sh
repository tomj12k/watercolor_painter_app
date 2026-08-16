#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "${script_directory}/.." && pwd)"
application_bundle="${repository_root}/.build/release/Watercolor Studio.app"
application_executable="${application_bundle}/Contents/MacOS/WatercolorStudio"
qualification_pid=""

cleanup() {
    local exit_status=$?
    trap - EXIT INT TERM HUP
    set +e
    if [[ -n "${qualification_pid}" ]] && kill -0 "${qualification_pid}" 2>/dev/null; then
        kill -TERM "${qualification_pid}" 2>/dev/null
        wait "${qualification_pid}" 2>/dev/null
    fi
    exit "${exit_status}"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

cd "${repository_root}"
swift package clean
mkdir -p ".build/qualification"
qualification_report="${repository_root}/.build/qualification/report.txt"
exec > >(tee "${qualification_report}") 2>&1

echo "WATERCOLOR_RELEASE_QUALIFICATION status=STARTED"
echo "WATERCOLOR_RELEASE_QUALIFICATION gate=clean_tests status=RUNNING"
make test
echo "WATERCOLOR_RELEASE_QUALIFICATION gate=clean_tests status=PASS"

echo "WATERCOLOR_RELEASE_QUALIFICATION gate=metal_validation status=RUNNING"
env \
    WATERCOLOR_REQUIRE_METAL=1 \
    MTL_DEBUG_LAYER=1 \
    MTL_DEBUG_LAYER_VALIDATE_LOAD_ACTIONS=1 \
    MTL_DEBUG_LAYER_VALIDATE_STORE_ACTIONS=1 \
    MTL_SHADER_VALIDATION=1 \
    swift test --filter WatercolorRendererTests
echo "WATERCOLOR_RELEASE_QUALIFICATION gate=metal_validation status=PASS"

echo "WATERCOLOR_RELEASE_QUALIFICATION gate=performance status=RUNNING"
env \
    WATERCOLOR_REQUIRE_METAL=1 \
    WATERCOLOR_RUN_BENCHMARK=1 \
    swift test --filter PerformanceQualificationTests
echo "WATERCOLOR_RELEASE_QUALIFICATION gate=performance status=PASS"

echo "WATERCOLOR_RELEASE_QUALIFICATION gate=local_package status=RUNNING"
make app
plutil -lint "${application_bundle}/Contents/Info.plist"
test -x "${application_executable}"
test -f "${application_bundle}/Contents/Resources/WatercolorStudio.icns"
echo "WATERCOLOR_RELEASE_QUALIFICATION gate=local_package status=PASS"

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" && -n "${NOTARYTOOL_PROFILE:-}" ]]; then
    echo "WATERCOLOR_RELEASE_QUALIFICATION gate=signing_notarization status=RUNNING"
    make distribution
    echo "WATERCOLOR_RELEASE_QUALIFICATION gate=signing_notarization status=PASS"
elif [[ -n "${DEVELOPER_ID_APPLICATION:-}" || -n "${NOTARYTOOL_PROFILE:-}" ]]; then
    echo "Both DEVELOPER_ID_APPLICATION and NOTARYTOOL_PROFILE are required together." >&2
    exit 2
else
    echo "WATERCOLOR_RELEASE_QUALIFICATION gate=signing_notarization status=NOT_RUN reason=credentials_not_supplied"
fi

echo "WATERCOLOR_RELEASE_QUALIFICATION gate=liveness status=RUNNING"
"${application_executable}" > ".build/qualification/liveness.log" 2>&1 &
qualification_pid=$!
for liveness_second in 1 2 3 4 5; do
    /bin/sleep 1
    if ! kill -0 "${qualification_pid}" 2>/dev/null; then
        echo "Watercolor Studio exited before the five-second liveness gate at second ${liveness_second}." >&2
        wait "${qualification_pid}" || true
        qualification_pid=""
        exit 3
    fi
done
kill -TERM "${qualification_pid}"
set +e
wait "${qualification_pid}"
liveness_exit_status=$?
set -e
if [[ "${liveness_exit_status}" -ne 0 && "${liveness_exit_status}" -ne 143 ]]; then
    echo "Watercolor Studio returned unexpected liveness exit status ${liveness_exit_status}." >&2
    qualification_pid=""
    exit 3
fi
qualification_pid=""
echo "WATERCOLOR_RELEASE_QUALIFICATION gate=liveness status=PASS duration_seconds=5 terminated=true"

git diff --check
echo "WATERCOLOR_RELEASE_QUALIFICATION gate=diff_check status=PASS"
echo "WATERCOLOR_RELEASE_QUALIFICATION status=PASS report=${qualification_report}"
