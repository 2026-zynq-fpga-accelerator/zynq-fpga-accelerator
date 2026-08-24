# 정밀도 후보 비교 (SW 시뮬레이션) — HW 검증 후보 압축용

재현: `firmware-verification/` 디렉토리에서 `python3 scripts/compare_precision_candidates.py` 실행 (torch/numpy만 필요). 저장소 최상위에서 실행할 경우 `python3 firmware-verification/scripts/compare_precision_candidates.py`.

## 결과

| format | logits 상대오차 | SQNR (dB) | 결정 일치율* | weight 저장량 | 압축률 (vs FP32) | activation 저장량† | 예상 traffic/이미지 | 절감률 (vs FP32) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| FP32 | 0.000% | inf | 100.00% | 1058.2 KB | 1.00x | 1612.3 KB | 2673.6 KB | 1.00x |
| FP16 | 0.015% | 76.25 | 100.00% | 529.1 KB | 2.00x | 806.1 KB | 1338.3 KB | 2.00x |
| **INT8** | 0.521% | 45.67 | 98.44% | 264.5 KB | 4.00x | 403.1 KB | 670.7 KB | 3.99x |
| INT4 | 9.618% | 20.34 | 81.25% | 132.3 KB | 8.00x | 201.5 KB | 336.9 KB | 7.94x |

아키텍처: conv 21층 + FC 1층, weight 270,896개 (ResNet-20 CIFAR-10).

## 결론 — HW 검증 우선순위

1. **INT8 유지** — 오차/압축 밸런스 최선, 이미 RTL 구현·보드 검증 완료.
2. **FP16 후순위** — 오차는 가장 낮지만 압축률 2x로 이득이 작아, datapath 재설계 비용 대비 우선순위 낮음.
3. **INT4 제외 권장** — 8x 압축이나 SQNR 20dB·결정 일치율 81%로 손실 급증. 32층 깊이에서 레이어를 거칠수록 오차가 누적되는 구조라 리스크가 큼.

## 주의사항

- `weight 저장량`·`activation 저장량`·`traffic`·`SQNR`은 신뢰 가능한 수치.
- †`activation 저장량`은 이미지 1장 기준(입력 32×32×3) 전 레이어 입/출력 activation 합계 — 레이어 간 캐시가 없다는 동일 가정하에 계산되어 `traffic`에도 그대로 포함됨.
- `결정 일치율`은 **실제 CIFAR-10 정확도가 아님** — 미학습 랜덤 가중치 기준 FP32 자기 자신과의 argmax 일치율(수치 안정성 proxy). 학습된 가중치가 없어 실제 정확도는 측정 불가(FINAL_SUBMISSION_REPORT.md §11 항목6과 동일 제약).
- traffic 모델은 이 프로젝트 RTL 구조(레이어당 weight/bias/input DMA-in + output DMA-out, 레이어 간 on-chip 캐시 없음)를 그대로 반영.
- bias는 포맷과 무관하게 항상 INT32(4바이트)로 가정 — 실제 RTL accumulator 폭과 동일.
