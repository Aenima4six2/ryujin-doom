/* cpu_temp.c - platform CPU package/control temperature reader.
 *
 * Linux uses the kernel hwmon drivers: AMD k10temp/zenpower Tdie when
 * available (otherwise Tctl), and Intel coretemp Package id 0.
 * Windows starts the bundled LibreHardwareMonitor PowerShell adapter and
 * reads its persistent stdout stream without blocking the render loop.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "cpu_temp.h"

#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wchar.h>

static HANDLE helper_process;
static HANDLE helper_stdout;
static char helper_buffer[256];
static size_t helper_buffer_len;
static int last_temp_tenths = -1;

static int build_helper_paths(wchar_t *directory, size_t directory_len,
			      wchar_t *script, size_t script_len)
{
	wchar_t executable[MAX_PATH];
	wchar_t *slash;

	if (!GetModuleFileNameW(NULL, executable, MAX_PATH))
		return -1;
	slash = wcsrchr(executable, L'\\');
	if (!slash)
		return -1;
	*slash = L'\0';

	if (swprintf(directory, directory_len, L"%ls\\hardware-monitor",
		      executable) < 0 ||
	    swprintf(script, script_len, L"%ls\\cpu-temp.ps1", directory) < 0)
		return -1;
	return 0;
}

int cpu_temp_open(void)
{
	SECURITY_ATTRIBUTES security = { sizeof(security), NULL, TRUE };
	STARTUPINFOW startup;
	PROCESS_INFORMATION process;
	wchar_t system_dir[MAX_PATH];
	wchar_t provider_dir[MAX_PATH];
	wchar_t script[MAX_PATH];
	wchar_t command[3 * MAX_PATH];
	HANDLE pipe_write = NULL;

	if (build_helper_paths(provider_dir, MAX_PATH, script, MAX_PATH) < 0 ||
	    !GetSystemDirectoryW(system_dir, MAX_PATH)) {
		fprintf(stderr, "ryujin-doom: cannot locate CPU temperature provider\n");
		return -1;
	}
	if (GetFileAttributesW(script) == INVALID_FILE_ATTRIBUTES) {
		fprintf(stderr,
			"ryujin-doom: bundled CPU temperature provider is missing\n");
		return -1;
	}
	if (!CreatePipe(&helper_stdout, &pipe_write, &security, 0) ||
	    !SetHandleInformation(helper_stdout, HANDLE_FLAG_INHERIT, 0)) {
		fprintf(stderr, "ryujin-doom: cannot create CPU provider pipe\n");
		if (helper_stdout)
			CloseHandle(helper_stdout);
		if (pipe_write)
			CloseHandle(pipe_write);
		helper_stdout = NULL;
		return -1;
	}

	memset(&startup, 0, sizeof(startup));
	startup.cb = sizeof(startup);
	startup.dwFlags = STARTF_USESTDHANDLES;
	startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
	startup.hStdOutput = pipe_write;
	startup.hStdError = GetStdHandle(STD_ERROR_HANDLE);
	memset(&process, 0, sizeof(process));

	if (swprintf(command, sizeof(command) / sizeof(command[0]),
		      L"\"%ls\\WindowsPowerShell\\v1.0\\powershell.exe\" "
		      L"-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass "
		      L"-File \"%ls\"", system_dir, script) < 0 ||
	    !CreateProcessW(NULL, command, NULL, NULL, TRUE, CREATE_NO_WINDOW,
			    NULL, provider_dir, &startup, &process)) {
		fprintf(stderr,
			"ryujin-doom: cannot start CPU temperature provider (%lu)\n",
			(unsigned long)GetLastError());
		CloseHandle(pipe_write);
		CloseHandle(helper_stdout);
		helper_stdout = NULL;
		return -1;
	}

	CloseHandle(pipe_write);
	CloseHandle(process.hThread);
	helper_process = process.hProcess;
	fprintf(stderr, "ryujin-doom: CPU temperature provider: LibreHardwareMonitor\n");
	return 0;
}

static void parse_helper_output(const char *data, size_t len)
{
	size_t i;

	for (i = 0; i < len; i++) {
		char ch = data[i];

		if (ch == '\r')
			continue;
		if (ch == '\n') {
			char *end;
			long value;

			helper_buffer[helper_buffer_len] = '\0';
			errno = 0;
			value = strtol(helper_buffer, &end, 10);
			if (!errno && end != helper_buffer && *end == '\0' &&
			    value >= 0 && value <= 1500)
				last_temp_tenths = (int)value;
			helper_buffer_len = 0;
			continue;
		}
		if (helper_buffer_len + 1 < sizeof(helper_buffer))
			helper_buffer[helper_buffer_len++] = ch;
	}
}

int cpu_temp_read(int *temp_tenths)
{
	char data[128];
	DWORD available;
	DWORD exit_code;

	if (!helper_stdout || !temp_tenths)
		return -1;
	if (helper_process && GetExitCodeProcess(helper_process, &exit_code) &&
	    exit_code != STILL_ACTIVE) {
		last_temp_tenths = -1;
		return -1;
	}
	while (PeekNamedPipe(helper_stdout, NULL, 0, NULL, &available, NULL) &&
	       available) {
		DWORD read_count;
		DWORD wanted = available < sizeof(data) ? available : sizeof(data);

		if (!ReadFile(helper_stdout, data, wanted, &read_count, NULL) ||
		    !read_count)
			break;
		parse_helper_output(data, read_count);
	}
	if (last_temp_tenths < 0)
		return -1;
	*temp_tenths = last_temp_tenths;
	return 0;
}

void cpu_temp_close(void)
{
	if (helper_stdout) {
		CloseHandle(helper_stdout);
		helper_stdout = NULL;
	}
	if (helper_process) {
		if (WaitForSingleObject(helper_process, 1500) == WAIT_TIMEOUT)
			TerminateProcess(helper_process, 0);
		CloseHandle(helper_process);
		helper_process = NULL;
	}
}

#else

#include <dirent.h>

static char sensor_input[PATH_MAX];
static char sensor_description[128];

static int read_line(const char *path, char *buffer, size_t size)
{
	FILE *file;
	size_t len;

	file = fopen(path, "r");
	if (!file)
		return -1;
	if (!fgets(buffer, size, file)) {
		fclose(file);
		return -1;
	}
	fclose(file);
	len = strlen(buffer);
	while (len && (buffer[len - 1] == '\n' || buffer[len - 1] == '\r'))
		buffer[--len] = '\0';
	return 0;
}

static int sensor_score(const char *driver, const char *label)
{
	if (strcmp(driver, "k10temp") == 0 || strcmp(driver, "zenpower") == 0) {
		if (strcmp(label, "Tdie") == 0)
			return 400;
		if (strcmp(label, "Tctl") == 0)
			return 350;
	}
	if (strcmp(driver, "coretemp") == 0) {
		if (strcmp(label, "Package id 0") == 0)
			return 400;
		if (strncmp(label, "Package id ", 11) == 0)
			return 350;
	}
	if (strcmp(label, "CPU Package") == 0)
		return 200;
	return 0;
}

int cpu_temp_open(void)
{
	const char *root = getenv("RYUJIN_DOOM_HWMON_ROOT");
	struct dirent *entry;
	DIR *directory;
	int best_score = 0;

	if (!root || !*root)
		root = "/sys/class/hwmon";
	directory = opendir(root);
	if (!directory) {
		fprintf(stderr, "ryujin-doom: cannot inspect CPU sensors at %s: %s\n",
			root, strerror(errno));
		return -1;
	}

	while ((entry = readdir(directory)) != NULL) {
		char driver_path[PATH_MAX];
		char driver[64];
		int index;

		if (strncmp(entry->d_name, "hwmon", 5) != 0)
			continue;
		snprintf(driver_path, sizeof(driver_path), "%s/%s/name", root,
			 entry->d_name);
		if (read_line(driver_path, driver, sizeof(driver)) < 0)
			continue;

		for (index = 1; index <= 64; index++) {
			char label_path[PATH_MAX];
			char input_path[PATH_MAX];
			char label[64];
			char value[64];
			int score;

			snprintf(label_path, sizeof(label_path), "%s/%s/temp%d_label",
				 root, entry->d_name, index);
			if (read_line(label_path, label, sizeof(label)) < 0)
				continue;
			score = sensor_score(driver, label);
			if (score <= best_score)
				continue;
			snprintf(input_path, sizeof(input_path), "%s/%s/temp%d_input",
				 root, entry->d_name, index);
			if (read_line(input_path, value, sizeof(value)) < 0)
				continue;
			if (snprintf(sensor_input, sizeof(sensor_input), "%s", input_path) >=
			    (int)sizeof(sensor_input))
				continue;
			snprintf(sensor_description, sizeof(sensor_description), "%s %s",
				 driver, label);
			best_score = score;
		}
	}
	closedir(directory);

	if (!best_score) {
		fprintf(stderr, "ryujin-doom: no CPU package temperature sensor found\n");
		return -1;
	}
	fprintf(stderr, "ryujin-doom: CPU temperature sensor: %s\n",
		sensor_description);
	return 0;
}

int cpu_temp_read(int *temp_tenths)
{
	char value_text[64];
	char *end;
	long millidegrees;

	if (!sensor_input[0] || !temp_tenths ||
	    read_line(sensor_input, value_text, sizeof(value_text)) < 0)
		return -1;
	errno = 0;
	millidegrees = strtol(value_text, &end, 10);
	if (errno || end == value_text || (*end && *end != '\n') ||
	    millidegrees < -20000 || millidegrees > 150000)
		return -1;
	*temp_tenths = (int)((millidegrees + (millidegrees >= 0 ? 50 : -50)) / 100);
	return 0;
}

void cpu_temp_close(void)
{
	sensor_input[0] = '\0';
}

#endif
