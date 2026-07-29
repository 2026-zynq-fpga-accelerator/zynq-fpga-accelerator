/* Minimal stand-in for the real Xilinx BSP header, used only for host-side -fsyntax-only checks (see VERIFICATION_GUIDE.md). Not for real Vitis builds. */
#ifndef XIL_PRINTF_H
#define XIL_PRINTF_H
int xil_printf(const char *ctrl1, ...);
#endif
