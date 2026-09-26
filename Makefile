
NAME   	:= buckle
SRC 	:= main.c
VERSION	:= 1.5.1
ifeq ($(OS),Windows_NT)
CC := i686-w64-mingw32-gcc
endif
PATH_AUDIO ?= "./wav"

CFLAGS	?= -O3 -g
LDFLAGS ?= -g
CFLAGS  += -Wall -Werror 
CFLAGS  += -DVERSION=\"$(VERSION)\"
CFLAGS  += -DPATH_AUDIO=\"$(PATH_AUDIO)\"

 ifeq ($(OS),Windows_NT)
 BIN     := $(NAME).exe
 CFLAGS  += -I"win32/include"
# LDFLAGS += -mwindows -static-libgcc -static-libstdc++
 LDFLAGS += -static-libgcc -static-libstdc++
 LIBS    += -L"win32/lib" -lALURE32 -lOpenAL32
 SRC     += scan-windows.c audio-openal.c
else
 OS := $(shell uname)
 ifeq ($(OS), Darwin)
  # Native CoreAudio output (audio-coreaudio.c): system frameworks only, no OpenAL,
  # no ALURE, no pkg-config, nothing to set up before `make`.
  BIN     := $(NAME)
  LDFLAGS += -framework ApplicationServices -framework Cocoa -framework CoreAudio -framework AudioToolbox
  SRC     += scan-mac.m audio-coreaudio.c
 else
  BIN     := $(NAME)
  LIBS    += -lm
  ifdef libinput
   LIBS    += $(shell pkg-config --libs openal alure libinput libudev)
   CFLAGS  += $(shell pkg-config --cflags openal alure libinput libudev)
   SRC     += scan-libinput.c audio-openal.c
  else
   LIBS    += $(shell pkg-config --libs openal alure xtst x11)
   CFLAGS  += $(shell pkg-config --cflags openal alure xtst x11)
   SRC     += scan-x11.c audio-openal.c
  endif
 endif
endif

OBJS    = $(addsuffix .o, $(basename $(SRC)))
CC 	?= $(CROSS)gcc
LD 	?= $(CROSS)gcc
CCLD 	?= $(CC)
STRIP 	= $(CROSS)strip

%.o: %.c
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

%.o: %.m
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

$(BIN):	$(OBJS)
	$(CCLD) $(LDFLAGS) -o $@ $(OBJS) $(LIBS)

dist:
	mkdir -p $(NAME)-$(VERSION)
	cp -a *.c *.m *.h wav scripts Makefile LICENSE $(NAME)-$(VERSION)
	tar -zcf /tmp/$(NAME)-$(VERSION).tgz $(NAME)-$(VERSION)
	rm -rf $(NAME)-$(VERSION)

rec: rec.c
	gcc -Wall -Werror rec.c -o rec

clean:
	$(RM) $(OBJS) $(BIN) core rec

strip: $(BIN)
	$(STRIP) $(BIN)

# Convert a Klack.app sound pack into wav-klack/<PACK>/ using the same
# filename convention as wav/. Requires macOS (afconvert) and a local
# Klack install; see scripts/convert-klack-sounds.py for details.
KLACK_PACK ?= Cardboard
.PHONY: wav-klack
wav-klack:
	./scripts/convert-klack-sounds.py --pack "$(KLACK_PACK)"
