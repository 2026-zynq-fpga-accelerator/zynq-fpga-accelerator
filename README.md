# Zynq FPGA SoC 기반 ResNet 추론 가속기

Zynq-7000 SoC(Digilent **Zybo Z7-20**, XC7Z020-1CLG400C)에서 ResNet 추론을 수행하는
HW/SW 통합 프로젝트. Processing System(PS)의 ARM Cortex-A9에서 bare-metal C 펌웨어를
실행하고, Programmable Logic(PL)에 SystemVerilog로 작성한 ResNet 연산 가속기를 두어
AXI4-Lite(제어)와 AXI4-Stream + AXI DMA(데이터)로 통신한다. 최종 목표는 CIFAR-10용
ResNet-20을 FPGA에서 end-to-end로 실행하는 것이다.


## 아키텍처 요약

- **제어 경로**: PS ↔ 가속기 AXI4-Lite 레지스터 (CONTROL/STATUS/ERROR_CODE 등,
  W1C/W1P 시맨틱). 가속기 base address `0x43C00000` (`XPAR_RESNET_ACCEL_0_BASEADDR`).
- **데이터 경로**: AXI DMA(`axi_dma_0`, base `0x40400000`, simple/non-SG 모드)로
  weight → bias → input 순서로 MM2S 전송, 결과는 S2MM으로 회수.
- **PL 클럭/리셋**: PS7 `FCLK_CLK0` 100 MHz, `FCLK_RESET0_N`(active-low) →
  Processor System Reset IP → 가속기 `ARESETN` (극성 변환 없음).
- **연산**: fixed-point INT8 conv (NHWC/HWIO), bias add, requantize(M/N shift),
  ReLU. Weight/activation은 symmetric INT8 quantization으로 생성.
- 레지스터맵과 프로토콜의 최종 근거는 [`HW_SW_Interface_v1.1_FINAL.md`](HW_SW_Interface_v1.1_FINAL.md).

## 저장소 구조

```
python/         PyTorch reference model, BatchNorm folding, fixed-point quantization,
                bit-accurate golden model, test-vector exporter (+ 단위 테스트)
firmware/
  src/          accelerator 레지스터 드라이버, DMA wrapper, ResNet layer scheduler
  inc/          위 소스의 헤더 + 보드/BSP 연동 상수(platform_config.h)
  test/         실기 bring-up 테스트(stage1_conv_test.c), 생성된 테스트 벡터 헤더,
                RTL-canonical 벡터 provenance manifest
  host_stubs/   실제 Xilinx BSP 없이 `gcc -fsyntax-only`로 문법만 검사하기 위한
                최소 스텁 헤더 (실제 Vitis 빌드에는 쓰이지 않음)
verification/
  cocotb/       cocotb 기반 AXI4-Lite/AXI4-Stream 검증 환경 (BFM + 테스트)
  rtl_ref/      behavioral 레퍼런스 모델 (SystemVerilog) — 포트 계약의 근거
scripts/        테스트 벡터 생성기, Python 벡터 → firmware C 헤더 변환기
data/           생성된 테스트 벡터 바이너리 (gitignored, 스크립트로 재생성)
```

## 개발/검증 워크플로우

이 프로젝트는 실제 보드/Vivado/Vitis 없이도 대부분을 로컬에서 검증할 수 있도록
4단계로 나뉘어 있다.

1. **Python golden model** — PyTorch 모델을 fixed-point로 quantize하고, RTL과
   비교할 bit-accurate 결과 및 테스트 벡터(`config.json` + `*.bin`)를 생성한다.
   ```bash
   python -m unittest discover -s python/tests -t .   # 저장소 루트에서 실행
   ```
2. **cocotb 시뮬레이션 검증** — behavioral reference model(`verification/rtl_ref/`)을
   대상으로 AXI4-Lite/AXI4-Stream 프로토콜 레벨 회귀. 실제 RTL이 들어오면
   `verification/cocotb/Makefile`의 `VERILOG_SOURCES`/`TOPLEVEL`만 바꿔서 그대로 재사용.
   ```bash
   cd verification/cocotb && make   # 기대 결과: TESTS=9 PASS=9 FAIL=0
   ```
3. **Firmware 문법 검증 (host-side)** — 실제 Xilinx BSP 없이, `firmware/host_stubs/`의
   최소 스텁 헤더로 문법/타입 오류만 잡는다. 
   ```bash
   for f in firmware/src/*.c firmware/inc/*.h firmware/test/stage1_conv_test.c; do
     gcc -std=c99 -Wall -Wextra -fsyntax-only -Ifirmware/inc -Ifirmware/host_stubs "$f"
   done
   ```
4. **실기 bring-up** — Vitis로 빌드한 `BOOT.BIN`을 SD카드로 부팅,
   UART(115200 8-N-1)로 `stage1_conv_test`의 `PASS`/`FAIL` + mismatch 개수 + cycle
   count 확인. 

테스트 벡터를 바꾼 뒤에는 firmware C 헤더를 다시 만들어야 한다 (bare-metal에는
파일시스템이 없어서 `.bin`을 그대로 못 읽는다):

```bash
python3 scripts/generate_stage1_c_header.py \
  --approved-manifest firmware/test/stage1_vector_manifest.json
```

`--approved-manifest`는 선택 인자지만, 첫 실기 bring-up처럼 테스트 벡터의 출처를
확실히 해야 하는 경우에는 반드시 붙여야 한다 (SHA-256으로 벡터 무결성을 검증).

## 보드/타깃

- Board: Digilent **Zybo Z7-20** (XC7Z020-1CLG400C)
- Boot: SD카드 (FAT32) → FSBL → bitstream → `.elf`, `BOOT.BIN` 단일 파일로 부팅
- UART: 115200 baud, 8-N-1
