# Phase 3B-2 completion-fix Zybo artifact rebuild verification

## 1. Baseline and scope

- Branch: `integration/zybo-bootbin`
- Local/origin commit: `4c8ac3ae37a52907613e7af7c6c6988aa455ad21`
- Subject: `fix(rtl): align DONE assertion with BUSY deassert`
- Vivado: 2022.2
- Board: Zybo Z7-20, `digilentinc.com:zybo-z7-20:part0:1.2`
- Part: `xc7z020clg400-1`

이 문서는 `build/reports/PHASE_3B2_ARTIFACT_REBUILD_REPORT.md`의 GitHub용
정리본이다. 기존 untracked `scripts/vitis/build_stage1_boot_image.tcl`은 build
중 수정·삭제·stage·commit하지 않았다.

## 2. IP propagation audit

`scripts/vivado/package_resnet_accel_ip.tcl`은 repository RTL을 packaging
project에 추가하고 `ipx::package_project -import_files`를 실행한다. 따라서
packaged IP는 repository RTL의 source copy를 보유한다.

- IP repository: `build/ip_repo`
- Packaged IP: `build/ip_repo/resnet_accel_1_0`
- VLNV: `jmhwang.local:npu:resnet_accel:1.0`
- Interfaces: S_AXI_CTRL slave, S_AXIS_INPUT slave, M_AXIS_OUTPUT master,
  `aclk`, active-low `aresetn`
- AXI-Lite register block: 128 bytes
- AXI stream width: 32 bits

Repackaging 전 packaged source와 HEAD의 hash가 달라 기존 package가 stale임을
확인했다. 공식 Tcl flow로 packaging project와 IP root를 다시 만들고 Block
Design project도 처음부터 재생성했으므로 이전 IP cache나 implementation
checkpoint를 재사용하지 않았다.

### Completion source hash proof

| Source | Repository / packaged / BD synthesis SHA-256 | Result |
|---|---|---|
| `rtl/control/controller_fsm.sv` | `f4f1bb1016b2d58b0cb45474827a76f25c4282aa131e9c2a4914b0ffe4500435` | Three-way match |
| `rtl/stream/axis_output_streamer.sv` | `b219c57310220cd97e3d5494a79e8f49819221b7388719fe88706c8508e68dd3` | Three-way match |

Packaged controller는 final output event로 `operation_done_o`를 만들고,
packaged streamer는 `TVALID && TREADY && TLAST`로 `done_o`를 만든다.

## 3. Block Design status

`scripts/vivado/create_zybo_system.tcl` flow는 Vivado project를 재생성하고
`build/ip_repo`를 refresh한 뒤 BD validation, output product generation 및 HDL
wrapper 생성을 수행했다.

- BD: `zybo_resnet_system`
- Accelerator instance: `resnet_accel_0`
- VLNV: `jmhwang.local:npu:resnet_accel:1.0`
- `validate_bd_design`: PASS
- `generate_target all`: PASS
- Wrapper regeneration: PASS
- AXIS width mismatch: 0
- Validation errors: 0
- IP upgrade/VLNV collision: 없음

## 4. Clock, reset, DMA and address map

| 항목 | 값 |
|---|---|
| Accelerator | `0x43C00000`–`0x43C0FFFF` |
| AXI DMA control | `0x40400000`–`0x4040FFFF` |
| DMA DDR aperture | `0x00000000`–`0x3FFFFFFF` |
| PS7 FCLK0 | 100 MHz |
| Reset source | `processing_system7_0/FCLK_RESET0_N` |
| Reset synchronizer | `proc_sys_reset_0` |
| Peripheral reset | `proc_sys_reset_0/peripheral_aresetn` |
| DMA mode | Simple mode, SG off, DRE off, polling |
| DMA channels | MM2S and S2MM enabled |
| Stream width | MM2S/S2MM 32 bits |
| DMA interrupts | Unconnected |

## 5. Synthesis

- Run: `synth_1`
- Status: `synth_design Complete!`
- Errors: 0
- Critical warnings: 0
- Warnings: 25
- Black boxes: 0
- Accelerator RAMB36E1/RAMB18E1/DSP48E1: 24/1/3
- Accelerator LUTRAM/SRL: 0

Memory/DSP structure acceptance와 source provenance check는 PASS했다.

## 6. Implementation strategy comparison

| Label | Strategy | WNS | TNS | Setup failures | WHS | Result |
|---|---|---:|---:|---:|---:|---|
| baseline | Vivado Implementation Defaults | -0.094 ns | -0.230 ns | 3 | +0.024 ns | FAIL |
| performance_explore | Performance_Explore | -0.140 ns | -0.193 ns | 4 | +0.050 ns | FAIL |
| performance_postroute_physopt | Performance_ExplorePostRoutePhysOpt | **+0.011 ns** | **0.000 ns** | **0** | **+0.050 ns** | **PASS** |

최종 run은 `impl_performance_postroute_physopt`이다. Vivado 2022.2 built-in
strategy의 Explore directive와 post-route physical optimization을 사용했으며,
clock relaxation, false path, RTL 수정 또는 수동 constraint exception은 없다.

## 7. Final timing and implementation result

| Metric | Result |
|---|---:|
| Clock period | 10.000 ns |
| Setup WNS / TNS | +0.011 ns / 0.000 ns |
| Setup failed endpoints | 0 |
| Hold WHS / THS | +0.050 ns / 0.000 ns |
| Hold failed endpoints | 0 |
| Pulse-width worst slack | +3.750 ns |
| Pulse-width failed endpoints | 0 |
| No-clock registers | 0 |
| Unconstrained internal endpoints | 0 |
| Unrouted nets | 0 |
| DRC errors | 0 |

Pre-write 및 post-bitstream timing check가 같은 PASS 수치를 보고했다.

### Utilization

- Slice LUTs: 6,109
- FFs: 7,618
- RAMB36/FIFO: 26
- RAMB18: 1
- DSP: 3
- BUFGCTRL: 2
- DRC warnings/advisories: 8/2
- Post-bitstream DRC errors: 0

## 8. Regression after artifact generation

| Flow | Result |
|---|---|
| Canonical Full Conv XSim | PASS |
| Unit regression | PASS, 3 tests / 33 checks |
| Directed regression | PASS, 51 checks |
| Packaged-wrapper smoke/full-conv | PASS |
| Verilator lint | Exit 0, no errors |
| Icarus smoke | PASS, 64 bytes matched |
| `git diff --check` | PASS |

Canonical observations:

- Final handshake: cycle 1,435,476
- BUSY deassert: cycle 1,435,476
- DONE assertion: cycle 1,435,476
- COMPLETE: cycle 1,435,476
- IDLE: cycle 1,435,477
- DONE 100-clock sticky hold: PASS
- Explicit W1C: PASS
- Output: 16,384 bytes
- Mismatch: 0
- Cycle count: 1,435,390
- ERROR / ERROR_CODE: 0 / NONE
- Full regression failures: 0

## 9. Approved bitstream

- Path: `build/vivado_zybo/artifacts/zybo_resnet_system.bit`
- Size: 4,045,686 bytes
- SHA-256: `92258e28659f863d5cad6d3126752ca933ba1849068f40aee772dce98f10ad77`
- Source: official `impl_performance_postroute_physopt` run bitstream
- Official run copy hash check: PASS
- Implementation DCP immutability during `write_bitstream`: PASS

수정 전 bitstream
`a0313efc078dbe644126534e5fbad106bd0e689eef28073e01eb62ad1dd56e4c`는
completion fix를 포함하지 않는 superseded artifact다.

## 10. Approved XSA

- Path: `build/vivado_zybo/artifacts/zybo_resnet_system.xsa`
- Size: 693,747 bytes
- SHA-256: `6affcfc6d742dc3f47abda1e4aaa0ce1c178544cae53b9fc0cb14c3f57afd394`
- Archive integrity: PASS
- Embedded bitstream: 정확히 1개
- Embedded bitstream SHA-256:
  `92258e28659f863d5cad6d3126752ca933ba1849068f40aee772dce98f10ad77`
- External bitstream match: PASS
- HWH metadata present: PASS
- PS/address/IP metadata validation: PASS

수정 전 XSA
`01f7f2121b6940064491ae7a25de46f6a4233f1a93ae3547a8ff67ea1b60477b`는
superseded artifact다.

## 11. BOOT package linkage

Completion-fix bitstream은 후속 Vitis/Bootgen package에 반영됐다.

- BOOT.BIN: `build/vitis/boot_package_completion_fix/BOOT.BIN`
- Size: 4,215,376 bytes
- SHA-256: `575258491fbfa6883e9a00a721461b1a3b9b483444895f5ed4fee3a9f336c397`

## 12. Board verification boundary

Synthesis, implementation, timing, regression 및 artifact provenance는 PASS다.
그러나 실제 board verification은 완료되지 않았다. 신규 completion-fix
BOOT.BIN에서도 `status=0x1` runtime failure가 보고되어 추가 분석 중이다.
따라서 이 문서는 Zybo Z7-20 board PASS나 실제 output mismatch 0을 주장하지
않는다.
