# ryujin-doom - DOOM on the ASUS ROG Ryujin III Extreme LCD

CC ?= gcc
PKG_CONFIG ?= pkg-config
PLATFORM ?= $(if $(filter Windows_NT,$(OS)),windows,linux)
STATIC_DEPS ?= 0

PKG_CONFIG_LIBS = $(PKG_CONFIG) $(if $(filter 1,$(STATIC_DEPS)),--static) --libs

CFLAGS = -O2 -Wall -DNORMALUNIX -Ivendor/doomgeneric/doomgeneric

ifeq ($(PLATFORM),windows)
TARGET = ryujin-doom.exe
CFLAGS += -D_WIN32_WINNT=0x0601 $(shell $(PKG_CONFIG) --cflags libusb-1.0 hidapi)
LDLIBS = $(shell $(PKG_CONFIG_LIBS) libusb-1.0 hidapi)
else
TARGET = ryujin-doom
CFLAGS += -DLINUX $(shell $(PKG_CONFIG) --cflags libusb-1.0)
LDLIBS = $(shell $(PKG_CONFIG_LIBS) libusb-1.0)
endif

DOOMGENERIC_COMMIT = dcb7a8dbc7a16ce3dda29382ac9aae9d77d21284
DOOMGENERIC_PATCH = patches/doomgeneric-ryujin-stats.patch
WAD ?= doom-shareware
WAD_FILE = $(shell ./scripts/fetch-wad.sh path $(WAD))

DOOMDIR = vendor/doomgeneric/doomgeneric
DOOMGENERIC_PATCH_STAMP = $(DOOMDIR)/.ryujin-doom-patched
OBJDIR = build

# Object list from vendor/doomgeneric/doomgeneric/Makefile.soso, minus
# doomgeneric_soso.o, plus the ryujin-doom platform and LCD transport.
SRC_DOOM = dummy.o am_map.o doomdef.o doomstat.o dstrings.o d_event.o d_items.o d_iwad.o d_loop.o d_main.o d_mode.o d_net.o f_finale.o f_wipe.o g_game.o hu_lib.o hu_stuff.o info.o i_cdmus.o i_endoom.o i_joystick.o i_scale.o i_sound.o i_system.o i_timer.o memio.o m_argv.o m_bbox.o m_cheat.o m_config.o m_controls.o m_fixed.o m_menu.o m_misc.o m_random.o p_ceilng.o p_doors.o p_enemy.o p_floor.o p_inter.o p_lights.o p_map.o p_maputl.o p_mobj.o p_plats.o p_pspr.o p_saveg.o p_setup.o p_sight.o p_spec.o p_switch.o p_telept.o p_tick.o p_user.o r_bsp.o r_data.o r_draw.o r_main.o r_plane.o r_segs.o r_sky.o r_things.o sha1.o sounds.o statdump.o st_lib.o st_stuff.o s_sound.o tables.o v_video.o wi_stuff.o w_checksum.o w_file.o w_main.o w_wad.o z_zone.o w_file_stdc.o i_input.o i_video.o doomgeneric.o

OBJS = $(addprefix $(OBJDIR)/, $(SRC_DOOM)) $(OBJDIR)/doomgeneric_ryujin_doom.o $(OBJDIR)/ryujin_lcd.o $(OBJDIR)/cpu_temp.o

all: vendor $(TARGET)

$(TARGET): $(OBJS)
	$(CC) $(LDFLAGS) $(OBJS) -o $@ $(LDLIBS)

$(OBJDIR)/%.o: $(DOOMDIR)/%.c | $(OBJDIR) $(DOOMGENERIC_PATCH_STAMP)
	$(CC) $(CFLAGS) -c $< -o $@

$(OBJDIR)/doomgeneric_ryujin_doom.o: src/doomgeneric_ryujin_doom.c src/ryujin_lcd.h src/cpu_temp.h | $(OBJDIR) $(DOOMGENERIC_PATCH_STAMP)
	$(CC) $(CFLAGS) -Isrc -c $< -o $@

$(OBJDIR)/ryujin_lcd.o: src/ryujin_lcd.c src/ryujin_lcd.h | $(OBJDIR)
	$(CC) $(CFLAGS) -Isrc -c $< -o $@

$(OBJDIR)/cpu_temp.o: src/cpu_temp.c src/cpu_temp.h | $(OBJDIR)
	$(CC) $(CFLAGS) -Isrc -c $< -o $@

$(OBJDIR):
	mkdir -p $(OBJDIR)

vendor: $(DOOMGENERIC_PATCH_STAMP)

$(DOOMGENERIC_PATCH_STAMP): $(DOOMDIR)/doomgeneric.h $(DOOMGENERIC_PATCH)
	@if patch --dry-run --directory=$(DOOMDIR) --strip=1 --forward --batch \
		--input=$(abspath $(DOOMGENERIC_PATCH)) >/dev/null 2>&1; then \
		echo "Patching doomgeneric HUD for Ryujin telemetry"; \
		patch --directory=$(DOOMDIR) --strip=1 --forward --batch \
			--input=$(abspath $(DOOMGENERIC_PATCH)); \
	elif patch --dry-run --directory=$(DOOMDIR) --strip=1 --reverse --batch \
		--input=$(abspath $(DOOMGENERIC_PATCH)) >/dev/null 2>&1; then \
		echo "doomgeneric HUD patch already applied"; \
	else \
		echo "doomgeneric HUD patch does not apply cleanly" >&2; \
		exit 1; \
	fi
	@touch $@

$(DOOMDIR)/doomgeneric.h:
	@echo "Cloning doomgeneric"
	@mkdir -p vendor
	@git clone https://github.com/ozkl/doomgeneric vendor/doomgeneric
	@git -C vendor/doomgeneric checkout $(DOOMGENERIC_COMMIT)

# The vendor clone creates every engine source at once. Declare that
# relationship so a parallel clean build waits for the clone before trying to
# resolve object prerequisites such as dummy.c.
$(DOOMDIR)/%.c: $(DOOMDIR)/doomgeneric.h
	@test -f $@

# Pattern-generated vendor sources are real clone outputs, not disposable
# intermediates. Keep them for the second (Linux) build in make dist.
.PRECIOUS: $(DOOMDIR)/%.c

wad:
	./scripts/fetch-wad.sh fetch $(WAD)

wads:
	./scripts/fetch-wad.sh fetch all

run: $(TARGET) wad
	./$(TARGET) -iwad "$(WAD_FILE)"

dist:
	./scripts/build-release.sh

clean:
	rm -rf $(OBJDIR)
	rm -f ryujin-doom ryujin-doom.exe

.PHONY: all vendor wad wads run dist clean
