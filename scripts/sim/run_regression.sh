#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VIVADO_SETTINGS="/home/jmhwang/tools/Xilinxe/Vivado/2022.2/settings64.sh"
LOG_DIR="${REPO_ROOT}/build/regression"

mkdir -p "${LOG_DIR}"
cd "${REPO_ROOT}"

if [[ ! -r "${VIVADO_SETTINGS}" ]]; then
  echo "ERROR: Vivado settings not found: ${VIVADO_SETTINGS}" >&2
  exit 2
fi
# shellcheck disable=SC1090
source "${VIVADO_SETTINGS}"

run_stage() {
  local name="$1"
  shift
  echo "RUN ${name}"
  if "$@" >"${LOG_DIR}/${name}.log" 2>&1; then
    echo "STAGE ${name} PASS"
    return 0
  fi
  echo "STAGE ${name} FAIL"
  tail -n 80 "${LOG_DIR}/${name}.log"
  return 1
}

stage_fail=0
run_stage vector_gen python3 scripts/vector_gen/generate_full_conv_vector.py || stage_fail=1
run_stage smoke vivado -mode batch -nolog -nojournal -source scripts/sim/run_xsim.tcl || stage_fail=1
run_stage unit vivado -mode batch -nolog -nojournal -source scripts/sim/run_unit_tests.tcl || stage_fail=1
run_stage directed vivado -mode batch -nolog -nojournal -source scripts/sim/run_directed_xsim.tcl || stage_fail=1
run_stage full_conv vivado -mode batch -nolog -nojournal -source scripts/sim/run_full_conv_xsim.tcl || stage_fail=1

if (( stage_fail != 0 )); then
  echo "TOTAL: stage execution failed"
  exit 1
fi

pass_count=0
fail_count=0

report_test() {
  local name="$1"
  shift
  if "$@"; then
    printf "TEST %-28s PASS\n" "${name}"
    pass_count=$((pass_count + 1))
  else
    printf "TEST %-28s FAIL\n" "${name}"
    fail_count=$((fail_count + 1))
  fi
}

has_all() {
  local file="$1"
  shift
  local marker
  for marker in "$@"; do
    grep -Fq "${marker}" "${file}" || return 1
  done
}

report_test smoke has_all "${LOG_DIR}/smoke.log" \
  "SMOKE PASS: 64 output bytes matched"
report_test scalar_arithmetic has_all "${LOG_DIR}/unit.log" \
  "UNIT PASS: sat_add_int32" "UNIT PASS: requantizer" "UNIT PASS: relu_clamp"
report_test stride2 has_all "${LOG_DIR}/directed.log" \
  "stride2 PASS"
report_test padding0 has_all "${LOG_DIR}/directed.log" \
  "padding0 PASS"
report_test signed_bias_relu_off has_all "${LOG_DIR}/directed.log" \
  "signed_bias_relu_off_requant PASS"
report_test requant_rounding has_all "${LOG_DIR}/unit.log" \
  "positive half tie PASS" "negative half tie PASS"
report_test packet_error has_all "${LOG_DIR}/directed.log" \
  "early_tlast PASS" "missing_tlast PASS" "invalid_tkeep PASS" \
  "buffer_capacity_invalid PASS" "register_byte_mismatch PASS"
report_test abort_recovery has_all "${LOG_DIR}/directed.log" \
  "abort PASS" "recovery_after_abort PASS"
report_test consecutive_operation has_all "${LOG_DIR}/directed.log" \
  "consecutive_operation_1 PASS" "consecutive_operation_2 PASS"
report_test full_conv has_all "${LOG_DIR}/full_conv.log" \
  "FULL CONV PASS: 16384 output bytes, mismatch=0"

echo "TOTAL: ${pass_count} PASS, ${fail_count} FAIL"
if (( fail_count != 0 )); then
  exit 1
fi
exit 0
