// doomgeneric for the ASUS ROG Ryujin III Extreme LCD
//
// Runs DOOM (doomgeneric) and streams the framebuffer to the cooler's
// 640x480 LCD.  No input: the title screen and DEMO1-3 attract loop play
// forever.
//
// SPDX-License-Identifier: GPL-3.0-or-later

#include "doomgeneric.h"
#include "cpu_temp.h"
#include "ryujin_lcd.h"
#include "st_stuff.h"

#include <limits.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#ifndef PATH_MAX
#define PATH_MAX MAX_PATH
#endif
#endif

#define TICRATE 35

static volatile sig_atomic_t stop_requested = 0;

static int opt_no_lcd = 0;
static const char *opt_dump_dir = NULL;
static int opt_fake_stats = 0;
static struct ryujin_stats fake_stats;
static int fake_cpu_temp = -1;
static unsigned long opt_exit_after = 0;

static uint8_t lcd_frame[LCD_FRAME_SIZE];
static unsigned long frames_rendered = 0;
static unsigned long frames_pushed = 0;
static int lcd_fatal = 0;
static long long next_stats_update_ns = 0;
static struct ryujin_stats current_stats;
static int current_cpu_temp = -1;

static void handle_signal(int sig)
{
	(void)sig;
	stop_requested = 1;
}

static long long monotonic_ns(void)
{
#ifdef _WIN32
	LARGE_INTEGER counter;
	LARGE_INTEGER frequency;

	QueryPerformanceCounter(&counter);
	QueryPerformanceFrequency(&frequency);
	return (long long)(counter.QuadPart * 1000000000LL / frequency.QuadPart);
#else
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec;
#endif
}

static void sleep_ns(long long ns)
{
#ifdef _WIN32
	DWORD ms = (DWORD)((ns + 999999LL) / 1000000LL);

	Sleep(ms);
#else
	struct timespec ts = { ns / 1000000000LL, ns % 1000000000LL };

	nanosleep(&ts, NULL);
#endif
}

static void update_ryujin_stats(int log_values)
{
	int cpu_temp_tenths;

	if (opt_fake_stats) {
		current_stats = fake_stats;
		current_cpu_temp = fake_cpu_temp;
	} else {
		if (!opt_no_lcd)
			lcd_read_stats(&current_stats);
		if (cpu_temp_read(&cpu_temp_tenths) == 0)
			current_cpu_temp = (cpu_temp_tenths + 5) / 10;
		else
			current_cpu_temp = -1;
	}

	ST_SetRyujinStats((current_stats.liquid_temp_tenths + 5) / 10,
			  current_stats.pump_rpm, current_stats.pump_fan_rpm,
			  current_cpu_temp);
	if (log_values) {
		fprintf(stderr,
			"ryujin-doom: liquid %d.%d C, pump %d rpm, micro fan %d rpm",
			current_stats.liquid_temp_tenths / 10,
			current_stats.liquid_temp_tenths % 10,
			current_stats.pump_rpm, current_stats.pump_fan_rpm);
		if (current_cpu_temp >= 0)
			fprintf(stderr, ", CPU package %d C", current_cpu_temp);
		fprintf(stderr, "\n");
	}
}

void DG_Init(void)
{
	if (!opt_fake_stats)
		cpu_temp_open();
	if (!opt_no_lcd) {
		fprintf(stderr, "ryujin-doom: initializing LCD\n");
		if (lcd_open() < 0) {
			fprintf(stderr, "ryujin-doom: cannot open the LCD (use --no-lcd to run without it)\n");
			cpu_temp_close();
			lcd_close();
			exit(1);
		}
	}
	update_ryujin_stats(opt_no_lcd ? 0 : 1);
	next_stats_update_ns = monotonic_ns() + 1000000000LL;
}

void DG_DrawFrame(void)
{
	int x, y;
	long long now = monotonic_ns();

	if (now >= next_stats_update_ns) {
		update_ryujin_stats(0);
		next_stats_update_ns = now + 1000000000LL;
	}

	// DG_ScreenBuffer is 640x400 rgba8888 (R at bits 16-23, G at 8-15,
	// B at 0-7).  Map each LCD row to a source row (400 -> 480 lines,
	// duplicating every 5th) and unpack to RGB888.  The LCD transport
	// converts this to the panel's native BGR888 byte order.
	for (y = 0; y < LCD_HEIGHT; y++) {
		int src_y = y * DOOMGENERIC_RESY / LCD_HEIGHT;
		const pixel_t *row = DG_ScreenBuffer + src_y * DOOMGENERIC_RESX;
		uint8_t *out = lcd_frame + y * LCD_WIDTH * 3;

		for (x = 0; x < LCD_WIDTH; x++) {
			uint32_t p = row[x];

			*out++ = (p >> 16) & 0xFF;
			*out++ = (p >> 8) & 0xFF;
			*out++ = p & 0xFF;
		}
	}

	frames_rendered++;

	if (opt_exit_after && frames_rendered >= opt_exit_after)
		stop_requested = 1;

	if (!opt_no_lcd && !lcd_fatal) {
		if (lcd_push_frame(lcd_frame) < 0) {
			fprintf(stderr, "ryujin-doom: LCD frame push failed, giving up on the LCD\n");
			lcd_fatal = 1;
			return;
		}
		frames_pushed++;
	}

	if (opt_dump_dir) {
		char path[PATH_MAX];
		FILE *f;

		snprintf(path, sizeof(path), "%s/frame_%06lu.ppm", opt_dump_dir,
			 frames_rendered);
		f = fopen(path, "wb");
		if (f) {
			fprintf(f, "P6\n%d %d\n255\n", LCD_WIDTH, LCD_HEIGHT);
			fwrite(lcd_frame, 1, LCD_FRAME_SIZE, f);
			fclose(f);
		} else {
			fprintf(stderr, "ryujin-doom: cannot write %s\n", path);
		}
	}
}

void DG_SleepMs(uint32_t ms)
{
	sleep_ns((long long)ms * 1000000LL);
}

uint32_t DG_GetTicksMs(void)
{
	return (uint32_t)(monotonic_ns() / 1000000LL);
}

int DG_GetKey(int *pressed, unsigned char *key)
{
	(void)pressed;
	(void)key;
	return 0;
}

void DG_SetWindowTitle(const char *title)
{
	(void)title;
}

static void parse_args(int argc, char **argv)
{
	int i;

	for (i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--no-lcd") == 0) {
			opt_no_lcd = 1;
		} else if (strcmp(argv[i], "--dump-frames") == 0 && i + 1 < argc) {
			opt_dump_dir = argv[++i];
		} else if (strcmp(argv[i], "--fake-stats") == 0 && i + 1 < argc) {
			int liquid, pump, fan, cpu;
			int parsed;

			parsed = sscanf(argv[++i], "%d,%d,%d,%d", &liquid, &pump,
					&fan, &cpu);
			if (parsed >= 3) {
				opt_fake_stats = 1;
				fake_stats.liquid_temp_tenths = liquid * 10;
				fake_stats.pump_rpm = pump;
				fake_stats.pump_fan_rpm = fan;
				fake_cpu_temp = parsed == 4 ? cpu : -1;
			}
		} else if (strcmp(argv[i], "--exit-after") == 0 && i + 1 < argc) {
			opt_exit_after = strtoul(argv[++i], NULL, 10);
		}
	}
}

int main(int argc, char **argv)
{
#ifndef _WIN32
	struct sigaction sa;
#endif
	const long long tic_ns = 1000000000LL / TICRATE;
	long long deadline;
	unsigned long last_logged = 0;

#ifdef _WIN32
	signal(SIGINT, handle_signal);
	signal(SIGTERM, handle_signal);
#else
	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = handle_signal;
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGTERM, &sa, NULL);
#endif

	parse_args(argc, argv);

	// doomgeneric_Create runs D_DoomMain, which runs one tick and returns.
	doomgeneric_Create(argc, argv);

	fprintf(stderr, "ryujin-doom: running (%s)\n",
		opt_no_lcd ? "LCD disabled" : "streaming to LCD");

	deadline = monotonic_ns();
	while (!stop_requested && !lcd_fatal) {
		long long now, remaining;

		deadline += tic_ns;
		doomgeneric_Tick();

		if (frames_rendered >= last_logged + TICRATE) {
			last_logged = frames_rendered;
			fprintf(stderr, "ryujin-doom: %lu frames rendered, %lu pushed\n",
				frames_rendered, frames_pushed);
		}

		now = monotonic_ns();
		remaining = deadline - now;
		if (remaining > 0) {
			sleep_ns(remaining);
		} else {
			deadline = now;	// fell behind; re-arm pacing
		}
	}

	cpu_temp_close();
	lcd_close();
	fprintf(stderr, "ryujin-doom: %s, %lu frames pushed\n",
		lcd_fatal ? "LCD error" : "stopping", frames_pushed);
	return lcd_fatal ? 1 : 0;
}
