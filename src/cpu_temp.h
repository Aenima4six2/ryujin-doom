/* cpu_temp.h - platform CPU package/control temperature reader.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef CPU_TEMP_H
#define CPU_TEMP_H

/* Discover the preferred CPU package/control temperature sensor.
 * Returns 0 when a provider was started/found, -1 when unavailable.
 */
int cpu_temp_open(void);

/* Read the selected sensor in tenths of a degree Celsius.
 * Returns 0 on success, -1 when no current reading is available.
 */
int cpu_temp_read(int *temp_tenths);

void cpu_temp_close(void);

#endif /* CPU_TEMP_H */
