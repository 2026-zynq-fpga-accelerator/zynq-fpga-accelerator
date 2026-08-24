# 마스터 문서 "단계 3" 기준 로드맵

## 0. 용어 정리 (혼동 방지)

- 마스터 문서(`Zynq_FPGA_SoC_기반_ResNet_추론_가속기_프로젝트.md` §5, §10)의 **"단계 3"** =
  CIFAR-10 ResNet-20 **end-to-end** 실행 (GAP, FC 포함).
- 지난번 완료된 **"STAGE3~1.MD / R5 projection shortcut"**(kernel=1 RTL, 빌드 `86ff3c7`)은 이름만
  "stage 3"였고, 실제로는 마스터 문서 §5 **단계 2**의 명시적 스코프("필요할 경우 projection
  shortcut")를 마무리하는 작업이었음. 마스터 문서 기준 진짜 단계 3까지는 아래 §2가 별도로 더 필요함.

---

## 1. 단계 2 마무리(projection shortcut) — 완료됨

`STAGE3_RTL_REQUEST.md`로 요청했던 항목 전부 완료:

1. **[완료]** `OP_CONV`의 KERNEL_SIZE 허용값 `{3}`→`{1,3}` 확장 — `controller_fsm.sv`/`conv_engine.sv`
   파라미터화. register map/opcode/packet 순서 변경 없음.
2. **[완료]** 검증 — kernel=1 unit/directed test, Stage-1/2 regression 유지, 4-checkpoint 통합
   시뮬레이션(conv1/conv2/shortcut/residual+ReLU) + 실기 `stage3_projection_test` 16회 연속
   PASS (2026-08-10).
3. **[완료]** 타이밍 마진(WNS -0.25ns, 6/27530 endpoint) 이슈 — 빌드 `86ff3c7`에서 WNS
   +0.001ns, 0/27647 endpoint로 완전 클로징 확인(`Performance_ExplorePostRoutePhysOpt` 전략).
4. **[완료]** 새 bitstream/XSA/BOOT.BIN(`86ff3c7`) 전달받음.

**마스터 문서 단계 2가 완전히 종료됨**(identity + projection shortcut 둘 다 실기 확인,
`BRINGUP_ISSUE_LOG.md` ISSUE-005 참조).

---

## 2. 마스터 문서 진짜 "단계 3"을 위해 앞으로 필요한 것

### 2.1 아직 아무것도 없는 것 — Global Average Pooling, Fully Connected layer

RTL도, register map도, 펌웨어 dispatch도 전혀 없음(`accel_configure()`가 `OP_GLOBAL_AVG_POOL`/
`OP_FC`를 지금도 거부 중). v1.1(conv)→v1.2(residual add)→v1.3(projection)과 같은 패턴으로 새
interface 합의부터 시작해야 함.

- **공동**: register map/packet protocol 합의 (`HW_SW_Interface_v1.4_DRAFT.md`류 새 문서로
  진행 — GAP은 H×W→1×1 reduction이라 packet 흐름이 conv와 다르고, FC는 matrix-vector 곱이라
  weight 전달 방식도 새로 정의해야 함).
- **정민님**: GAP RTL 설계/구현, FC RTL 설계/구현(MAC array 재사용 가능 여부 검토), synthesis/
  timing.
- **소은수**: GAP/FC golden model(Python `resnet_fp.py`의 `ResNet20CIFAR`에 이미
  `nn.Linear(64, num_classes)`와 GAP forward 로직이 있음 — 이를 fixed-point/quantized 버전으로
  변환), 펌웨어 dispatch(`accel_driver.c`에 `OP_GLOBAL_AVG_POOL`/`OP_FC` 브랜치 추가), test
  vector 생성.

### 2.2 Backbone 체이닝 — 16→32→64채널, 9개 BasicBlock

ResNet-20 CIFAR 구조는 stage당 3개 BasicBlock × 3 stage(각 stage 첫 블록만 projection shortcut,
나머지는 identity) = 9개 블록.

- **소은수**: 9개 블록 전체의 golden model/weight/test vector 생성(Python 모델은 이미
  `ResNet20CIFAR`로 존재, 아직 전체 9-block용 test vector export는 안 해봄). Layer descriptor
  리스트 작성 — `resnet_scheduler.c`의 `resnet_run()`은 이미 범용(루프 구조)이라 스케줄러 자체
  변경은 불필요, descriptor 배열만 9블록 분량으로 채우면 됨.
- **정민님**: 추가 RTL 불필요(conv/residual add/projection이 모두 파라미터화돼 있으면 반복
  재사용). 다만 여러 block을 연속으로 실행했을 때 리소스 재사용/타이밍에 새 문제가 없는지는
  확인 필요.
- **공동**: 실기에서 9블록 연속 실행 시 상태 누적/reset 관련 새 버그가 나오는지 확인(과거
  ISSUE-004류 문제가 다시 나올 수 있는 지점).

### 2.3 최종 정확도/성능 검증 (마스터 문서 §8.7, §11)

- **소은수**: FPGA classification accuracy를 Python fixed-point reference와 비교, layer별
  mismatch/cycle count/latency 정량 보고서 작성.
- **정민님**: LUT/FF/DSP/BRAM 사용량, 최대 동작 주파수 보고.
- 이 둘을 합쳐야 마스터 문서 §11 "최종 성공 기준"이 전부 충족됨.

---

## 3. 권장 순서

1. ~~kernel=1 projection RTL 완성 → 실기 검증 → 단계 2 완전 종료~~ **완료 (2026-08-10, 빌드 `86ff3c7`)**
   — `stage3_projection_test` 16회 연속 실행, 4-checkpoint 전부 PASS. 타이밍도 WNS -0.25ns/6
   endpoint 위반 → +0.001ns/0 위반으로 완전 클로징 확인(`BRINGUP_ISSUE_LOG.md` ISSUE-005 참조).
   **마스터 문서 단계 2(identity + projection shortcut) 완전히 종료.**
2. GAP/FC interface 논의 시작(공동) — v1.4 DRAFT류 문서로 register map/packet protocol 확정.
3. GAP RTL + FC RTL 구현(정민님), 동시에 소은수는 GAP/FC golden model + 펌웨어 dispatch 준비.
4. GAP, FC 각각 단독 board-level 검증.
5. 9-block 전체 backbone 조립 + GAP + FC 연결해서 end-to-end 실행.
6. 정확도/성능 보고서로 마스터 문서 §11 성공 기준 충족 확인 — 이게 마스터 문서 "단계 3" 완료.
