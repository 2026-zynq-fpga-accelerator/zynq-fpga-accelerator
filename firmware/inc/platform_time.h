/* Millisecond wait-timeout helper built on the standalone BSP global timer (project doc §7,
 * HW_SW_Interface_v1.1 §11.4-§11.5: every blocking phase must be bounded by elapsed wall-clock
 * time, not a loop-iteration count). */
#ifndef PLATFORM_TIME_H
#define PLATFORM_TIME_H

#include <stdint.h>
#include "xtime_l.h"

#define FW_WAIT_TIMEOUT_MS 100U

static inline XTime fw_time_now(void)
{
    XTime now;
    XTime_GetTime(&now);
    return now;
}

static inline int fw_time_expired(XTime start, uint32_t timeout_ms)
{
    const uint64_t ticks =
        ((uint64_t)COUNTS_PER_SECOND * (uint64_t)timeout_ms) / 1000U;
    return ((uint64_t)(fw_time_now() - start) >= ticks);
}

#endif /* PLATFORM_TIME_H */
