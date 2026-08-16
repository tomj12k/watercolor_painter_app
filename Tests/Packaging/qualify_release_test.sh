#!/usr/bin/env bash
set -euo pipefail

source_repository="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/watercolor-qualify-test.XXXXXX")"
cleanup() {
    local exit_status=$?
    trap - EXIT INT TERM HUP
    if [[ -f "${test_root}/liveness-process.pid" ]]; then
        local leaked_pid
        leaked_pid="$(cat "${test_root}/liveness-process.pid")"
        if kill -0 "${leaked_pid}" 2>/dev/null; then
            kill -KILL "${leaked_pid}" 2>/dev/null || true
            wait "${leaked_pid}" 2>/dev/null || true
            exit_status=1
        fi
    fi
    rm -rf "${test_root}"
    exit "${exit_status}"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

make_fixture() {
    local fixture="$1"
    mkdir -p \
        "${fixture}/scripts" \
        "${fixture}/Resources" \
        "${fixture}/fake-bin"
    cp "${source_repository}/scripts/qualify_release.sh" "${fixture}/scripts/qualify_release.sh"
    cp "${source_repository}/Resources/WatercolorStudio.icns" "${fixture}/Resources/WatercolorStudio.icns"

    cat > "${fixture}/fake-bin/swift" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "package" && "${2:-}" == "clean" ]]; then
    if [[ "${FAKE_CLEAN_FAIL:-0}" == "1" ]]; then
        echo "controlled clean failure" >&2
        exit 41
    fi
    rm -rf .build
    exit 0
fi
if [[ "${1:-}" == "test" ]]; then
    echo "fake swift test pass"
    exit 0
fi
echo "unexpected swift invocation: $*" >&2
exit 42
SCRIPT

    cat > "${fixture}/fake-bin/make" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
    test)
        echo "fake make test pass"
        ;;
    app)
        bundle=".build/release/Watercolor Studio.app/Contents"
        mkdir -p "${bundle}/MacOS" "${bundle}/Resources"
        printf '<plist/>' > "${bundle}/Info.plist"
        cp Resources/WatercolorStudio.icns "${bundle}/Resources/WatercolorStudio.icns"
        cat > "${bundle}/MacOS/WatercolorStudio" <<'APP'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--qualify-customer-input" ]]; then
    echo "WATERCOLOR_QUALIFICATION metric=customer_input status=PASS"
    exit 0
fi
printf '%s\n' "$$" > "${WATERCOLOR_TEST_PID_FILE}"
if [[ "${FAKE_APP_IGNORES_TERM:-0}" == "1" ]]; then
    trap '' TERM
else
    trap 'exit 143' TERM
fi
while :; do /bin/sleep 0.05; done
APP
        chmod +x "${bundle}/MacOS/WatercolorStudio"
        ;;
    distribution)
        echo "fake distribution pass"
        ;;
    *)
        echo "unexpected make invocation: $*" >&2
        exit 43
        ;;
esac
SCRIPT

    cat > "${fixture}/fake-bin/plutil" <<'SCRIPT'
#!/usr/bin/env bash
exit 0
SCRIPT

    cat > "${fixture}/fake-bin/git" <<'SCRIPT'
#!/usr/bin/env bash
if [[ "${1:-}" == "diff" && "${2:-}" == "--check" ]]; then exit 0; fi
exit 44
SCRIPT

    chmod +x "${fixture}/scripts/qualify_release.sh" "${fixture}/fake-bin/"*
}

run_fixture() {
    local fixture="$1"
    shift
    (
        cd "${fixture}"
        env \
            PATH="${fixture}/fake-bin:/usr/bin:/bin" \
            WATERCOLOR_LIVENESS_SECONDS=1 \
            WATERCOLOR_TERMINATION_GRACE_SECONDS=1 \
            WATERCOLOR_TEST_PID_FILE="${test_root}/liveness-process.pid" \
            "$@" \
            scripts/qualify_release.sh
    )
}

clean_failure_fixture="${test_root}/clean-failure"
make_fixture "${clean_failure_fixture}"
if run_fixture "${clean_failure_fixture}" FAKE_CLEAN_FAIL=1; then
    echo "clean failure unexpectedly passed" >&2
    exit 1
fi
test -s "${clean_failure_fixture}/.build/qualification/report.txt"
grep -q 'status=FAIL' "${clean_failure_fixture}/.build/qualification/report.txt"

reporter_failure_fixture="${test_root}/reporter-failure"
make_fixture "${reporter_failure_fixture}"
cat > "${reporter_failure_fixture}/fake-bin/tee" <<'SCRIPT'
#!/usr/bin/env bash
exit 45
SCRIPT
chmod +x "${reporter_failure_fixture}/fake-bin/tee"
if run_fixture "${reporter_failure_fixture}"; then
    echo "reporter failure unexpectedly passed" >&2
    exit 1
fi
test -s "${reporter_failure_fixture}/.build/qualification/report.txt"
grep -q 'status=FAIL' "${reporter_failure_fixture}/.build/qualification/report.txt"

corrupt_icon_fixture="${test_root}/corrupt-icon"
make_fixture "${corrupt_icon_fixture}"
printf 'not an icon' > "${corrupt_icon_fixture}/Resources/WatercolorStudio.icns"
if run_fixture "${corrupt_icon_fixture}"; then
    echo "corrupt icon unexpectedly passed" >&2
    exit 1
fi
grep -q 'status=FAIL' "${corrupt_icon_fixture}/.build/qualification/report.txt"

wedged_app_fixture="${test_root}/wedged-app"
make_fixture "${wedged_app_fixture}"
SECONDS=0
if run_fixture "${wedged_app_fixture}" FAKE_APP_IGNORES_TERM=1; then
    echo "wedged app unexpectedly passed" >&2
    exit 1
fi
if (( SECONDS > 8 )); then
    echo "wedged app cleanup exceeded its bound" >&2
    exit 1
fi
wedged_pid="$(cat "${test_root}/liveness-process.pid")"
if kill -0 "${wedged_pid}" 2>/dev/null; then
    echo "wedged app process was left running" >&2
    exit 1
fi
grep -q 'status=FAIL' "${wedged_app_fixture}/.build/qualification/report.txt"
rm "${test_root}/liveness-process.pid"

happy_fixture="${test_root}/happy"
make_fixture "${happy_fixture}"
run_fixture "${happy_fixture}"
test -s "${happy_fixture}/.build/qualification/report.txt"
grep -q 'WATERCOLOR_RELEASE_QUALIFICATION status=PASS' \
    "${happy_fixture}/.build/qualification/report.txt"
happy_pid="$(cat "${test_root}/liveness-process.pid")"
if kill -0 "${happy_pid}" 2>/dev/null; then
    echo "happy-path app process was left running" >&2
    exit 1
fi
rm "${test_root}/liveness-process.pid"

echo "qualify_release_test: PASS"
