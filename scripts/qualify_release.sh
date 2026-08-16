#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "${script_directory}/.." && pwd)"
application_bundle="${repository_root}/.build/release/Watercolor Studio.app"
application_executable="${application_bundle}/Contents/MacOS/WatercolorStudio"
qualification_directory="${repository_root}/.build/qualification"
qualification_report="${qualification_directory}/report.txt"
working_directory="$(mktemp -d "${TMPDIR:-/tmp}/watercolor-qualification.XXXXXX")"
working_report="${working_directory}/report.txt"
qualification_pid=""
cleanup_active=0
liveness_seconds="${WATERCOLOR_LIVENESS_SECONDS:-5}"
termination_grace_seconds="${WATERCOLOR_TERMINATION_GRACE_SECONDS:-2}"
optimized_timeout_seconds="${WATERCOLOR_OPTIMIZED_TIMEOUT_SECONDS:-30}"
launch_registration_delay_seconds="${WATERCOLOR_TEST_LAUNCH_REGISTRATION_DELAY_SECONDS:-0}"
signals_are_deferred=0
pending_signal_exit_code=0

record() {
    printf '%s\n' "$1" | tee -a "${working_report}"
}

run_logged() {
    "$@" 2>&1 | tee -a "${working_report}"
}

handle_signal() {
    local signal_exit_code="$1"
    if [[ "${signals_are_deferred}" -eq 1 ]]; then
        pending_signal_exit_code="${signal_exit_code}"
        return
    fi
    exit "${signal_exit_code}"
}

launch_tracked_process() {
    local output_path="$1"
    shift
    local launched_pid
    local deferred_exit_code

    signals_are_deferred=1
    "$@" > "${output_path}" 2>&1 &
    launched_pid=$!
    if [[ "${launch_registration_delay_seconds}" -gt 0 ]]; then
        /bin/sleep "${launch_registration_delay_seconds}"
    fi
    qualification_pid="${launched_pid}"
    signals_are_deferred=0
    if [[ "${pending_signal_exit_code}" -ne 0 ]]; then
        deferred_exit_code="${pending_signal_exit_code}"
        pending_signal_exit_code=0
        record "WATERCOLOR_RELEASE_QUALIFICATION gate=process_registration status=INTERRUPTED exit_code=${deferred_exit_code}"
        exit "${deferred_exit_code}"
    fi
}

publish_report() {
    local pending_report="${qualification_directory}/.report.txt.pending.$$"
    if ! mkdir -p "${qualification_directory}"; then
        return 1
    fi
    if ! cp "${working_report}" "${pending_report}"; then
        rm -f "${pending_report}" 2>/dev/null || true
        return 1
    fi
    if ! mv "${pending_report}" "${qualification_report}"; then
        rm -f "${pending_report}" 2>/dev/null || true
        return 1
    fi
    return 0
}

terminate_qualification_process() {
    local process_pid="${qualification_pid}"
    local process_exit_status=0
    local forced_kill=0
    local poll_count=$((termination_grace_seconds * 10))

    if [[ -z "${process_pid}" ]]; then
        return 0
    fi
    if ! kill -0 "${process_pid}" 2>/dev/null; then
        if wait "${process_pid}" 2>/dev/null; then
            process_exit_status=0
        else
            process_exit_status=$?
        fi
        qualification_pid=""
        if [[ "${process_exit_status}" -eq 0 || "${process_exit_status}" -eq 143 ]]; then
            return 0
        fi
        return 3
    fi

    kill -TERM "${process_pid}" 2>/dev/null || true
    for ((poll = 0; poll < poll_count; poll += 1)); do
        if ! kill -0 "${process_pid}" 2>/dev/null; then
            break
        fi
        /bin/sleep 0.1
    done
    if kill -0 "${process_pid}" 2>/dev/null; then
        forced_kill=1
        kill -KILL "${process_pid}" 2>/dev/null || true
        for ((poll = 0; poll < 20; poll += 1)); do
            if ! kill -0 "${process_pid}" 2>/dev/null; then
                break
            fi
            /bin/sleep 0.1
        done
    fi

    if wait "${process_pid}" 2>/dev/null; then
        process_exit_status=0
    else
        process_exit_status=$?
    fi
    qualification_pid=""
    if kill -0 "${process_pid}" 2>/dev/null; then
        return 1
    fi
    if [[ "${forced_kill}" -eq 1 ]]; then
        return 2
    fi
    if [[ "${process_exit_status}" -ne 0 && "${process_exit_status}" -ne 143 ]]; then
        return 3
    fi
    return 0
}

run_optimized_qualification() {
    local optimized_log="${working_directory}/optimized-customer-input.log"
    local process_exit_status=0
    local termination_status=0
    local poll_count=$((optimized_timeout_seconds * 10))

    launch_tracked_process \
        "${optimized_log}" \
        "${application_executable}" \
        --qualify-customer-input
    for ((poll = 0; poll < poll_count; poll += 1)); do
        if ! kill -0 "${qualification_pid}" 2>/dev/null; then
            break
        fi
        /bin/sleep 0.1
    done
    if kill -0 "${qualification_pid}" 2>/dev/null; then
        terminate_qualification_process || termination_status=$?
        run_logged cat "${optimized_log}"
        echo "The optimized customer-input qualification exceeded ${optimized_timeout_seconds} seconds." >&2
        if [[ "${termination_status}" -eq 1 ]]; then
            return 3
        fi
        return 124
    fi

    if wait "${qualification_pid}"; then
        process_exit_status=0
    else
        process_exit_status=$?
    fi
    qualification_pid=""
    run_logged cat "${optimized_log}"
    return "${process_exit_status}"
}

cleanup() {
    local exit_status=$?
    local termination_status=0
    local publish_status=0
    if [[ "${cleanup_active}" -eq 1 ]]; then
        return
    fi
    cleanup_active=1
    trap '' EXIT HUP INT TERM
    set +e

    if [[ -n "${qualification_pid}" ]]; then
        terminate_qualification_process
        termination_status=$?
        if [[ "${termination_status}" -ne 0 && "${exit_status}" -eq 0 ]]; then
            exit_status=3
        fi
    fi
    if [[ "${exit_status}" -ne 0 ]]; then
        printf '%s\n' \
            "WATERCOLOR_RELEASE_QUALIFICATION status=FAIL exit_code=${exit_status}" \
            >> "${working_report}"
    fi
    publish_report
    publish_status=$?
    if [[ "${publish_status}" -ne 0 ]]; then
        echo "Watercolor qualification could not publish its report. Complete working report retained at ${working_report}." >&2
        exit_status=4
    else
        rm -rf "${working_directory}"
    fi
    exit "${exit_status}"
}
trap cleanup EXIT
trap 'handle_signal 129' HUP
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

cd "${repository_root}"
record "WATERCOLOR_RELEASE_QUALIFICATION status=STARTED"
if [[ ! "${liveness_seconds}" =~ ^[1-9][0-9]*$ ]] \
    || [[ ! "${termination_grace_seconds}" =~ ^[1-9][0-9]*$ ]] \
    || [[ ! "${optimized_timeout_seconds}" =~ ^[1-9][0-9]*$ ]] \
    || [[ ! "${launch_registration_delay_seconds}" =~ ^(0|[1-9][0-9]*)$ ]]; then
    echo "Qualification timing values must be positive whole seconds." >&2
    exit 2
fi
record "WATERCOLOR_RELEASE_QUALIFICATION gate=clean_tests status=RUNNING"
run_logged swift package clean
run_logged swift test --no-parallel
record "WATERCOLOR_RELEASE_QUALIFICATION gate=clean_tests status=PASS"

record "WATERCOLOR_RELEASE_QUALIFICATION gate=metal_validation status=RUNNING"
run_logged env \
    WATERCOLOR_REQUIRE_METAL=1 \
    MTL_DEBUG_LAYER=1 \
    MTL_DEBUG_LAYER_VALIDATE_LOAD_ACTIONS=1 \
    MTL_DEBUG_LAYER_VALIDATE_STORE_ACTIONS=1 \
    MTL_SHADER_VALIDATION=1 \
    swift test --filter WatercolorRendererTests
record "WATERCOLOR_RELEASE_QUALIFICATION gate=metal_validation status=PASS"

record "WATERCOLOR_RELEASE_QUALIFICATION gate=gpu_and_heartbeat status=RUNNING"
run_logged env \
    WATERCOLOR_REQUIRE_METAL=1 \
    WATERCOLOR_RUN_BENCHMARK=1 \
    swift test --filter PerformanceQualificationTests
record "WATERCOLOR_RELEASE_QUALIFICATION gate=gpu_and_heartbeat status=PASS"

record "WATERCOLOR_RELEASE_QUALIFICATION gate=local_package status=RUNNING"
run_logged make app
run_logged plutil -lint "${application_bundle}/Contents/Info.plist"
test -x "${application_executable}"
application_icon="${application_bundle}/Contents/Resources/WatercolorStudio.icns"
test -s "${application_icon}"
run_logged /usr/bin/sips -g format -g pixelWidth -g pixelHeight "${application_icon}"
icon_format="$(/usr/bin/sips -g format "${application_icon}" | awk '/format:/ { print $2 }')"
icon_width="$(/usr/bin/sips -g pixelWidth "${application_icon}" | awk '/pixelWidth:/ { print $2 }')"
icon_height="$(/usr/bin/sips -g pixelHeight "${application_icon}" | awk '/pixelHeight:/ { print $2 }')"
if [[ "${icon_format}" != "icns" ]] \
    || [[ ! "${icon_width}" =~ ^[1-9][0-9]*$ ]] \
    || [[ ! "${icon_height}" =~ ^[1-9][0-9]*$ ]]; then
    echo "The packaged application icon is not a decodable ICNS resource." >&2
    exit 5
fi
record "WATERCOLOR_RELEASE_QUALIFICATION gate=local_package status=PASS"

record "WATERCOLOR_RELEASE_QUALIFICATION gate=optimized_customer_input status=RUNNING"
run_optimized_qualification
record "WATERCOLOR_RELEASE_QUALIFICATION gate=optimized_customer_input status=PASS"

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" && -n "${NOTARYTOOL_PROFILE:-}" ]]; then
    record "WATERCOLOR_RELEASE_QUALIFICATION gate=signing_notarization status=RUNNING"
    run_logged make distribution
    record "WATERCOLOR_RELEASE_QUALIFICATION gate=signing_notarization status=PASS"
elif [[ -n "${DEVELOPER_ID_APPLICATION:-}" || -n "${NOTARYTOOL_PROFILE:-}" ]]; then
    echo "Both DEVELOPER_ID_APPLICATION and NOTARYTOOL_PROFILE are required together." >&2
    exit 2
else
    record "WATERCOLOR_RELEASE_QUALIFICATION gate=signing_notarization status=NOT_RUN reason=credentials_not_supplied"
fi

record "WATERCOLOR_RELEASE_QUALIFICATION gate=liveness status=RUNNING"
launch_tracked_process \
    "${working_directory}/liveness.log" \
    "${application_executable}"
for ((liveness_second = 1; liveness_second <= liveness_seconds; liveness_second += 1)); do
    /bin/sleep 1
    if ! kill -0 "${qualification_pid}" 2>/dev/null; then
        echo "Watercolor Studio exited before the liveness gate at second ${liveness_second}." >&2
        exit 3
    fi
done
termination_status=0
terminate_qualification_process || termination_status=$?
if [[ "${termination_status}" -ne 0 ]]; then
    echo "Watercolor Studio did not terminate cleanly after the liveness gate." >&2
    exit 3
fi
mkdir -p "${qualification_directory}"
cp "${working_directory}/liveness.log" "${qualification_directory}/liveness.log"
record "WATERCOLOR_RELEASE_QUALIFICATION gate=liveness status=PASS duration_seconds=${liveness_seconds} terminated=true"

run_logged git diff --check
record "WATERCOLOR_RELEASE_QUALIFICATION gate=diff_check status=PASS"
record "WATERCOLOR_RELEASE_QUALIFICATION status=PASS report=${qualification_report}"
