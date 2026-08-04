# Zybo Z7-20 Single OP_CONV Integration TODO

Last updated: 2026-07-31

## Completed baseline

- [x] Core RTL functional verification
- [x] Official regression: 10 PASS, 0 FAIL
- [x] Full convolution: 16,384 bytes, mismatch 0
- [x] Full operation cycle count: 1,435,391
- [x] Zybo board file recognized as `digilentinc.com:zybo-z7-20:part0:1.2`
- [x] FPGA part fixed as `xc7z020clg400-1`
- [x] 100 MHz OOC timing: WNS +0.691 ns, TNS 0, 0 failing endpoints
- [x] OOC memory/DSP inference reviewed

## Phase 3B-1 - Wrapper and packaged IP

- [x] Thin `resnet_accel_ip_wrapper` with AWPROT/ARPROT
- [x] Wrapper compile and elaboration
- [x] Wrapper smoke: 64 bytes, mismatch 0
- [x] Wrapper full vector: 16,384 bytes, mismatch 0, 1,435,391 cycles
- [x] Tcl-based package generation under `build/ip_repo/`
- [x] VLNV `jmhwang.local:npu:resnet_accel:1.0`
- [x] AXI4-Lite slave and AXIS slave/master explicit mapping
- [x] 7/32-bit AXI-Lite and 4-byte AXIS TDATA checks
- [x] Clock association with all three buses and active-low reset
- [x] `ipx::check_integrity` PASS
- [x] Generated paths ignored
- [x] Integration documentation updated

## Phase 3C - Block Design (requires separate approval)

- [ ] Create reproducible Vivado project/BD Tcl
- [ ] Configure PS7 FCLK_CLK0=100 MHz, GP0, HP0, and FCLK_RESET0_N
- [ ] Configure Processor System Reset with active-low external reset
- [ ] Configure AXI DMA Simple mode, SG/DRE/interrupts disabled, 32-bit streams
- [ ] Add packaged accelerator and interconnect/SmartConnect
- [ ] Connect GP0 control, HP0 DDR, MM2S input, and S2MM output paths
- [ ] Assign and record accelerator/DMA address ranges
- [ ] Validate Design with zero errors

## Phase 3D - Full hardware build

- [ ] Generate BD output products and HDL wrapper
- [ ] Run full synthesis and review warnings/resources
- [ ] Run implementation and review setup/hold timing
- [ ] Confirm no unintended CDC/reset issue
- [ ] Generate bitstream only after report review
- [ ] Export bitstream-included XSA

## Phase 3E - Firmware and BOOT.BIN

- [ ] Create Vitis platform/BSP from XSA
- [ ] Update accelerator/DMA identifiers from `xparameters.h`
- [ ] Verify aligned DDR buffers and cache maintenance
- [ ] Verify finite DMA/accelerator polling and recovery
- [ ] Build firmware ELF and FSBL
- [ ] Generate BOOT.BIN

## Physical-board test

- [ ] SD boot and UART capture
- [ ] DMA initialization and accelerator VERSION read
- [ ] Prepare 16,384-byte S2MM before START
- [ ] Send separate 432/64/3,072-byte MM2S packets
- [ ] Poll BUSY or ERROR after START admission
- [ ] Invalidate output cache and compare 16,384 bytes
- [ ] Record mismatch 0 and final cycle/status diagnostics

## Deferred until single OP_CONV hardware PASS

- [ ] Residual implementation and skip-packet decision
- [ ] Projection shortcut
- [ ] BatchNorm folding/export policy
- [ ] GAP/FC fixed-point behavior
- [ ] CPU fallback boundary
- [ ] Full ResNet-20 exporter, scheduler, and end-to-end inference

## Mandatory stop conditions

Do not modify the verified core or broaden the design if a phase would require a
register-map, packet, reset-polarity, datapath-cycle, stream-width, clock-domain,
CDC, controller, or AXI DMA contract change. Stop on regression, IP integrity,
Block Design validation, or board/part conflicts and report the first failure.
