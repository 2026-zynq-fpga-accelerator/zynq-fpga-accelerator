/* Minimal stand-in for the real Xilinx BSP header, used only for host-side -fsyntax-only checks (see VERIFICATION_GUIDE.md). Not for real Vitis builds. */
#ifndef XIL_CACHE_H
#define XIL_CACHE_H
#include <stdint.h>
#include "xil_io.h"
void Xil_DCacheFlushRange(UINTPTR addr, uint32_t len);
void Xil_DCacheInvalidateRange(UINTPTR addr, uint32_t len);
#endif
