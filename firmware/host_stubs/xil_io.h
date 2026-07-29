/* Minimal stand-in for the real Xilinx BSP header, used only for host-side -fsyntax-only checks (see VERIFICATION_GUIDE.md). Not for real Vitis builds. */
#ifndef XIL_IO_H
#define XIL_IO_H
#include <stdint.h>
typedef uintptr_t UINTPTR;
uint32_t Xil_In32(UINTPTR Addr);
void Xil_Out32(UINTPTR Addr, uint32_t Value);
#endif
