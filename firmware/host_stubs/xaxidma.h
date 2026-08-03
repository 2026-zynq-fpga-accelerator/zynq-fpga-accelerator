/* Minimal stand-in for the real Xilinx BSP header, used only for host-side -fsyntax-only checks (see VERIFICATION_GUIDE.md). Not for real Vitis builds. */
#ifndef XAXIDMA_H
#define XAXIDMA_H
#include <stdint.h>
#include "xil_io.h"

#define XST_SUCCESS 0
#define XAXIDMA_IRQ_ALL_MASK 0xFFU
#define XAXIDMA_DMA_TO_DEVICE 0
#define XAXIDMA_DEVICE_TO_DMA 1

typedef struct {
    UINTPTR RegBase;
    int HasSg;
    int HasMm2S;
    int HasMm2SDRE;
    int HasS2Mm;
    int HasS2MmDRE;
} XAxiDma;
typedef struct { int dummy; } XAxiDma_Config;
typedef int XAxiDma_Bd;

XAxiDma_Config *XAxiDma_LookupConfig(uint32_t DeviceId);
int XAxiDma_CfgInitialize(XAxiDma *InstancePtr, XAxiDma_Config *CfgPtr);
int XAxiDma_HasSg(XAxiDma *InstancePtr);
void XAxiDma_IntrDisable(XAxiDma *InstancePtr, uint32_t Mask, int Direction);
int XAxiDma_SimpleTransfer(XAxiDma *InstancePtr, UINTPTR BuffAddr, uint32_t Length, int Direction);
int XAxiDma_Busy(XAxiDma *InstancePtr, int Direction);
void XAxiDma_Reset(XAxiDma *InstancePtr);
int XAxiDma_ResetIsDone(XAxiDma *InstancePtr);
#endif
