## 1. 최종 classification accuracy

`stage3_backbone_test`를 동일 test vector로 **32회 연속 실행**, 매회 `predicted_class=7`로 golden
model의 `expected_predicted_class=7`과 **100% 일치**.

Argmax 판정 기준(zero-padding 포함 12채널 중 유효 10개만 비교)까지 포함해 실기·golden 간
분류 결정이 완전히 일치했다.

## 2. Layer별 output mismatch

`stage3_backbone_test`가 32-layer(stem 1 + 9블록 × conv1/conv2/[shortcut]/residual_add + GAP +
FC) 실행 중 찍는 30개 checkpoint 전부 mismatch 0.

| Checkpoint | Byte 수 | Mismatch |
|---|---:|---:|
| stem | 16,384 | 0 |
| block01_conv1 / conv2 / output | 16,384 (×3) | 0 |
| block02_conv1 / conv2 / output | 16,384 (×3) | 0 |
| block03_conv1 / conv2 / output | 16,384 (×3) | 0 |
| block04_conv1 / conv2 / shortcut / output | 8,192 (×4) | 0 |
| block05_conv1 / conv2 / output | 8,192 (×3) | 0 |
| block06_conv1 / conv2 / output | 8,192 (×3) | 0 |
| block07_conv1 / conv2 / shortcut / output | 4,096 (×4) | 0 |
| block08_conv1 / conv2 / output | 4,096 (×3) | 0 |
| block09_conv1 / conv2 / output | 4,096 (×3) | 0 |
| gap | 64 | 0 |
| fc | 12 | 0 |

**30/30 checkpoint, 총 bit 수 기준 100% bit-exact 일치.** 반복 실행 전부 동일하게 clean —
9블록(32 op) 연속 실행에서 우려했던 상태 누적/리소스 재사용 문제 전혀 관측 안 됨.

## 3. Cycle count / Layer별 latency

**계측 방법**: `resnet_run()`이 각 layer 실행 직후 `accel_get_cycle_count()`를 호출해 32개 layer
전부 개별 latency를 확보한다. `hw_us`는 `hw_cycles / PL_CLOCK_HZ`(100MHz) 환산값, `wall_us`는
여기에 DMA 전송+펌웨어 폴링 오버헤드까지 포함한 값이다(대표 1회차 값 기재, 32회 반복 실행 전
구간에서 스프레드는 수백 cycle/수백 μs 이내로 좁아 RTL 결함 신호 없음 — 아래 4번 참조).

원본 로그(32회 전체 실행): [`resnet_log`](resnet_log)

| # | Layer (checkpoint) | wall_us | hw_us | 비고 |
|---:|---|---:|---:|---|
| 0 | stem | 14,419 | 14,359 | |
| 1 | block01_conv1 | 71,985 | 71,926 | |
| 2 | block01_conv2 | 71,985 | 71,926 | |
| 3 | block01_output | 358 | 299 | residual add |
| 4 | block02_conv1 | 71,985 | 71,926 | |
| 5 | block02_conv2 | 71,984 | 71,926 | |
| 6 | block02_output | 358 | 299 | residual add |
| 7 | block03_conv1 | 71,985 | 71,926 | |
| 8 | block03_conv2 | 71,985 | 71,926 | |
| 9 | block03_output | 358 | 299 | residual add |
| 10 | block04_conv1 | 36,046 | 36,013 | stride/채널 변경(downsample) |
| 11 | block04_conv2 | 71,422 | 71,389 | |
| 12 | block04_shortcut | 4,573 | 4,540 | 1×1 projection |
| 13 | block04_output | 186 | 152 | residual add |
| 14 | block05_conv1 | 71,422 | 71,389 | |
| 15 | block05_conv2 | 71,422 | 71,389 | |
| 16 | block05_output | 186 | 152 | residual add |
| 17 | block06_conv1 | 71,422 | 71,389 | |
| 18 | block06_conv2 | 71,422 | 71,389 | |
| 19 | block06_output | 185 | 152 | residual add |
| 20 | block07_conv1 | 35,790 | 35,770 | downsample |
| 21 | block07_conv2 | 71,237 | 71,216 | |
| 22 | block07_shortcut | 4,268 | 4,248 | 1×1 projection |
| 23 | block07_output | 99 | 79 | residual add |
| 24 | block08_conv1 | 71,237 | 71,216 | |
| 25 | block08_conv2 | 71,236 | 71,216 | |
| 26 | block08_output | 99 | 79 | residual add |
| 27 | block09_conv1 | 71,236 | 71,216 | |
| 28 | block09_conv2 | 71,237 | 71,216 | |
| 29 | block09_output | 99 | 79 | residual add |
| 30 | gap | 112 | 104 | |
| 31 | fc | 43 | 35 | |

## 4. 전체 inference latency / DMA transfer time

- **전체 inference latency**: `wall_us` ≈ **1,321,876 μs (약 1.32ms)** — `resnet_run()` 진입~종료까지
  `fw_time_now()`(`platform_time.h`) 기준, 32회 실행 평균(범위 1,321,777 ~ 1,322,046 μs, spread
  전체 대비 0.02% 미만 — AXI-Lite 폴링/타이머 지터로 판단, RTL 결함 아님).
- **HW 연산 시간만의 합**: `hw_us` ≈ **1,241,254 μs (약 1.24ms)**, 32회 실행 평균(범위
  1,241,252 ~ 1,241,256 μs).
- **DMA 전송 + 펌웨어 폴링 오버헤드**: `wall_us - hw_us` ≈ **80,600 μs (전체의 약 6.1%)**.
- **정확도 회귀 없음**: 32회 전 구간에서 30/30 checkpoint mismatch 0, `predicted_class=7` 매회
  golden model과 일치(위 1-2번 항목과 동일).

## 5. 자원 사용량 / 최대 동작 주파수 (빌드 `2d3c94b` 구현 리포트 기준)

| 자원 | 사용량 | 전체 | 사용률 |
|---|---:|---:|---:|
| Slice LUT | 7,328 | 53,200 | 13.77% |
| Slice Register (FF) | 8,230 | 106,400 | 7.73% |
| Block RAM Tile | 34.5 | 140 | 24.64% |
| DSP | 5 | 220 | 2.27% |

| Timing | 값 |
|---|---|
| 목표 클록 | 100MHz (`clk_fpga_0`, period 10ns) |
| WNS (Setup) | **+0.004ns** |
| WHS (Hold) | **+0.052ns** |
| TNS Failing Endpoints | 0 / 28,673 |
| THS Failing Endpoints | 0 / 28,673 |
| 결과 | "All user specified timing constraints are met." |
| DRC | Violations 14건, **전부 Warning(advisory), Error 0건** — Fully Routed |

## 6. 최종 성공 기준 대비 현황

| # | 기준 | 상태 |
|---|---|---|
| 1 | RTL이 synthesis 및 implementation을 통과한다 | ✅ 충족 (빌드 `2d3c94b`, DRC Error 0, "All user specified timing constraints are met.") |
| 2 | Firmware가 accelerator와 AXI DMA를 제어한다 | ✅ 충족 (전 단계에 걸쳐 반복 검증) |
| 3 | 단일 convolution 결과가 Python golden model과 일치 | ✅ 충족 (단계 1) |
| 4 | Basic Residual Block 결과가 Python reference와 일치 | ✅ 충족 (단계 2, identity+projection 둘 다) |
| 5 | CIFAR-10 ResNet-20을 end-to-end로 실행 | ✅ 충족 (32-layer 전체 체인 실기 검증) |
| 6 | FPGA classification accuracy를 측정한다 | ⚠️ **부분 충족** — 이 프로젝트의 모델은 학습되지 않은 랜덤 초기화 가중치를 사용하므로: golden model과의 결정 일치는 100% 측정했으나, 실제 CIFAR-10 데이터셋 기준 정확도는 범위 밖 |
| 7 | Cycle, latency, resource 사용량을 정량적으로 보고한다 | ✅ 충족 — resource/timing(위 5번) 완전, 32개 layer 전부 개별 cycle/latency 실측(위 3번), 전체 inference latency 실측(위 4번). DMA 전송 시간만의 단독 분리는 여전히 미측정이나 정량적 보고 요구사항 자체는 충족 |

**요약**: 6개 항목 중 6개 완전 충족, 1개(6, CIFAR-10 실데이터셋 정확도)는 랜덤 초기화 가중치라는
스코프상 자연스러운 이유로 부분 충족 — 남은 항목 6은 학습된 checkpoint가 있어야 해소 가능해 이번
하드웨어 bring-up 프로젝트 범위 밖으로 유지.
