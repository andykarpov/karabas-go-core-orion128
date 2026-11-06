# Orion-128 core for Karabas Go / Mini / Mini G

A core of the Soviet home computer Orion-128 and its modifications for the Karabas Go family of boards (Xilinx Spartan-6 XC6SLX25). Work in progress: Mini G only for now (Go and Mini come later).

What works: KR580VM80A and Z80 (Z80 Card II, 2.5 / 5 / 10 MHz), up to 1 MB of RAM, the screen modes of the Orion-128 (480 points and the pseudocolour not tried on the board yet), RK-86 and MS7007 keyboards, ROM disk and ORDOS files, two floppy drives (`.odi`), IDE hard disks (`.ohi`), the RTC of the board, AY, the Orion-2010 registers and its SD card. OS-DOS, DSDOS 3.95 and AltairDOS / Best-DOS run.

- [docs/GUIDE.md](docs/GUIDE.md): **how to use it** (Russian): what to put on the SD card, where to get the Monitors, ROM disks and disk images, what to load in which order.
- [docs/PLAN.md](docs/PLAN.md): research, decisions and phases (Russian).
- [docs/HARDWARE.md](docs/HARDWARE.md): the supported hardware, memory map and ports (Russian).
- [docs/BACKLOG.md](docs/BACKLOG.md): open questions (Russian).

Clone with `--recursive`: the board modules are the submodule `modules/` ([karabas-go-modules](https://github.com/andykarpov/karabas-go-modules)). `src/make_core.py` needs [karabas-go-tools](https://github.com/andykarpov/karabas-go-tools) next to this repository.
