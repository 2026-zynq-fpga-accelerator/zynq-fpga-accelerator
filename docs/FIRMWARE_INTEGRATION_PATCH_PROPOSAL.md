# Phase 3E-1 Firmware Integration Patch Proposal

Date: 2026-08-01  
Status: design only; no firmware source was modified

## 0. Scope and proposed-diff conventions

This document proposes the smallest firmware-side changes needed to remove the
Phase 3E-1 integration blockers. It is based on firmware commit
`26421df63a0254cf00a0c94ce5a699dc3a2428dc`, hardware commit
`cecb4b66bc3cfb45a6cf2e0933f65b818374afbf`, and
`HW_SW_Interface_v1.1_FINAL.md`.

The diffs below are review material, not applied patches. They are cumulative:
later snippets assume the API changes introduced by earlier snippets. Exact
`xparameters.h` symbol spelling remains a Phase 3E-2 BSP-output check; no guessed
symbol should be silently replaced by a numeric fallback.

All blocking waits use the same policy:

- elapsed time is measured with standalone BSP `XTime_GetTime()`;
- each admission, accelerator-completion, DMA-completion, and reset-confirmation
  phase has a 100 ms deadline;
- DMA status is checked on every poll, including the final non-busy sample;
- a layer failure is diagnosed first, then accelerator abort/idle confirmation
  and both-channel DMA reset are coordinated before returning;
- S2MM is still armed before START and MM2S packet order remains
  Weight, Bias, Input.

### Shared proposed time helper

Target: new `firmware/inc/platform_time.h`. This keeps timer arithmetic out of
the accelerator and DMA drivers while adding only a header-only helper.

```diff
diff --git a/firmware/inc/platform_time.h b/firmware/inc/platform_time.h
new file mode 100644
--- /dev/null
+++ b/firmware/inc/platform_time.h
@@
+#ifndef PLATFORM_TIME_H
+#define PLATFORM_TIME_H
+
+#include <stdint.h>
+#include "xtime_l.h"
+
+#define FW_WAIT_TIMEOUT_MS 100U
+
+static inline XTime fw_time_now(void)
+{
+    XTime now;
+    XTime_GetTime(&now);
+    return now;
+}
+
+static inline int fw_time_expired(XTime start, uint32_t timeout_ms)
+{
+    const uint64_t ticks =
+        ((uint64_t)COUNTS_PER_SECOND * (uint64_t)timeout_ms) / 1000U;
+    return ((uint64_t)(fw_time_now() - start) >= ticks);
+}
+
+#endif
```

`COUNTS_PER_SECOND` is the BSP timer count rate, not `PL_CLOCK_HZ`. On Zynq-7000
the global timer count rate is not interchangeable with the 100 MHz PL FCLK.

## 1. START 후 BUSY 또는 ERROR admission polling

### 1. 대상 파일과 함수

- `firmware/inc/accel_driver.h`: new return code and admission API.
- `firmware/src/accel_driver.c`: `accel_wait_start_admitted()`,
  `accel_run_layer()`.

### 2. 현재 동작

`accel_run_layer()` arms S2MM, writes `CONTROL.START`, and immediately submits
the Weight MM2S transfer. It does not prove that START was accepted.

### 3. 문제 발생 시나리오

The RTL validates configuration before asserting BUSY; the completed RTL
regression observed 34 cycles of START admission latency. If configuration is
invalid, BUSY never rises and sticky ERROR is set. Current firmware can start
MM2S into an accelerator that never entered `LOAD_WEIGHT`, leaving the DMA busy
forever.

### 4. 제안하는 최소 수정

After START, poll until either `STATUS.BUSY=1` (accepted) or
`STATUS.ERROR=1` while BUSY remains zero (rejected). Apply a timer-based 100 ms
deadline before submitting any MM2S packet. Preserve ERROR/ERROR_CODE until the
scheduler logs them.

### 5. 하드웨어 계약 근거

Interface v1.1 §7.1 says packets follow a normally accepted START. §11.1 steps
7-9 require config validation and BUSY assertion before Weight MM2S. §11.2 says
an invalid START leaves BUSY low and records fatal ERROR. STATUS ERROR is sticky
and W1C (§8.4).

### 6. 기존 firmware 기능에 미치는 영향

The accepted path gains only a short register-poll delay. Packet ordering,
register programming, and successful result semantics do not change. Rejected
START changes from a possible hang to a bounded diagnostic return.

### 7. 테스트 방법

- Valid Stage-1 config: observe START, then BUSY, then first MM2S; first MM2S
  must not precede BUSY.
- Invalid `SHIFT_N=32`: expect ERROR, BUSY remains zero, no MM2S submission,
  and `ACCEL_START_REJECTED` within 100 ms.
- Stub STATUS as permanently IDLE/no ERROR: expect `ACCEL_TIMEOUT` at
  100 ms ± timer/polling tolerance and no MM2S.

### 8. proposed diff

```diff
diff --git a/firmware/inc/accel_driver.h b/firmware/inc/accel_driver.h
--- a/firmware/inc/accel_driver.h
+++ b/firmware/inc/accel_driver.h
@@
 #define ACCEL_VERSION_MISMATCH    (-5)
+#define ACCEL_START_REJECTED      (-6)
@@
-int accel_wait_done(uint32_t timeout);
+int accel_wait_start_admitted(uint32_t timeout_ms);
+int accel_wait_done(uint32_t timeout_ms);

diff --git a/firmware/src/accel_driver.c b/firmware/src/accel_driver.c
--- a/firmware/src/accel_driver.c
+++ b/firmware/src/accel_driver.c
@@
 #include "platform_config.h"
+#include "platform_time.h"
@@
+int accel_wait_start_admitted(uint32_t timeout_ms)
+{
+    XTime start = fw_time_now();
+    do {
+        uint32_t status = accel_reg_read(ACCEL_REG_STATUS);
+        if ((status & STATUS_BUSY_MASK) != 0U) {
+            return ACCEL_OK;
+        }
+        if ((status & STATUS_ERROR_MASK) != 0U) {
+            return ACCEL_START_REJECTED;
+        }
+    } while (!fw_time_expired(start, timeout_ms));
+    return ACCEL_TIMEOUT;
+}
@@
     rc = accel_start();
     if (rc != ACCEL_OK) {
         return rc;
     }
+    rc = accel_wait_start_admitted(FW_WAIT_TIMEOUT_MS);
+    if (rc != ACCEL_OK) {
+        return rc;
+    }
 
     uint32_t weight_bytes = accel_reg_read(ACCEL_REG_WEIGHT_BYTES);
```

## 2. Timer 기반 100 ms timeout

### 1. 대상 파일과 함수

- New `firmware/inc/platform_time.h` shown in §0.
- `firmware/src/accel_driver.c`: `accel_wait_done()`, abort confirmation.
- `firmware/src/dma_transfer.c`: DMA completion and reset waits.

### 2. 현재 동작

Accelerator completion uses `1,000,000` loop iterations, abort confirmation
uses 1,000 iterations, DMA completion has no limit, and DMA reset uses 10,000
iterations. None is a stated wall-clock duration.

### 3. 문제 발생 시나리오

Compiler optimization, memory latency, CPU clock, or debug/release settings
change loop duration. A claimed 100 ms timeout can fire too early or take an
unbounded time; DMA waits can hang permanently.

### 4. 제안하는 최소 수정

Interpret wait arguments as milliseconds and compare elapsed global-timer
ticks. Use `FW_WAIT_TIMEOUT_MS=100` at every blocking phase. Use unsigned
64-bit elapsed subtraction so normal timer wrap is safe.

### 5. 하드웨어 계약 근거

Interface v1.1 §11.4 requires separate bounded operation and ABORT-confirm
polling. §11.5 requires BUSY to be confirmed low before restart. Phase 3E-1's
100 ms requirement must therefore be measured by an elapsed-time source.

### 6. 기존 firmware 기능에 미치는 영향

Return meanings stay unchanged, but the parameter unit changes from iterations
to milliseconds. There is only one internal caller, so this is a contained API
change. The successful Stage-1 RTL run took about 14.35 ms at 100 MHz, leaving
substantial margin within 100 ms.

### 7. 테스트 방법

- Fake `XTime_GetTime()` in a host unit test and assert exact boundary behavior.
- On board, time a forced non-completing operation using a second timer/UART;
  verify approximately 100 ms before abort.
- Build-time check that `COUNTS_PER_SECOND` is supplied by the selected BSP.

### 8. proposed diff

```diff
diff --git a/firmware/src/accel_driver.c b/firmware/src/accel_driver.c
--- a/firmware/src/accel_driver.c
+++ b/firmware/src/accel_driver.c
@@
-#define ACCEL_DEFAULT_TIMEOUT 1000000U
-#define ACCEL_ABORT_CONFIRM_TIMEOUT 1000U
@@
-int accel_wait_done(uint32_t timeout)
+int accel_wait_done(uint32_t timeout_ms)
 {
-    while (timeout-- > 0U) {
+    XTime start = fw_time_now();
+    do {
         uint32_t status = accel_reg_read(ACCEL_REG_STATUS);
@@
-    }
+    } while (!fw_time_expired(start, timeout_ms));
 
     accel_abort();
-    uint32_t confirm = ACCEL_ABORT_CONFIRM_TIMEOUT;
-    while (confirm-- > 0U) {
+    start = fw_time_now();
+    do {
         uint32_t status = accel_reg_read(ACCEL_REG_STATUS);
         if ((status & STATUS_BUSY_MASK) == 0U) {
             return ACCEL_TIMEOUT;
         }
-    }
+    } while (!fw_time_expired(start, FW_WAIT_TIMEOUT_MS));
     return ACCEL_ABORT_TIMEOUT;
@@
-    rc = accel_wait_done(ACCEL_DEFAULT_TIMEOUT);
+    rc = accel_wait_done(FW_WAIT_TIMEOUT_MS);
```

## 3. DMA timeout/error 검사

### 1. 대상 파일과 함수

- `firmware/inc/dma_transfer.h`: explicit return codes and millisecond wait
  parameters.
- `firmware/src/dma_transfer.c`: common channel wait helper,
  `dma_mm2s_wait_complete()`, `dma_s2mm_wait_complete()`.
- `firmware/src/accel_driver.c`: pass 100 ms timeout and preserve DMA failures.

### 2. 현재 동작

Both DMA wait functions spin only on `XAxiDma_Busy()` and always return zero.
They neither inspect DMASR error bits nor expire.

### 3. 문제 발생 시나리오

A decode, slave, internal, or stream protocol error may halt a DMA channel.
Depending on channel state, BUSY can remain asserted forever or become false
while an error remains latched. Current code either hangs or reports success.

### 4. 제안하는 최소 수정

Poll the correct channel DMASR directly. Return `DMA_HW_ERROR` if any
`XAXIDMA_ERR_ALL_MASK` bit is set, `DMA_TIMEOUT` after 100 ms, and success only
when no error is present and Busy is false. Keep MM2S and S2MM wrappers thin.

### 5. 하드웨어 계약 근거

Interface v1.1 §3 defines polling operation; §10.3 and §11.5 require firmware
DMA recovery on fatal errors. §11.1 requires each MM2S and S2MM completion to be
confirmed, not merely attempted.

### 6. 기존 firmware 기능에 미치는 영향

Normal transfers retain their order and blocking behavior. Failure returns
become distinguishable instead of collapsing to `-1` or hanging. This proposal
does not enable interrupts or scatter-gather mode.

### 7. 테스트 방법

- Valid four transfers: expect `DMA_OK` and no DMASR error bits.
- Stub a DMASR decode/slave/internal error for each direction: expect
  `DMA_HW_ERROR` even if Busy is already false.
- Hold Busy high with clean DMASR: expect `DMA_TIMEOUT` at about 100 ms.
- Confirm no third packet is submitted after a failed Weight or Bias transfer.

### 8. proposed diff

```diff
diff --git a/firmware/inc/dma_transfer.h b/firmware/inc/dma_transfer.h
--- a/firmware/inc/dma_transfer.h
+++ b/firmware/inc/dma_transfer.h
@@
+#define DMA_OK             0
+#define DMA_INVALID_ARG  (-1)
+#define DMA_SUBMIT_ERROR (-2)
+#define DMA_HW_ERROR     (-3)
+#define DMA_TIMEOUT      (-4)
+#define DMA_RESET_ERROR  (-5)
@@
-int dma_mm2s_wait_complete(void);
+int dma_mm2s_wait_complete(uint32_t timeout_ms);
@@
-int dma_s2mm_wait_complete(void);
+int dma_s2mm_wait_complete(uint32_t timeout_ms);

diff --git a/firmware/src/dma_transfer.c b/firmware/src/dma_transfer.c
--- a/firmware/src/dma_transfer.c
+++ b/firmware/src/dma_transfer.c
@@
 #include "xil_cache.h"
+#include "platform_time.h"
+#include "xaxidma_hw.h"
@@
+static int dma_wait_channel(int direction, uint32_t timeout_ms)
+{
+    const u32 channel_offset = (direction == XAXIDMA_DMA_TO_DEVICE)
+        ? XAXIDMA_TX_OFFSET : XAXIDMA_RX_OFFSET;
+    XTime start = fw_time_now();
+
+    do {
+        u32 status = XAxiDma_ReadReg(
+            dma_instance.RegBase, channel_offset + XAXIDMA_SR_OFFSET);
+        if ((status & XAXIDMA_ERR_ALL_MASK) != 0U) {
+            return DMA_HW_ERROR;
+        }
+        if (!XAxiDma_Busy(&dma_instance, direction)) {
+            return DMA_OK;
+        }
+    } while (!fw_time_expired(start, timeout_ms));
+    return DMA_TIMEOUT;
+}
@@
-int dma_mm2s_wait_complete(void)
+int dma_mm2s_wait_complete(uint32_t timeout_ms)
 {
-    while (XAxiDma_Busy(&dma_instance, XAXIDMA_DMA_TO_DEVICE)) {
-        /* poll; v1.0 is polling-only (§3 rule 2) */
-    }
-    return 0;
+    return dma_wait_channel(XAXIDMA_DMA_TO_DEVICE, timeout_ms);
 }
@@
-int dma_s2mm_wait_complete(void)
+int dma_s2mm_wait_complete(uint32_t timeout_ms)
 {
-    while (XAxiDma_Busy(&dma_instance, XAXIDMA_DEVICE_TO_DMA)) {
-        /* poll */
-    }
-    return 0;
+    return dma_wait_channel(XAXIDMA_DEVICE_TO_DMA, timeout_ms);
 }

diff --git a/firmware/src/accel_driver.c b/firmware/src/accel_driver.c
--- a/firmware/src/accel_driver.c
+++ b/firmware/src/accel_driver.c
@@
-    if (dma_mm2s_transfer(layer->weight_addr, weight_bytes) != 0 || dma_mm2s_wait_complete() != 0) {
+    if (dma_mm2s_transfer(layer->weight_addr, weight_bytes) != DMA_OK ||
+        dma_mm2s_wait_complete(FW_WAIT_TIMEOUT_MS) != DMA_OK) {
         return ACCEL_FATAL_ERROR;
     }
@@
-    if (dma_s2mm_wait_complete() != 0) {
+    if (dma_s2mm_wait_complete(FW_WAIT_TIMEOUT_MS) != DMA_OK) {
         return ACCEL_FATAL_ERROR;
     }
```

Apply the same two-line form to Bias and Input. In implementation, retain the
exact DMA return in a local variable for UART diagnostics rather than losing it
inside a boolean expression.

## 4. Coordinated DMA reset

### 1. 대상 파일과 함수

- `firmware/inc/accel_driver.h`: `accel_abort_and_wait_idle()`.
- `firmware/src/accel_driver.c`: bounded abort helper.
- `firmware/src/dma_transfer.c`: timer-based `dma_halt_reset()`.
- `firmware/src/resnet_scheduler.c`: one failure recovery path.

### 2. 현재 동작

`accel_wait_done()` aborts only on its own timeout. Other failures return
without abort. The scheduler writes ABORT but neither confirms BUSY low nor
calls the existing `dma_halt_reset()`.

### 3. 문제 발생 시나리오

If START was accepted and Weight/Bias/Input DMA fails, the accelerator can wait
for a packet while S2MM remains armed. Returning without resetting both DMA
channels leaves stale BTT/status state and makes the next layer unsafe.

### 4. 제안하는 최소 수정

Expose one accelerator abort-and-idle-confirm helper. On every layer failure,
the scheduler first snapshots/logs status, error code, and debug state, then
calls the helper and resets both DMA channels. Do not clear sticky diagnostics
until logging is complete. If recovery fails, report it and do not run another
layer.

### 5. 하드웨어 계약 근거

Interface v1.1 §8.3 says ABORT does not reset DMA. §10.3 requires firmware to
reset active DMA after a fatal error. §11.4 requires BUSY-low confirmation, and
§11.5 requires accelerator and DMA cleanup before sticky flags are cleared and
execution restarts.

### 6. 기존 firmware 기능에 미치는 영향

There is no change on success. Failure handling becomes longer but bounded and
leaves a defined idle state. The original layer error remains the primary return
value; recovery failure is separately printed.

### 7. 테스트 방법

- Inject MM2S and S2MM errors at each packet boundary; verify ABORT if BUSY,
  BUSY-low confirmation, DMA reset completion, and no next-layer submission.
- Inject an accelerator timeout; verify that a second no-op abort is harmless
  and DMA reset still occurs.
- Hold reset-not-done or BUSY high: verify bounded recovery failure and stop.

### 8. proposed diff

```diff
diff --git a/firmware/inc/accel_driver.h b/firmware/inc/accel_driver.h
--- a/firmware/inc/accel_driver.h
+++ b/firmware/inc/accel_driver.h
@@
+int accel_abort_and_wait_idle(uint32_t timeout_ms);

diff --git a/firmware/src/accel_driver.c b/firmware/src/accel_driver.c
--- a/firmware/src/accel_driver.c
+++ b/firmware/src/accel_driver.c
@@
+int accel_abort_and_wait_idle(uint32_t timeout_ms)
+{
+    if ((accel_reg_read(ACCEL_REG_STATUS) & STATUS_BUSY_MASK) != 0U) {
+        accel_abort();
+    }
+    XTime start = fw_time_now();
+    do {
+        if ((accel_reg_read(ACCEL_REG_STATUS) & STATUS_BUSY_MASK) == 0U) {
+            return ACCEL_OK;
+        }
+    } while (!fw_time_expired(start, timeout_ms));
+    return ACCEL_ABORT_TIMEOUT;
+}

diff --git a/firmware/src/dma_transfer.c b/firmware/src/dma_transfer.c
--- a/firmware/src/dma_transfer.c
+++ b/firmware/src/dma_transfer.c
@@
 int dma_halt_reset(void)
 {
     XAxiDma_Reset(&dma_instance);
-    int timeout = 10000;
-    while (!XAxiDma_ResetIsDone(&dma_instance) && timeout-- > 0) {
-        /* poll */
-    }
-    return (timeout > 0) ? 0 : -1;
+    XTime start = fw_time_now();
+    while (!XAxiDma_ResetIsDone(&dma_instance)) {
+        if (fw_time_expired(start, FW_WAIT_TIMEOUT_MS)) {
+            return DMA_RESET_ERROR;
+        }
+    }
+    return DMA_OK;
 }

diff --git a/firmware/src/resnet_scheduler.c b/firmware/src/resnet_scheduler.c
--- a/firmware/src/resnet_scheduler.c
+++ b/firmware/src/resnet_scheduler.c
@@
 #include "accel_driver.h"
+#include "dma_transfer.h"
+#include "platform_time.h"
@@
         if (rc != ACCEL_OK) {
+            uint32_t status = accel_get_status();
+            uint32_t error_code = accel_get_error_code();
+            uint32_t debug_state = accel_get_debug_state();
             xil_printf(
                 "resnet_run: layer %u failed rc=%d status=0x%lx error_code=%lu debug_state=%lu\r\n",
-                (unsigned)i, rc,
-                (unsigned long)accel_get_status(),
-                (unsigned long)accel_get_error_code(),
-                (unsigned long)accel_get_debug_state());
-            accel_abort();
+                (unsigned)i, rc, (unsigned long)status,
+                (unsigned long)error_code, (unsigned long)debug_state);
+            int accel_recovery =
+                accel_abort_and_wait_idle(FW_WAIT_TIMEOUT_MS);
+            int dma_recovery = dma_halt_reset();
+            if (accel_recovery != ACCEL_OK || dma_recovery != DMA_OK) {
+                xil_printf("resnet_run: recovery failed accel=%d dma=%d\r\n",
+                           accel_recovery, dma_recovery);
+            }
             return rc;
         }
```

## 5. S2MM 완료 후 cache invalidate

### 1. 대상 파일과 함수

- `firmware/src/dma_transfer.c`: `dma_s2mm_prepare()` and
  `dma_s2mm_wait_complete()`.

### 2. 현재 동작

The destination range is invalidated before S2MM starts, but its address and
length are not retained and no invalidation occurs after DMA completion.

### 3. 문제 발생 시나리오

The CPU can speculatively refill a cache line while DMA is writing DDR. After
S2MM completion, the bytewise comparison may read that stale line and report a
false mismatch even though DDR contains correct output.

### 4. 제안하는 최소 수정

Record the active S2MM destination and byte count only after successful submit.
After an error-free S2MM completion, invalidate that exact range again, then
clear the saved state. Clear saved state during DMA reset as well.

### 5. 하드웨어 계약 근거

Interface v1.1 §11.1 steps 18-20 require both accelerator DONE and S2MM
completion before DDR output is read. Cache maintenance is part of making the
completed DDR write visible to the ARM CPU.

### 6. 기존 firmware 기능에 미치는 영향

No stream or DMA programming changes. The post-completion invalidation adds a
small cost and ensures the existing comparison sees DMA data.

### 7. 테스트 방법

- Pre-fill/read the output buffer to make it cache-resident before S2MM; after
  completion, verify the first CPU read matches DDR/golden data.
- Assert exactly one post-completion invalidation with the submitted address and
  length in a mocked driver test.
- On timeout/error/reset, ensure no stale saved S2MM transaction is reused.

### 8. proposed diff

```diff
diff --git a/firmware/src/dma_transfer.c b/firmware/src/dma_transfer.c
--- a/firmware/src/dma_transfer.c
+++ b/firmware/src/dma_transfer.c
@@
 static XAxiDma dma_instance;
+static uintptr_t s2mm_dst_addr;
+static uint32_t s2mm_byte_count;
+static int s2mm_active;
@@
 int dma_s2mm_prepare(uintptr_t dst_addr, uint32_t byte_count)
 {
@@
     int status = XAxiDma_SimpleTransfer(&dma_instance, (UINTPTR)dst_addr,
                                         byte_count, XAXIDMA_DEVICE_TO_DMA);
-    return (status == XST_SUCCESS) ? 0 : -1;
+    if (status != XST_SUCCESS) {
+        return DMA_SUBMIT_ERROR;
+    }
+    s2mm_dst_addr = dst_addr;
+    s2mm_byte_count = byte_count;
+    s2mm_active = 1;
+    return DMA_OK;
 }
@@
 int dma_s2mm_wait_complete(uint32_t timeout_ms)
 {
-    return dma_wait_channel(XAXIDMA_DEVICE_TO_DMA, timeout_ms);
+    int rc = dma_wait_channel(XAXIDMA_DEVICE_TO_DMA, timeout_ms);
+    if (rc == DMA_OK && s2mm_active) {
+        Xil_DCacheInvalidateRange((UINTPTR)s2mm_dst_addr, s2mm_byte_count);
+        s2mm_active = 0;
+    }
+    return rc;
 }
@@
 int dma_halt_reset(void)
 {
+    s2mm_active = 0;
     XAxiDma_Reset(&dma_instance);
```

## 6. Runtime alignment 검사

### 1. 대상 파일과 함수

- `firmware/src/dma_transfer.c`: `dma_mm2s_transfer()`,
  `dma_s2mm_prepare()`, common validator.

### 2. 현재 동작

Generated arrays and the output buffer request 4-byte alignment, but DMA
wrappers do not check address, nonzero length, or length multiple-of-four before
cache maintenance and submission.

### 3. 문제 발생 시나리오

With DRE disabled, a future layer descriptor or linker placement can pass an
unaligned pointer. The DMA submission then fails or transfers unintended data;
an invalid length may also violate the accelerator's 32-bit full-beat/TKEEP
contract.

### 4. 제안하는 최소 수정

Reject zero length, `(address & 3) != 0`, or `(byte_count & 3) != 0` before any
cache call or DMA register write. Keep compile-time `aligned(4)` attributes as
an additional guarantee.

### 5. 하드웨어 계약 근거

Interface v1.1 §6.2 requires 4-byte MM2S/S2MM addresses and packet lengths with
DRE disabled. §6.3 states all v1.0 beats use `TKEEP=4'b1111`.

### 6. 기존 firmware 기능에 미치는 영향

Current Stage-1 buffers and sizes pass unchanged. Invalid future descriptors
fail early with `DMA_INVALID_ARG` instead of reaching hardware.

### 7. 테스트 방법

- For each direction, test aligned lengths 4 and Stage-1 sizes: submission
  proceeds.
- Test address offsets +1/+2/+3, lengths 0/1/2/3/5: expect
  `DMA_INVALID_ARG` and no cache or DMA call.
- Inspect ELF map/symbol addresses for all four embedded arrays and output.

### 8. proposed diff

```diff
diff --git a/firmware/src/dma_transfer.c b/firmware/src/dma_transfer.c
--- a/firmware/src/dma_transfer.c
+++ b/firmware/src/dma_transfer.c
@@
+static int dma_buffer_is_valid(uintptr_t addr, uint32_t byte_count)
+{
+    return byte_count != 0U &&
+           (addr & 0x3U) == 0U &&
+           (byte_count & 0x3U) == 0U;
+}
@@
 int dma_mm2s_transfer(uintptr_t src_addr, uint32_t byte_count)
 {
+    if (!dma_buffer_is_valid(src_addr, byte_count)) {
+        return DMA_INVALID_ARG;
+    }
     Xil_DCacheFlushRange((UINTPTR)src_addr, byte_count);
@@
-    return (status == XST_SUCCESS) ? 0 : -1;
+    return (status == XST_SUCCESS) ? DMA_OK : DMA_SUBMIT_ERROR;
 }
@@
 int dma_s2mm_prepare(uintptr_t dst_addr, uint32_t byte_count)
 {
+    if (!dma_buffer_is_valid(dst_addr, byte_count)) {
+        return DMA_INVALID_ARG;
+    }
     Xil_DCacheInvalidateRange((UINTPTR)dst_addr, byte_count);
```

## 7. init_platform/cleanup_platform 적용

### 1. 대상 파일과 함수

- `firmware/test/stage1_conv_test.c`: `main()`.

### 2. 현재 동작

The application prints with `xil_printf()` but never calls the Vitis standalone
platform initialization or cleanup hooks. Several early returns bypass any
common shutdown path.

### 3. 문제 발생 시나리오

UART and platform services may depend on generated platform initialization.
Diagnostics can be absent or platform resources left in an undefined state,
especially when the application template/platform implementation changes.

### 4. 제안하는 최소 수정

Include `platform.h`, call `init_platform()` before the first driver/UART use,
and replace early returns with a single `out:` path that calls
`cleanup_platform()` exactly once.

### 5. 하드웨어 계약 근거

The firmware integration acceptance requires visible UART diagnostics. The XSA
contains PS7 initialization metadata, while Vitis generated platform hooks are
the application-level entry/exit contract for the standalone domain.

### 6. 기존 firmware 기능에 미치는 영향

Test logic and result code are unchanged. Initialization occurs before DMA and
accelerator access; cleanup occurs on both PASS and every failure.

### 7. 테스트 방법

- Instrument/stub hooks to prove one init and one cleanup for DMA-init failure,
  accelerator-init failure, run failure, mismatch, and PASS.
- On board, verify the earliest boot banner/diagnostics and final PASS/FAIL are
  visible on the configured UART.

### 8. proposed diff

```diff
diff --git a/firmware/test/stage1_conv_test.c b/firmware/test/stage1_conv_test.c
--- a/firmware/test/stage1_conv_test.c
+++ b/firmware/test/stage1_conv_test.c
@@
 #include "xil_printf.h"
+#include "platform.h"
@@
 int main(void)
 {
+    int exit_code = -1;
+    init_platform();
+
     int rc = dma_init();
     if (rc != 0) {
         xil_printf("stage1_conv_test: dma_init failed rc=%d\r\n", rc);
-        return -1;
+        goto out;
     }
@@
-        return -1;
+        goto out;
@@
-        return -1;
+        goto out;
@@
-    return (mismatch_count == 0) ? 0 : -1;
+    exit_code = (mismatch_count == 0) ? 0 : -1;
+out:
+    cleanup_platform();
+    return exit_code;
 }
```

## 8. xparameters.h 매크로 연결

### 1. 대상 파일과 함수

- `firmware/inc/platform_config.h`: accelerator and DMA integration symbols.
- Indirect consumers: `accel_reg_read/write()` and `dma_init()`.

### 2. 현재 동작

The header supplies numeric fallbacks `0x43C00000` and DMA device ID `0` and
does not include `xparameters.h`. These happen to match audit expectations but
do not prove the compiled application targets the generated BSP hardware.

### 3. 문제 발생 시나리오

Generated instance order or address naming can change while the placeholders
still compile. Firmware can access the wrong peripheral without a build error.

### 4. 제안하는 최소 수정

Include generated `xparameters.h`, alias only the exact macros confirmed after
platform/BSP generation, and use `#error` if either is absent. Add compile-time
address checks against the audited XSA values. Do not infer DMA device ID from
its base address.

### 5. 하드웨어 계약 근거

The audited XSA maps `resnet_accel_0` at `0x43C00000-0x43C0FFFF` and
`axi_dma_0` at `0x40400000-0x4040FFFF`; FCLK0 is 100 MHz. The generated BSP is
the authoritative source of C symbol spelling and device IDs.

### 6. 기존 firmware 기능에 미치는 영향

Runtime behavior is unchanged when the correct BSP is selected. Builds against
the wrong or incomplete platform fail early instead of using placeholders.

### 7. 테스트 방법

- Inspect generated `xparameters.h` before applying this diff and substitute the
  exact emitted names if they differ from the expected names below.
- Preprocess `platform_config.h` and record resolved values.
- Require accelerator base `0x43C00000`, DMA base `0x40400000`, DMA simple mode,
  and successful VERSION `0x00010001` read on board.

### 8. proposed diff

```diff
diff --git a/firmware/inc/platform_config.h b/firmware/inc/platform_config.h
--- a/firmware/inc/platform_config.h
+++ b/firmware/inc/platform_config.h
@@
 #define PLATFORM_CONFIG_H
+#include "xparameters.h"
 
-#ifndef ACCEL_BASE_ADDR
-#define ACCEL_BASE_ADDR 0x43C00000U /* placeholder AXI4-Lite base address */
+#ifndef XPAR_RESNET_ACCEL_0_S_AXI_CTRL_BASEADDR
+#error "BSP does not expose resnet_accel_0 AXI-Lite base"
 #endif
+#define ACCEL_BASE_ADDR XPAR_RESNET_ACCEL_0_S_AXI_CTRL_BASEADDR
 
-#ifndef ACCEL_DMA_DEVICE_ID
-#define ACCEL_DMA_DEVICE_ID 0U /* placeholder XPAR_AXIDMA_*_DEVICE_ID */
+#ifndef XPAR_AXIDMA_0_DEVICE_ID
+#error "BSP does not expose axi_dma_0 device ID"
 #endif
+#define ACCEL_DMA_DEVICE_ID XPAR_AXIDMA_0_DEVICE_ID
+
+#ifndef XPAR_AXIDMA_0_BASEADDR
+#error "BSP does not expose axi_dma_0 base address"
+#endif
+
+#if ACCEL_BASE_ADDR != 0x43C00000U
+#error "Accelerator base differs from audited XSA"
+#endif
+#if XPAR_AXIDMA_0_BASEADDR != 0x40400000U
+#error "AXI DMA base differs from audited XSA"
+#endif
```

The three `XPAR_*` names above are expected, not yet confirmed. Phase 3E-2 must
inspect the generated BSP and revise only the alias spelling if needed; the
audited numeric assertions must remain.

## 9. Canonical Stage-1 vector 연결 방식

### 1. 대상 파일과 함수

- `scripts/generate_stage1_c_header.py`: config schema adapter, provenance and
  hash checks.
- `firmware/test/generated/stage1_test_vector.h`: generated build input only.
- `firmware/test/stage1_conv_test.c`: existing generated-header include; no
  algorithmic change required.

### 2. 현재 동작

The firmware remote vector uses `M=44077`, `N=24`, omits seed, and has four
binary hashes different from the RTL regression vector. The RTL canonical
vector uses `seed=20260730`, `M=3`, `N=2` and produced a zero-mismatch RTL
regression. The header generator accepts only `multiplier_m`/`shift_n`, while
the RTL config uses `multiplier`/`shift`.

### 3. 문제 발생 시나리오

Embedding the remote vector would test a different quantization/data snapshot
from the one already proven against RTL. Pointing the current generator at the
RTL vector fails on key names. Either path can therefore produce an untraceable
or non-buildable first FPGA bit-exact test.

### 4. 제안하는 최소 수정

Do not copy or merge a vector into the firmware repository. Select one immutable
vector directory at Vitis staging time, pass it with `--vector-dir`, accept
either M/N key schema with conflict rejection, verify byte sizes and approved
SHA-256 values, and emit provenance macros/comments into the generated header.
Generate the header under the ignored Vitis/application staging area.

**Joint decision required:** no vector is selected by this proposal. The first
FPGA bit-exact run must jointly choose between the two rows below and record the
chosen directory, commit, config SHA, four binary SHAs, seed availability, M,
and N in the build log. Engineering continuity favors the RTL canonical vector
because it is the only one already demonstrated with zero RTL mismatches, but
that evidence is not authorization to replace the firmware author's vector.

| Candidate | Provenance | Seed | M | N | Current evidence |
|---|---|---:|---:|---:|---|
| Firmware remote | `origin/test-vectors/stage1-conv` at `7a326549...` | not recorded | 44077 | 24 | schema/size/layout audit only; different binaries |
| RTL canonical | `vectors/full_conv_32x32x3x16/` at hardware `cecb4b66...` | 20260730 | 3 | 2 | 16,384-byte RTL output, zero mismatch |

### 5. 하드웨어 계약 근거

Interface v1.1 §§4-7 and §14 require identical NHWC/HWIO layout, binary
packing, packet lengths, M/N requantization, and golden arithmetic across
Python, firmware, and RTL. M/N are functional inputs, not interchangeable test
metadata.

### 6. 기존 firmware 기능에 미치는 영향

The application continues consuming the same macro/array names. Only the
build-time generator becomes schema-aware and provenance-enforcing. Neither
candidate's binary contents nor M/N values are rewritten.

### 7. 테스트 방법

- Run the generator separately against each candidate in a temporary build
  directory; verify emitted M/N exactly match its config and all array lengths
  are 432/64/3,072/16,384 bytes.
- Give a config both schema variants with different values: generation must
  fail.
- Give one altered binary: approved-hash verification must fail.
- After joint selection, compare generated-header hashes/provenance with the
  build manifest, then use only that header for the first board comparison.

### 8. proposed diff

```diff
diff --git a/scripts/generate_stage1_c_header.py b/scripts/generate_stage1_c_header.py
--- a/scripts/generate_stage1_c_header.py
+++ b/scripts/generate_stage1_c_header.py
@@
 import argparse
+import hashlib
 import json
@@
+def require_alias(config: dict, old: str, new: str) -> int:
+    present = [key for key in (old, new) if key in config]
+    if len(present) != 1:
+        raise ValueError(f"expected exactly one of {old!r}, {new!r}")
+    return int(config[present[0]])
+
+def sha256(data: bytes) -> str:
+    return hashlib.sha256(data).hexdigest()
+
 def main() -> None:
@@
+    parser.add_argument(
+        "--approved-manifest", type=Path, required=True,
+        help="jointly approved config/binary SHA-256 manifest",
+    )
@@
     expected_output = (args.vector_dir / "expected_output.bin").read_bytes()
+    multiplier_m = require_alias(config, "multiplier_m", "multiplier")
+    shift_n = require_alias(config, "shift_n", "shift")
+
+    manifest = json.loads(args.approved_manifest.read_text())
+    payloads = {
+        "weight.bin": weight, "bias.bin": bias, "input.bin": input_,
+        "expected_output.bin": expected_output,
+    }
+    for name, data in payloads.items():
+        if sha256(data) != manifest["sha256"][name]:
+            raise ValueError(f"SHA-256 mismatch: {name}")
+    config_sha = sha256((args.vector_dir / "config.json").read_bytes())
+    if config_sha != manifest["sha256"]["config.json"]:
+        raise ValueError("SHA-256 mismatch: config.json")
@@
-#define STAGE1_MULTIPLIER_M  {config["multiplier_m"]}
-#define STAGE1_SHIFT_N       {config["shift_n"]}
+#define STAGE1_MULTIPLIER_M  {multiplier_m}
+#define STAGE1_SHIFT_N       {shift_n}
+#define STAGE1_VECTOR_CONFIG_SHA256 "{config_sha}"
+#define STAGE1_VECTOR_SEED {config.get("seed", "STAGE1_VECTOR_SEED_NOT_RECORDED")}
```

For a cleaner implementation, emit seed as a string macro or emit
`STAGE1_VECTOR_HAS_SEED` plus a numeric value; the schematic last line above is
intended to show provenance preservation, not to invent a seed for the remote
vector. The approved manifest itself must be created only after the joint
decision and stored with Phase 3E-2 build artifacts.

## 10. Integrated execution order after approval

The combined minimal implementation would execute one layer as follows:

1. Validate all four DMA addresses and byte counts.
2. Clear prior DONE/ERROR and program accelerator registers.
3. Invalidate output cache and arm S2MM.
4. Write START, then wait up to 100 ms for BUSY or ERROR.
5. Submit and bounded-wait Weight, Bias, and Input MM2S separately.
6. Bounded-wait accelerator DONE and then S2MM completion.
7. Invalidate the completed S2MM destination again.
8. On any failure, snapshot diagnostics, abort/confirm accelerator idle, reset
   both DMA channels, report recovery status, and stop.
9. Compare against the jointly approved generated vector and clean up platform.

## 11. Decision and implementation gates

No firmware patch or Vitis build should begin until all of these are true:

- the first bit-exact vector candidate is jointly selected and its immutable
  hashes are recorded;
- generated BSP macro names are inspected and the expected aliases confirmed;
- the BSP provides `XTime_GetTime()` and `COUNTS_PER_SECOND` for the selected
  standalone Cortex-A9 domain;
- the cumulative API/diff design is reviewed with the firmware owner;
- DMA status-mask/register macros are confirmed against the Vitis 2022.2
  `xaxidma` driver headers.

This proposal does not modify firmware source, create/switch branches, merge
test vectors, invoke Vitis, or create ELF/FSBL/BOOT.BIN artifacts.
