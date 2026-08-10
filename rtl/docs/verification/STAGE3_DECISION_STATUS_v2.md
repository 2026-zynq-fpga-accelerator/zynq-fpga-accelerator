# Stage 3 (R5: 1×1 Projection/Downsample) 결정 사항 정리

기준 문서: `HW_SW_Interface_v1.3_DRAFT.md` (2026-08-10 작성, RTL 및 Python golden model
코드 직접 확인 기반). 이번 확장은 v1.2(OP_RESIDUAL_ADD, 새 연산 추가)와 달리 기존
OP_CONV의 파라미터 허용 범위만 넓히는 것이라, HW/SW 간 합의가 필요한 항목이 훨씬 적다.

---

## 1. 확정됨 — RTL 단독 결정 (은수님 확인 불필요)

| 항목 | 결정 내용 |
|---|---|
| Opcode | 새 opcode 없음. 기존 `OP_CONV`(0) 그대로 재사용 |
| Register map | 변경 없음. 새 register 없음, 재해석도 없음 |
| KERNEL_SIZE 허용값 | `{3}` → `{1, 3}`로 확장 (CONV_CONFIG 0x1C bits[7:0]) |
| STRIDE / PADDING 허용값 | 변경 없음 — 이미 필요한 범위(STRIDE∈{1,2}, PADDING∈{0,1}) 지원 중 |
| ERROR_CODE | 신규 코드 없음. `ERR_INVALID_CONFIG`(3)가 kernel=1을 더 이상 거부하지 않도록 validator만 조정 |
| DEBUG_STATE | v1.2 같은 MAIN/SKIP latch 규칙 불필요 (단일 packet 흐름이라 v1.1 규칙 그대로) |
| 연산 정의 | 변경 없음 — 기존 MAC→bias→requant→ReLU→clamp 파이프라인의 퇴화(degenerate) 케이스 |
| Packet 순서 | 변경 없음 — `WEIGHT → BIAS → INPUT → OUTPUT` 그대로 |
| BIAS_BYTES 공식 | 변경 없음 — kernel 크기와 무관 (`OUT_CHANNELS × 4`) |
| WEIGHT_BYTES 공식 | 공식 동일, `KERNEL_SIZE=1` 대입 시 값만 1/9로 감소 |

**RTL 내부 수정 항목** (register/protocol과 무관한 순수 구현 작업):
- `controller_fsm.sv`: KERNEL_SIZE 검증 로직, 출력 크기 계산 공식, 최소 patch 크기 검사 — 총 3곳 하드코딩 파라미터화
- `conv_engine.sv`: tap-loop 종료 조건, `kernel_row_advance_q` 계산식 — 총 2곳 파라미터화

---

## 2. 은수님 확인/결정 필요

| 항목 | 내용 | 이유 |
|---|---|---|
| **DDR 버퍼 레이아웃** | identity 버전(4개: A/B/C/D) → projection 버전(5개, `shortcut_output` 추가) | SKIP이 X 자체가 아니라 X를 1×1 conv한 결과이므로 별도 버퍼 필요. 게다가 stride=2로 해상도 절반·채널 2배 — 각 버퍼 크기 재계산 필요 |
| **byte-count 공식 실사용 검증** | `accel_driver.c`의 weight/bias byte 계산은 코드상 일반형(하드코딩 없음)으로 확인됨 — 다만 kernel=1 실제 호출이 board에서 실행된 이력이 없어 미검증 상태 | RTL 파라미터화 완료 후 함께 실기 검증 필요 |

---

## 2-1. 은수님 결정 (2026-08-10)

### DDR 버퍼 레이아웃 — 결정: 5개 버퍼로 확장

Stage 2 §4.8 기준(`Buffer A/B/C/D`, 각 16,384B = 32×32×16)에 stride=2/channel×2를 적용해
재계산. Input 32×32×16 → Output 16×16×32 (해상도 1/2, 채널 2배 → feature map 1개당
바이트 수는 정확히 절반: 32×32×16=16,384B → 16×16×32=8,192B).

```text
Buffer A: input_x            32×32×16 = 16,384 B   (변경 없음 — block 입력, downsample 전)
Buffer B: conv1_output       16×16×32 =  8,192 B   (conv1: 3×3, stride2, 16→32)
Buffer C: conv2_output       16×16×32 =  8,192 B   (conv2: 3×3, stride1, 32→32)
Buffer D: shortcut_output    16×16×32 =  8,192 B   (NEW — projection: 1×1, stride2, 16→32)
Buffer E: block_output       16×16×32 =  8,192 B   (residual add + Final ReLU 결과)
```

총 feature buffer 용량: 16,384 + 8,192×4 = **49,152 B** (identity 버전 65,536B보다 오히려 작음 —
버퍼 하나 늘었지만 나머지 4개가 스트라이드로 절반이 돼서).

- **주소/정렬**: Stage 2와 동일 원칙 유지 — 각 버퍼 32-byte aligned, 별도 output buffer 사용
  (in-place add 안 함), buffer 겹침 없음.
- **실행 순서**: `input_x(A) → conv1(B) → conv2(C)` 와 `input_x(A) → shortcut_conv(D)` 두 갈래를
  독립적으로 실행한 뒤, `C+D → residual_add → E`. 두 갈래 순서(conv1/conv2 먼저 vs shortcut 먼저)는
  RTL 쪽 제약 없으므로 편의상 conv1→conv2→shortcut→residual_add 순으로 확정.

### byte-count 공식 실사용 검증 — 결정: 별도 minimal 직접 테스트로 선검증

RTL 파라미터화된 새 BOOT.BIN이 오면, 바로 위 5-buffer 통합 테스트로 가지 않고 **먼저 kernel=1
단독 최소 config**(예: 4×4×4→8, stride 2)로 `WEIGHT_BYTES`/`BIAS_BYTES`/`OUTPUT_BYTES` 레지스터
값이 공식과 일치하는지 확인 — Stage 1때 `stage1_conv_test.c` 패턴 그대로 재사용. 이게 PASS해야
projection block 통합 테스트(위 5-buffer 구조)로 넘어감. 이 minimal test는 RTL 도착 후 은수님이
작성.

---

## 3. 참고

- 상세 근거·수식·체크리스트: `rtl/docs/HW_SW_Interface_v1.3_DRAFT.md`
- Python golden model(`resnet_fp.py`, `bn_fold.py`) 확인 결과, projection conv도 identity conv와 동일하게 BN-folded bias를 실제로 가짐 (bias 없는 conv 아님)
- kernel=1 + stride=2 조합의 실기 동작은 RTL 파라미터화·directed test 이후 별도 검증 필요
