# Completion-edge fix build verification summary

## Status

> **RTL simulation, implementation, timing 및 artifact provenance는 PASS.  
> 실제 Zybo Z7-20 board runtime failure는 추가 분석 중.**

이 문서는 completion-edge normative fix가 반영된 RTL의 regression, Vivado
implementation/timing closure, hardware artifact 및 BOOT package provenance를
GitHub에서 한눈에 확인하기 위한 요약이다. 실제 보드 검증 완료를 주장하지
않는다. 신규 BOOT.BIN을 사용한 보드 실행에서도 `status=0x1` 현상이 보고되어
runtime failure 원인을 별도로 분석해야 한다.

상세 근거:

- [RTL completion-edge fix](RTL_COMPLETION_EDGE_FIX_REPORT.md)
- [Vivado artifact rebuild](PHASE_3B2_ARTIFACT_REBUILD_REPORT.md)
- [Bootgen overlap warning](BOOTGEN_OVERLAP_WARNING_ANALYSIS.md)

## Source baseline

| 항목 | 값 |
|---|---|
| Branch | `integration/zybo-bootbin` |
| Hardware commit | `4c8ac3ae37a52907613e7af7c6c6988aa455ad21` |
| Commit subject | `fix(rtl): align DONE assertion with BUSY deassert` |
| Board | Zybo Z7-20 |
| FPGA part | `xc7z020clg400-1` |
| Vivado | 2022.2 |
| PL clock | 100 MHz, 10.000 ns |

## Completion contract and canonical regression

정상 operation의 final output beat가 `TVALID && TREADY && TLAST`로 수락되는
cycle에 BUSY deassert와 sticky DONE assertion이 동시에 관측되어야 한다.

| 관측 항목 | 결과 |
|---|---:|
| Final output handshake | cycle `1,435,476` |
| BUSY deassert | cycle `1,435,476` |
| DONE assertion | cycle `1,435,476` |
| COMPLETE observable | cycle `1,435,476` |
| IDLE observable | cycle `1,435,477` |
| DONE sticky hold | 100 clocks, PASS |
| Explicit DONE W1C | PASS |
| Canonical output | 16,384 bytes |
| Mismatch | 0 |
| Accelerator cycle count | 1,435,390 |
| Full regression failures | 0 |

검증 범위에는 Vivado smoke, 3개 unit test, 51개 directed integration/error
check, canonical Full Conv, packaged-wrapper smoke/Full Conv, Icarus smoke,
Verilator lint 및 `git diff --check`가 포함된다.

## Vivado implementation and timing

| 항목 | 값 |
|---|---|
| Implementation run | `impl_performance_postroute_physopt` |
| Strategy | `Performance_ExplorePostRoutePhysOpt` |
| Setup WNS / TNS | **+0.011 ns / 0.000 ns** |
| Hold WHS / THS | **+0.050 ns / 0.000 ns** |
| Setup / Hold failed endpoints | 0 / 0 |
| Unconstrained endpoints | 0 |
| Unrouted nets | 0 |
| DRC errors | 0 |

기본 implementation과 `Performance_Explore` run은 setup timing을 통과하지
못했으며, 승인된 결과는 post-route physical optimization이 적용된 위 run이다.

## Approved completion-fix artifacts

| Artifact | Repository-relative path | Size | SHA-256 |
|---|---|---:|---|
| Bitstream | `build/vivado_zybo/artifacts/zybo_resnet_system.bit` | 4,045,686 bytes | `92258e28659f863d5cad6d3126752ca933ba1849068f40aee772dce98f10ad77` |
| XSA | `build/vivado_zybo/artifacts/zybo_resnet_system.xsa` | 693,747 bytes | `6affcfc6d742dc3f47abda1e4aaa0ce1c178544cae53b9fc0cb14c3f57afd394` |
| BOOT.BIN | `build/vitis/boot_package_completion_fix/BOOT.BIN` | 4,215,376 bytes | `575258491fbfa6883e9a00a721461b1a3b9b483444895f5ed4fee3a9f336c397` |

XSA에는 bitstream이 정확히 한 개 포함되며 embedded bitstream SHA-256도
`92258e...ad77`로 외부 bitstream과 일치한다.

### Superseded artifacts

다음 수정 전 artifact는 completion-edge fix를 포함하지 않으므로 사용하지
않는다.

| Artifact | Superseded SHA-256 |
|---|---|
| Previous bitstream | `a0313efc078dbe644126534e5fbad106bd0e689eef28073e01eb62ad1dd56e4c` |
| Previous XSA | `01f7f2121b6940064491ae7a25de46f6a4233f1a93ae3547a8ff67ea1b60477b` |

## Source provenance

공식 IP packaging flow는 repository RTL을 `-import_files`로 packaged IP
source에 복사한다. 다음 두 completion 핵심 파일은 repository source,
packaged IP source 및 Block Design `ipshared` synthesis source에서 각각
동일한 SHA-256을 가진다.

| RTL | Three-way SHA-256 |
|---|---|
| `rtl/control/controller_fsm.sv` | `f4f1bb1016b2d58b0cb45474827a76f25c4282aa131e9c2a4914b0ffe4500435` |
| `rtl/stream/axis_output_streamer.sv` | `b219c57310220cd97e3d5494a79e8f49819221b7388719fe88706c8508e68dd3` |

따라서 승인 bitstream/XSA가 stale packaged RTL에서 생성됐다는 근거는 없다.

## BOOT image and Bootgen warning

BIF partition 순서는 다음과 같다.

1. `[bootloader]` FSBL ELF
2. `zybo_resnet_system.bit`
3. Application ELF

Bootgen 2022.2는 FSBL↔bitstream 및 bitstream↔Application memory-range overlap
warning을 출력하지만 image 생성은 성공한다. 정적 load-map 분석과 격리 실험의
판정은 **B. SAFE WITH EXPLANATION**이다.

- FSBL과 Application ELF의 PT_LOAD/live range는 실제로 겹치지 않는다.
- BOOT.BIN 내부 partition file offsets도 겹치지 않는다.
- bitstream은 PL configuration partition이다.
- SD boot에서 FSBL이 bitstream을 DDR에 임시 staging하고 PCAP configuration을
  완료한 뒤 Application이 같은 DDR 주소를 시간 분할로 재사용한다.

이 warning 때문에 현재 BOOT.BIN을 수정하거나 재생성할 필요가 있다는 근거는
없다.

## Board verification boundary

다음은 완료 및 검증됐다.

- RTL simulation과 full regression
- packaged IP source propagation
- synthesis와 implementation
- 100 MHz timing closure
- bitstream/XSA/BOOT.BIN 생성 및 hash provenance
- Bootgen overlap warning 정적 분석

다음은 완료되지 않았다.

- completion-fix BOOT.BIN의 실제 Zybo Z7-20 runtime PASS
- Stage-1 canonical output의 실제 보드 `mismatch=0`

신규 BOOT.BIN에서도 `STATUS=0x1` (`IDLE=1`, `BUSY=0`, `DONE=0`,
`ERROR=0`)이 보고되었으므로, simulation PASS를 board PASS로 확대 해석하면
안 된다. 다음 분석은 artifact를 추측으로 다시 수정하기 전에 UART log,
START admission, BUSY/DONE 관측, DMA MM2S/S2MM 상태, cycle counter 및 FSM
debug state로 failure stage를 먼저 분리해야 한다.
