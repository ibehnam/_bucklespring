Nostalgia bucklespring keyboard sound
=====================================

Copyright 2016 Ico Doornekamp

This project emulates the sound of my old faithful IBM Model-M space saver
bucklespring keyboard while typing on my notebook, mainly for the purpose of
annoying the hell out of my coworkers.

![Model M](img/model-m.jpg)
![Buckle](img/buckle.gif)

Bucklespring runs as a background process and plays back the sound of each key
pressed and released on your keyboard, just as if you were using an IBM
Model-M. The sound of each key has carefully been sampled, and is played back
while simulating the proper distance and direction for a realistic 3D sound
palette of pure nostalgic bliss.

To temporarily silence bucklespring, for example to enter secrets, press
ScrollLock twice (but be aware that those ScrollLock events _are_ delivered to
the application); same to unmute. The keycode for muting can be changed with
the `-m` option. Use keycode 0 to disable the mute function.

Installation
------------

[![Packaging status](https://repology.org/badge/tiny-repos/bucklespring.svg)](https://repology.org/project/bucklespring/versions)

### Debian

Bucklespring is available in the latest Debian and Ubuntu dev-releases, so you can
install with

```
$ sudo apt-get install bucklespring
```

### VoidLinux

Bucklespring is available in the VoidLinux repositories, so you can install with

```
$ sudo xbps-install -S bucklespring
```

### FreeBSD

Bucklespring can be installed via package:

```
$ pkg install bucklespring
```

or built via port:

```
$ cd /usr/ports/games/bucklespring
$ make install clean
```

### Linux, building from source

To compile on debian-based linux distributions, first make sure the require
libraries and header files are installed, then simply run `make`:

#### Dependencies on Debian
```
$ sudo apt-get install libopenal-dev libalure-dev libxtst-dev pkg-config
```

#### Dependencies on Arch Linux
```
$ sudo pacman -S openal alure libxtst
```

#### Dependencies on Fedora Linux
```
$ sudo dnf install gcc openal-soft-devel alure-devel libX11-devel libXtst-devel
```

#### Building
```
$ make
$ ./buckle
```

The default Linux build requires X11 for grabbing events. If you want to use
Bucklespring on the linux console or Wayland display server, you can configure
buckle to read events from the raw input devices in /dev/input. This will
require special permissions for buckle to open the devices, though. Build with

```
$ make libinput=1
```

#### Using snap on Ubuntu (since 16.04) and other distros

```
$ sudo snap install bucklespring
$ bucklespring.buckle
```

The snap includes the OpenAL configuration tweaks mentioned in this README.
See http://snapcraft.io/ for more info about Snap packages


### MacOS

Since `alure` is no longer available in Homebrew, a setup script is provided to
build the dependencies locally:

```
$ git clone https://github.com/zevv/bucklespring.git && cd bucklespring
$ ./setup-macos.sh
$ make
$ sudo ./buckle
```

The setup script will install `openal-soft` and `cmake` via Homebrew, then
download and build `alure` from source.

Note that you need superuser privileges to create the event tap on Mac OS X.
Also give your terminal Accessibility rights: System Preferences -> Security & Privacy -> Privacy -> Accessibility

If you want to use buckle while doing normal work, add an & behind the command.
```
$ sudo ./buckle &
```

### Windows

[The program has been compiled](https://github.com/Matin6725/bucklespring-Windows/releases/tag/bucklespring-Windows), but it has not yet received Microsoft's security certificate. Therefore, it may be detected as a virus by some antivirus software. To view reports from some antivirus programs, you can visit [link to reports](https://www.virustotal.com/gui/file/fe4a813c39793515d726311da50b9ac5e64e6d87ab21c8a16b8980b756a4e07b?nocache=1).

For better performance and to resolve some issues, it is recommended to run the program in **Administrator** mode.


Usage
-----

````
usage: ./buckle [options]

options:

  -d DEVICE use OpenAL audio device DEVICE
  -f        use a fallback sound for unknown keys
  -g GAIN   set playback gain [0..100]
  -m CODE   use CODE as mute key (default 0x46 for scroll lock)
  -M        start the program muted
  -h        show help
  -l        list available openAL audio devices
  -p PATH   load .wav files from directory PATH
  -s WIDTH  set stereo width [0..100]
  -v        increase verbosity / debugging
````

Sound packs
-----------

Because the WAV directory is selectable at runtime via `-p PATH`, bucklespring
can play any sound pack that follows its `{hex_scancode}-{0|1}.wav` naming
scheme. A helper script converts sound packs from [Klack](https://klack.app)
(a separate paid macOS app) into this format so you can use them with buckle:

```
$ ./scripts/convert-klack-sounds.py --pack Cardboard
$ ./buckle -p ./wav-klack/Cardboard
```

Klack ships six packs (`Cardboard`, `Cream`, `Crystal Purple`, `Japanese Black`,
`Milky Yellow`, `Oreo`). Klack only covers letters, modifiers, and arrow keys,
so the script overlays its samples on top of the Model-M baseline in `wav/` —
F-keys, keypad, and mouse click keep the authentic Model-M sound, so every key
makes noise out of the box. Convert all six at once with `--all`.

Klack is proprietary; the script operates only on your local installation and
does not redistribute any audio. The generated directory is ignored by git.
On macOS the script uses the built-in `afconvert` (no extra dependencies).

OpenAL notes
------------


Bucklespring uses the OpenAL library for mixing samples and providing a
realistic 3D audio playback. This section contains some tips and tricks for
properly tuning OpenAL for bucklespring.

* The default OpenAL settings can cause a slight delay in playback. Edit or create
  the OpenAL configuration file `~/.alsoftrc` and add the following options:

 ````
 period_size = 32
 periods = 4
 ````

* If you are using headphones, enabling the head-related-transfer functions in OpenAL
  for a better 3D sound:

 ````
 hrtf = true
 ````

* When starting an OpenAL application, the internal sound card is selected for output,
  and you might not be able to change the device using pavucontrol. The option to select
  an alternate device is present, but choosing the device has no effect. To solve this,
  add the following option to the OpenAL configuration file:

 ````
 allow-moves = true
 ````
