# Stage 3 (R5: 1x1 Projection/Downsample) RTL 작업 요청 (정민님)

기준 문서: `STAGE3~1.MD` (§1: RTL 단독 결정 항목, §2-1: 은수님 쪽 결정 완료 항목). 이번 확장은
새 연산 추가가 아니라 기존 `OP_CONV`의 KERNEL_SIZE 허용 범위만 넓히는 것이라, v1.2(residual add)
때보다 합의가 필요한 항목이 훨씬 적습니다.

---

## 1. [필수] KERNEL_SIZE=1 RTL 파라미터화

새 opcode/새 register 없음. 기존 `OP_CONV`(0)가 `KERNEL_SIZE=1`도 처리하도록 확장하는 것만
필요합니다.

- **KERNEL_SIZE 허용값**: `{3}` → `{1, 3}`로 확장 (`CONV_CONFIG` `0x1C` bits[7:0]).
- **ERROR_CODE**: 신규 코드 없음. `ERR_INVALID_CONFIG`(3)가 kernel=1을 더 이상 거부하지 않도록
  validator만 조정.
- **RTL 내부 파라미터화 지점** (register/protocol과 무관한 순수 구현 작업):
  - `controller_fsm.sv`: KERNEL_SIZE 검증 로직, 출력 크기 계산 공식, 최소 patch 크기 검사 —
    총 3곳 하드코딩 파라미터화
  - `conv_engine.sv`: tap-loop 종료 조건, `kernel_row_advance_q` 계산식 — 총 2곳 파라미터화
- **변경 없음(확정, 재확인 불필요)**: opcode, register map, STRIDE/PADDING 허용값(이미
  STRIDE∈{1,2}, PADDING∈{0,1} 지원 중), DEBUG_STATE 규칙(v1.2 MAIN/SKIP latch 불필요, 단일
  packet 흐름), 연산 정의(기존 MAC→bias→requant→ReLU→clamp의 퇴화 케이스), 패킷 순서
  (WEIGHT→BIAS→INPUT→OUTPUT), BIAS_BYTES 공식(`OUT_CHANNELS×4`, kernel 무관), WEIGHT_BYTES
  공식(동일 공식에 `KERNEL_SIZE=1` 대입 시 값만 1/9로 감소).

펌웨어 쪽 byte-count 계산(`accel_driver.c`)도 이미 `layer->kernel`을 일반형으로 쓰고 있어
하드코딩이 없는 것을 코드로 재확인했습니다 — 펌웨어 쪽 조치 불필요.

---

## 2. [참고, 조치 불필요] DDR 버퍼 레이아웃 + 검증 순서 — 은수님 쪽 결정 완료

- Stage 2 identity 버전(4개 버퍼: input_x/conv1_output/conv2_output/block_output, 각
  16,384B)에서 5개 버퍼로 확장: `A: input_x(16,384B)` / `B: conv1_output(8,192B)` /
  `C: conv2_output(8,192B)` / `D: shortcut_output(8,192B, 신규)` / `E: block_output(8,192B)`.
  Stride=2로 해상도 절반·채널 2배라 각 feature map 바이트 수는 identity 버전의 정확히 절반.
- 실행 순서: `conv1 → conv2 → shortcut_conv → residual_add`로 확정.
- 검증 순서: kernel=1 새 BOOT.BIN 오면 5-buffer 통합 테스트 전에 **먼저 kernel=1 단독 minimal
  config**(예: 4×4×4→8, stride 2)로 byte-count 공식이 실기에서도 맞는지 선검증.

이 항목은 RTL/레지스터에 영향 없어서 정민님 쪽 조치는 필요 없고, 참고용입니다.

---

## 3. [필수] 검증

- **kernel=1 unit/directed test**: 양수/음수 입력, overflow/underflow saturation, kernel=1이라
  `padding` 항상 0인 조합, `stride=2`와 `kernel=1` 조합.
- **Stage-1/Stage-2 regression 유지 확인**: 기존 `kernel=3` 경로(단일 conv, identity residual
  add)가 이번 파라미터화로 깨지지 않았는지 재확인.
- **Conv1 → Conv2 → Shortcut_conv → Residual Add 통합 시뮬레이션**: 중간 checkpoint(conv1
  출력, conv2 출력, shortcut 출력, 최종 residual+ReLU 출력) 4개 전부 golden model과 mismatch 0.

---

## 4. [알려드릴 것] 이전 BOOT.BIN의 타이밍 마진 이슈(WNS -0.25ns) 후속 확인 결과

지난번 residual-add BOOT.BIN에서 100MHz 기준 conv MAC 경로 WNS -0.25ns(27,530개 중 6개
endpoint) 미클로징을 "알려진 이슈로 문서화 후 진행"으로 결정하셨던 것, 실기에서 후속 확인했습니다.

- `stage2_residual_test` 총 24회 연속 실행, 3개 checkpoint 전부 24회 모두 0/16384 mismatch.
  `cycle_count` 29942~29959 범위(스프레드 17)로 정상 폴링 지터 수준 — 간헐적 오류 전혀 관측 안 됨.
- 다만 24회 다 같은 입력 데이터라서, 이 타이밍 위반이 다른 데이터 패턴에서도 안전한지는 아직
  stress-test된 게 아닙니다. "완전히 무해"가 아니라 "이 조건에서는 미관측"으로 로그
  (`BRINGUP_ISSUE_LOG.md` ISSUE-005)에 남겨뒀습니다.
- **요청**: 이번 kernel=1 파라미터화로 로직이 더 늘면 이 마진이 더 나빠질 수 있으니, 재합성 후
  timing report(특히 WNS/위반 endpoint 수 변화)를 같이 공유해주시면 계속 추적하겠습니다.

---

## 5. [필수] 전달물

- 위 1, 3 반영한 새 bitstream/XSA/BOOT.BIN.

---

## 6. 참고 — 펌웨어 쪽 현황 (소은수)

- `firmware/test/stage3_projection_test.c` 작성 완료, push됨(커밋 `a0885bc`,
  `feat(firmware): add stage-3 projection-shortcut bring-up test scaffold`). conv1→conv2→
  shortcut_conv→residual_add 5-buffer 구조로 이미 짜여 있어, kernel=1 RTL/BOOT.BIN이 오면 바로
  실기 테스트 가능.
- Golden model/test vector(`data/test_vectors/stage2_basicblock_projection/`,
  `firmware/test/generated/stage2_projection_test_vector.h`)도 이미 준비돼 있음 — shortcut
  conv의 output scale이 conv2 output과 동일하게 강제돼 있어 residual add가 별도
  requantization 없이 바로 더할 수 있음(`scripts/generate_stage2_vectors.py`
  `target_output_scale` 처리).
