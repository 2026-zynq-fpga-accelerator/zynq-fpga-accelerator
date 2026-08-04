# Bootgen memory-range overlap warning analysis

## 1. Executive summary

최종 판정은 **B. SAFE WITH EXPLANATION**이다.

Bootgen warning은 BOOT.BIN file-offset 충돌이나 FSBL ELF와 Application ELF의
실제 ARM live-memory 충돌을 뜻하지 않는다. Bootgen 2022.2의 generic range
checker가 PL bitstream partition을 0 기반 memory range처럼 비교해 형식적
교집합을 보고한다.

이 판정은 warning 자체가 board runtime PASS를 증명한다는 뜻이 아니다. 신규
BOOT.BIN에서도 `status=0x1` failure가 보고됐으며 실제 board 원인은 추가 분석
중이다.

## 2. Analyzed image

- BOOT.BIN: `build/vitis/boot_package_completion_fix/BOOT.BIN`
- Size: 4,215,376 bytes
- SHA-256: `575258491fbfa6883e9a00a721461b1a3b9b483444895f5ed4fee3a9f336c397`
- BIF: `build/vitis/boot_package_completion_fix/boot_image.bif`
- Bootgen: Xilinx Bootgen v2022.2.0, build date Oct 13 2022

## 3. Warning text

```text
[WARNING]: Partition zybo_resnet_fsbl_completion_fix.elf.0 range is overlapped with partition zybo_resnet_system.bit.0 memory range
[WARNING]: Partition zybo_resnet_system.bit.0 range is overlapped with partition stage1_conv_test_completion_fix.elf.0 memory range
[INFO] : Bootimage generated successfully
```

Warning code는 출력되지 않았다.

## 4. BIF

```bif
the_ROM_image:
{
  [bootloader] zybo_resnet_fsbl_completion_fix.elf
  zybo_resnet_system.bit
  stage1_conv_test_completion_fix.elf
}
```

- `[bootloader]`는 FSBL에만 적용된다.
- 순서는 FSBL → PL bitstream → Application이다.
- Application에 잘못된 bootloader/load/startup/offset attribute가 없다.
- Bitstream 뒤 Application이 오는 순서는 Zynq FSBL flow와 일치한다.

## 5. ELF PT_LOAD ranges

### FSBL

- ELF32 ARM, EABI5, hard-float
- Entry: `0x00000000`

| Segment | PAddr/VAddr | FileSz | MemSz | Live interval | Flags |
|---|---:|---:|---:|---|---|
| PT_LOAD 0 | `0x00000000` | `0x00018008` | `0x0001D2E0` | `[0x00000000, 0x0001D2E0)` | RWE |
| PT_LOAD 1 | `0xFFFF0000` | `0x00000000` | `0x0000D400` | `[0xFFFF0000, 0xFFFFD400)` | RW |

FSBL은 low/high OCM에 위치한다.

### Application

- ELF32 ARM, EABI5, hard-float
- Entry: `0x00100000`

| Segment | PAddr/VAddr | FileSz | MemSz | Live interval | Flags |
|---|---:|---:|---:|---|---|
| PT_LOAD 0 | `0x00100000` | `0x00010010` | `0x00019FD0` | `[0x00100000, 0x00119FD0)` | RWE |

FSBL과 Application PT_LOAD는 file-backed 범위뿐 아니라 BSS/heap/stack을
포함한 live range에서도 겹치지 않는다. Link command에 `-Map`이 없어 `.map`
파일은 없었지만 ELF program/section headers, `objdump`, `size` 및 linker
scripts가 서로 일치했다.

## 6. Partition header table

| Partition | BOOT file offset | Length | Load | Exec | Raw attr |
|---|---:|---:|---:|---:|---:|
| FSBL | `0x00001700` | `0x00018008` | `0x00000000` | `0x00000000` | `0x10` |
| Bitstream | `0x00019740` | `0x003DBB00` | `0x00000000` | `0x00000000` | `0x20` |
| Application | `0x003F5240` | `0x00010010` | `0x00100000` | `0x00100000` | `0x10` |

BOOT.BIN file intervals:

- FSBL: `[0x00001700, 0x00019708)`
- Bitstream: `[0x00019740, 0x003F5240)`
- Application: `[0x003F5240, 0x00405250)`

File offsets는 서로 겹치지 않는다. Raw attribute `0x20`은 Zynq FSBL source의
PL image mask이고 `0x10`은 PS code partition mask다.

## 7. Bootgen checker ranges

Trace: `build/reports/bootgen_overlap_trace.log`

| Checker partition | Start | End exclusive | Length |
|---|---:|---:|---:|
| FSBL | `0x00000000` | `0x00018008` | `0x00018008` |
| Bitstream | `0x00000000` | `0x003DBB00` | `0x003DBB00` |
| Application | `0x00100000` | `0x00110010` | `0x00010010` |

Bootgen이 계산한 교집합:

- FSBL ∩ bitstream: `[0x00000000, 0x00018008)`, 98,312 bytes
- bitstream ∩ Application: `[0x00100000, 0x00110010)`, 65,552 bytes

이것은 bitstream bytes를 CPU memory image처럼 취급한 generic checker 결과다.

## 8. Runtime boot sequence

1. BootROM이 FSBL을 OCM에 적재하고 실행한다.
2. FSBL이 raw attribute `0x20`을 PL bitstream으로 식별한다.
3. SD 같은 non-linear boot path에서 bitstream을 DDR
   `[0x00100000, 0x004DBB00)`에 임시 staging한다.
4. FSBL이 `PcapLoadPartition()`으로 PL configuration을 완료한다.
5. Staging data가 더 이상 필요하지 않은 뒤 Application을
   `[0x00100000, 0x00119FD0)`에 적재한다.
6. `LoadBootImage()`가 Application entry `0x00100000`을 반환하고 FSBL이
   handoff한다.

Bitstream staging과 Application은 주소를 재사용하지만 동시에 유효한 데이터가
아닌 시간 분할 재사용이다. FSBL은 OCM에서 실행되므로 DDR overwrite의 영향을
받지 않는다.

## 9. Isolation experiment

| Partition combination | Warning count | Result |
|---|---:|---|
| FSBL + bitstream + Application | 2 | Generated successfully |
| FSBL + Application | 0 | Generated successfully |
| FSBL + bitstream | 1 | Generated successfully |

Bitstream을 제외하면 warning이 사라지므로 두 ELF 사이 실제 collision은
배제된다. 임시 isolation images는 진단용이며 배포 대상이 아니다.

## 10. Classification

**B. SAFE WITH EXPLANATION**

- BOOT file offset overlap: 없음
- Simultaneous CPU ELF live-memory collision: 없음
- PL bitstream staging과 Application DDR 주소 재사용: 있음
- 재사용 시점: PCAP 완료 전/후로 분리되어 안전
- Metadata/partition order 오류: 없음

따라서 이 warning만을 이유로 BIF, linker script, ELF, bitstream 또는 BOOT.BIN을
수정·재생성할 필요는 없다.

## 11. Board verification boundary

Overlap warning 분석은 해당 warning이 ELF collision 원인이 아님을 보여준다.
하지만 신규 BOOT.BIN의 Zybo Z7-20 runtime PASS를 보장하지는 않는다. 실제
보드에서 `status=0x1`이 다시 보고됐으므로 UART, START admission, DMA channel
status, cache/alignment, polling snapshot, cycle counter와 DEBUG_STATE를 기반으로
별도 분석해야 한다.
