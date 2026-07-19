/* ryujin_lcd.h - transport layer for the ASUS ROG Ryujin III Extreme LCD.
 *
 * Protocol derived from liquidctl's asus_ryujin driver
 * (liquidctl/driver/asus_ryujin.py) and the protocol documentation
 * (docs/developer/protocol/asus_ryujin.md).
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef RYUJIN_LCD_H
#define RYUJIN_LCD_H

#include <stdint.h>

#define LCD_VID 0x0B05
#define LCD_PID 0x1BCB

#define LCD_WIDTH  640
#define LCD_HEIGHT 480
#define LCD_FRAME_SIZE (LCD_WIDTH * LCD_HEIGHT * 3)	/* packed RGB888 */

struct ryujin_stats {
	int liquid_temp_tenths;
	int pump_rpm;
	int pump_fan_rpm;
};

/* Find the cooler, open its HID control node and bulk OUT endpoint,
 * validate it with a firmware query and switch the display into raw
 * framebuffer mode.
 *
 * Returns 0 on success, -1 on failure (message printed to stderr).
 */
int lcd_open(void);

/* Upload one 640x480 packed RGB888 frame (LCD_FRAME_SIZE bytes,
 * top-to-bottom, left-to-right) to the display.
 *
 * Returns 0 on success, -1 on failure.
 */
int lcd_push_frame(const uint8_t *rgb888);

/* Read the same live cooler telemetry exposed by liquidctl's
 * AsusRyujin.get_status(): liquid temperature, pump speed and embedded
 * micro-fan speed.
 */
int lcd_read_stats(struct ryujin_stats *stats);

/* Release the bulk interface, reattach the kernel driver and close all
 * handles.  Safe to call when not (fully) opened.
 */
void lcd_close(void);

#endif /* RYUJIN_LCD_H */
