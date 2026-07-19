/* ryujin_lcd.c - transport layer for the ASUS ROG Ryujin III Extreme LCD.
 *
 * The cooler control interface is HID (65-byte reports prefixed with 0xEC),
 * the LCD pixel data goes to a separate bulk OUT endpoint (0x02).  Callers
 * provide RGB888 frames; the panel's native byte order is BGR888.
 *
 * Protocol derived from liquidctl's asus_ryujin driver
 * (liquidctl/driver/asus_ryujin.py) and the protocol documentation
 * (docs/developer/protocol/asus_ryujin.md).
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "ryujin_lcd.h"

#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <hidapi.h>
#else
#include <dirent.h>
#include <fcntl.h>
#include <poll.h>
#include <unistd.h>
#endif

#include <libusb.h>

#define REPORT_LENGTH 65
#define REPORT_PREFIX 0xEC

#define LCD_RAW_FRAMEBUFFER_MODE 0x20
#define LCD_BULK_OUT_ENDPOINT 0x02
#define LCD_TRANSFER_TIMEOUT_MS 10000

#define HID_READ_TIMEOUT_MS 500
#define HID_READ_RETRIES 4

#ifdef _WIN32
static hid_device *hid_handle = NULL;
#else
static int hid_fd = -1;
#endif
static libusb_context *usb_ctx = NULL;
static libusb_device_handle *usb_handle = NULL;
static int usb_interface = -1;
static int kernel_driver_detached = 0;
static uint8_t native_frame[LCD_FRAME_SIZE];

/* Write one report: leading 0x00 report-ID byte (hidraw convention for
 * unnumbered reports), then the 65-byte report (prefix, payload, zero pad).
 */
static int hid_write_report(const uint8_t *payload, size_t len)
{
	uint8_t buf[1 + REPORT_LENGTH];
#ifdef _WIN32
	int written;
#else
	ssize_t written;
#endif

	if (len > REPORT_LENGTH - 1)
		len = REPORT_LENGTH - 1;

	memset(buf, 0, sizeof(buf));
	buf[0] = 0x00;			/* report ID */
	buf[1] = REPORT_PREFIX;
	memcpy(&buf[2], payload, len);


#ifdef _WIN32
	written = hid_write(hid_handle, buf, sizeof(buf));
#else
	written = write(hid_fd, buf, sizeof(buf));
#endif
	if (written < 0 || (size_t)written != sizeof(buf)) {
		fprintf(stderr, "ryujin: hid write failed: %s\n",
#ifdef _WIN32
			written < 0 ? "HIDAPI error" : "short write");
#else
			written < 0 ? strerror(errno) : "short write");
#endif
		return -1;
	}
	return 0;
}

/* Drop any stale input reports. */
static void hid_drain(void)
{
	uint8_t tmp[REPORT_LENGTH];
#ifdef _WIN32

	hid_set_nonblocking(hid_handle, 1);
	while (hid_read(hid_handle, tmp, sizeof(tmp)) > 0)
		;
	hid_set_nonblocking(hid_handle, 0);
#else
	int flags = fcntl(hid_fd, F_GETFL, 0);

	fcntl(hid_fd, F_SETFL, flags | O_NONBLOCK);
	while (read(hid_fd, tmp, sizeof(tmp)) > 0)
		;
	fcntl(hid_fd, F_SETFL, flags);
#endif
}

/* Read reports until one with the expected prefix and header arrives. */
static int hid_read_report(uint8_t expected_header, uint8_t *out)
{
	int attempt;

	for (attempt = 0; attempt < HID_READ_RETRIES; attempt++) {
#ifdef _WIN32
		int n = hid_read_timeout(hid_handle, out, REPORT_LENGTH,
					 HID_READ_TIMEOUT_MS);
#else
		struct pollfd pfd = { hid_fd, POLLIN, 0 };
		ssize_t n;

		if (poll(&pfd, 1, HID_READ_TIMEOUT_MS) <= 0)
			continue;
		n = read(hid_fd, out, REPORT_LENGTH);
#endif
		if (n < 2)
			continue;
		if (out[0] != REPORT_PREFIX || out[1] != expected_header)
			continue;
		return 0;
	}
	return -1;
}

static int hid_request(uint8_t request_header, uint8_t response_header,
		       uint8_t *out)
{
	hid_drain();
	if (hid_write_report(&request_header, 1) < 0)
		return -1;
	return hid_read_report(response_header, out);
}

/* Scan /sys/class/hidraw for the cooler's HID node and validate each
 * candidate with a firmware query (EC 82 -> EC 02).  First responsive
 * node wins.
 */
#ifdef _WIN32
static int hid_open_validated(void)
{
	struct hid_device_info *devices;
	struct hid_device_info *candidate;
	uint8_t reply[REPORT_LENGTH];

	if (hid_init() < 0) {
		fprintf(stderr, "ryujin: hidapi initialization failed\n");
		return -1;
	}
	devices = hid_enumerate(LCD_VID, LCD_PID);
	for (candidate = devices; candidate; candidate = candidate->next) {
		hid_handle = hid_open_path(candidate->path);
		if (!hid_handle)
			continue;
		if (hid_request(0x82, 0x02, reply) == 0) {
			char fw[16];

			memcpy(fw, &reply[4], 15);
			fw[15] = '\0';
			fprintf(stderr, "ryujin: HID interface: firmware %s\n", fw);
			hid_free_enumeration(devices);
			return 0;
		}
		hid_close(hid_handle);
		hid_handle = NULL;
	}
	hid_free_enumeration(devices);
	fprintf(stderr,
		"ryujin: no responsive HID interface for %04X:%04X\n",
		LCD_VID, LCD_PID);
	return -1;
}
#else
static int hid_open_validated(void)
{
	const char *sysdir = "/sys/class/hidraw";
	uint8_t reply[REPORT_LENGTH];
	struct dirent *de;
	DIR *dir;
	int found = 0;

	dir = opendir(sysdir);
	if (!dir) {
		fprintf(stderr, "ryujin: cannot open %s: %s\n", sysdir,
			strerror(errno));
		return -1;
	}

	while ((de = readdir(dir)) != NULL) {
		char path[PATH_MAX];
		char line[256];
		int match = 0;
		FILE *f;
		int fd;

		if (strncmp(de->d_name, "hidraw", 6) != 0)
			continue;

		snprintf(path, sizeof(path), "%s/%s/device/uevent", sysdir,
			 de->d_name);
		f = fopen(path, "r");
		if (!f)
			continue;
		while (fgets(line, sizeof(line), f)) {
			if (strncmp(line, "HID_ID=", 7) == 0 &&
			    strstr(line, "0B05:00001BCB")) {
				match = 1;
				break;
			}
		}
		fclose(f);
		if (!match)
			continue;

		found = 1;
		snprintf(path, sizeof(path), "/dev/%s", de->d_name);
		fd = open(path, O_RDWR);
		if (fd < 0) {
			fprintf(stderr, "ryujin: %s: %s (check permissions)\n",
				path, strerror(errno));
			continue;
		}

		hid_fd = fd;
		if (hid_request(0x82, 0x02, reply) == 0) {
			char fw[16];

			memcpy(fw, &reply[4], 15);
			fw[15] = '\0';
			fprintf(stderr, "ryujin: %s: firmware %s\n", path, fw);
			closedir(dir);
			return 0;
		}

		fprintf(stderr, "ryujin: %s: no valid firmware reply\n", path);
		close(fd);
		hid_fd = -1;
	}

	closedir(dir);
	if (!found)
		fprintf(stderr,
			"ryujin: ROG RYUJIN III EXTREME (%04X:%04X) not found; is the cooler plugged in?\n",
			LCD_VID, LCD_PID);
	return -1;
}
#endif

/* Open the USB device, find the interface/altsetting carrying bulk OUT
 * endpoint 0x02 and claim it.
 */
static int bulk_open(void)
{
	struct libusb_config_descriptor *cfg;
	libusb_device *dev;
	int alt = -1;
	int r;
	unsigned int i, j, k;

	r = libusb_init(&usb_ctx);
	if (r < 0) {
		fprintf(stderr, "ryujin: libusb_init: %s\n",
			libusb_error_name(r));
		return -1;
	}

	usb_handle = libusb_open_device_with_vid_pid(usb_ctx, LCD_VID, LCD_PID);
	if (!usb_handle) {
		fprintf(stderr, "ryujin: cannot open USB device %04X:%04X\n",
			LCD_VID, LCD_PID);
		return -1;
	}
	dev = libusb_get_device(usb_handle);

	r = libusb_get_active_config_descriptor(dev, &cfg);
	if (r < 0) {
		fprintf(stderr, "ryujin: no active USB configuration: %s\n",
			libusb_error_name(r));
		return -1;
	}

	for (i = 0; i < cfg->bNumInterfaces && usb_interface < 0; i++) {
		const struct libusb_interface *iface = &cfg->interface[i];

		for (j = 0; j < iface->num_altsetting && usb_interface < 0; j++) {
			const struct libusb_interface_descriptor *id =
				&iface->altsetting[j];

			for (k = 0; k < id->bNumEndpoints; k++) {
				const struct libusb_endpoint_descriptor *ep =
					&id->endpoint[k];

				if (ep->bEndpointAddress == LCD_BULK_OUT_ENDPOINT &&
				    (ep->bmAttributes & 0x03) == LIBUSB_TRANSFER_TYPE_BULK) {
					usb_interface = id->bInterfaceNumber;
					alt = id->bAlternateSetting;
					break;
				}
			}
		}
	}
	libusb_free_config_descriptor(cfg);

	if (usb_interface < 0) {
		fprintf(stderr, "ryujin: bulk OUT endpoint 0x%02X not found\n",
			LCD_BULK_OUT_ENDPOINT);
		return -1;
	}

#ifndef _WIN32
	r = libusb_kernel_driver_active(usb_handle, usb_interface);
	if (r == 1) {
		r = libusb_detach_kernel_driver(usb_handle, usb_interface);
		if (r < 0) {
			fprintf(stderr, "ryujin: cannot detach kernel driver: %s\n",
				libusb_error_name(r));
			return -1;
		}
		kernel_driver_detached = 1;
	}
#endif

	r = libusb_claim_interface(usb_handle, usb_interface);
	if (r < 0) {
		fprintf(stderr, "ryujin: cannot claim interface %d: %s\n",
			usb_interface, libusb_error_name(r));
#ifdef _WIN32
		if (r == LIBUSB_ERROR_NOT_SUPPORTED) {
			fprintf(stderr,
				"ryujin: the LCD bulk interface needs a WinUSB-compatible driver;\n"
				"ryujin: configure only that interface with Zadig, not the HID interface\n");
		}
#endif
		return -1;
	}

	if (alt > 0) {
		r = libusb_set_interface_alt_setting(usb_handle, usb_interface, alt);
		if (r < 0) {
			fprintf(stderr, "ryujin: cannot set altsetting %d: %s\n",
				alt, libusb_error_name(r));
			return -1;
		}
	}

	return 0;
}

static void sleep_ms(long ms)
{
#ifdef _WIN32
	Sleep((DWORD)ms);
#else
	struct timespec ts = { ms / 1000, (ms % 1000) * 1000000L };

	nanosleep(&ts, NULL);
#endif
}

/* Query LCD state (EC D0 -> EC 50) and reapply raw framebuffer mode
 * (EC 51 20 <reply[6]> <reply[7]>).  The mode is reapplied even when it
 * is already selected, to reset display state left by an earlier
 * raw-frame session.
 */
static int lcd_set_raw_framebuffer_mode(void)
{
	uint8_t reply[REPORT_LENGTH];
	uint8_t cmd[4];

	if (hid_request(0xD0, 0x50, reply) < 0) {
		fprintf(stderr, "ryujin: LCD state query failed\n");
		return -1;
	}

	sleep_ms(100);

	cmd[0] = 0x51;
	cmd[1] = LCD_RAW_FRAMEBUFFER_MODE;
	cmd[2] = reply[6];
	cmd[3] = reply[7];
	if (hid_write_report(cmd, sizeof(cmd)) < 0)
		return -1;

	sleep_ms(100);
	return 0;
}

int lcd_open(void)
{
	if (hid_open_validated() < 0) {
#ifdef _WIN32
		fprintf(stderr,
			"ryujin: no usable HID interface; check that the cooler is connected\n");
#else
		fprintf(stderr,
			"ryujin: no usable hidraw node; check that the cooler is connected\n"
			"ryujin: and that you may access /dev/hidrawN (liquidctl's udev\n"
			"ryujin: rules grant uaccess to the logged-in user)\n");
#endif
		return -1;
	}
	if (bulk_open() < 0) {
		lcd_close();
		return -1;
	}
	if (lcd_set_raw_framebuffer_mode() < 0) {
		lcd_close();
		return -1;
	}
	fprintf(stderr, "ryujin: LCD ready (bulk interface %d)\n", usb_interface);
	return 0;
}

int lcd_push_frame(const uint8_t *rgb888)
{
	uint8_t cmd[6];
	size_t i;
	int transferred = 0;
	int r;

#ifdef _WIN32
	if (!hid_handle || !usb_handle)
#else
	if (hid_fd < 0 || !usb_handle)
#endif
		return -1;

	cmd[0] = 0x7F;
	cmd[1] = 0x03;
	cmd[2] = LCD_FRAME_SIZE & 0xFF;
	cmd[3] = (LCD_FRAME_SIZE >> 8) & 0xFF;
	cmd[4] = (LCD_FRAME_SIZE >> 16) & 0xFF;
	cmd[5] = (LCD_FRAME_SIZE >> 24) & 0xFF;
	if (hid_write_report(cmd, sizeof(cmd)) < 0)
		return -1;

	/* The USB framebuffer is packed BGR888, despite initially appearing to
	 * be RGB888.  Keep the public interface conventional RGB888 so callers
	 * and diagnostic PPM dumps use their expected channel order.
	 */
	for (i = 0; i < LCD_FRAME_SIZE; i += 3) {
		native_frame[i] = rgb888[i + 2];
		native_frame[i + 1] = rgb888[i + 1];
		native_frame[i + 2] = rgb888[i];
	}

	r = libusb_bulk_transfer(usb_handle, LCD_BULK_OUT_ENDPOINT,
				 native_frame, LCD_FRAME_SIZE, &transferred,
				 LCD_TRANSFER_TIMEOUT_MS);
	if (r < 0 || transferred != LCD_FRAME_SIZE) {
		fprintf(stderr, "ryujin: bulk write failed: %s (%d of %d bytes)\n",
			r < 0 ? libusb_error_name(r) : "short write",
			transferred, LCD_FRAME_SIZE);
		return -1;
	}
	return 0;
}

int lcd_read_stats(struct ryujin_stats *stats)
{
	uint8_t reply[REPORT_LENGTH];

#ifdef _WIN32
	if (!hid_handle || !stats)
#else
	if (hid_fd < 0 || !stats)
#endif
		return -1;
	if (hid_request(0x99, 0x19, reply) < 0) {
		fprintf(stderr, "ryujin: cooler status query failed\n");
		return -1;
	}

	/* Ryujin III Extreme offsets from liquidctl's AsusRyujin device
	 * configuration: temp=5, pump=7, embedded fan=10.
	 */
	stats->liquid_temp_tenths = reply[5] * 10 + reply[6];
	stats->pump_rpm = reply[7] | (reply[8] << 8);
	stats->pump_fan_rpm = reply[10] | (reply[11] << 8);
	return 0;
}

void lcd_close(void)
{
	if (usb_handle) {
		if (usb_interface >= 0) {
			libusb_release_interface(usb_handle, usb_interface);
			if (kernel_driver_detached)
				libusb_attach_kernel_driver(usb_handle, usb_interface);
		}
		libusb_close(usb_handle);
		usb_handle = NULL;
	}
	if (usb_ctx) {
		libusb_exit(usb_ctx);
		usb_ctx = NULL;
	}
#ifdef _WIN32
	if (hid_handle) {
		hid_close(hid_handle);
		hid_handle = NULL;
	}
	hid_exit();
#else
	if (hid_fd >= 0) {
		close(hid_fd);
		hid_fd = -1;
	}
#endif
	usb_interface = -1;
	kernel_driver_detached = 0;
}
