/* Minimal stand-in for the real Xilinx BSP header, used only for host-side -fsyntax-only checks (see VERIFICATION_GUIDE.md). Not for real Vitis builds. */
#ifndef XTIME_L_H
#define XTIME_L_H
#include <stdint.h>
typedef uint64_t XTime;
#define COUNTS_PER_SECOND 333333333U /* real value comes from the generated BSP, per-domain */
void XTime_GetTime(XTime *Xtime_Global);
#endif
