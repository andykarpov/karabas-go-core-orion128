# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

A new core of the Soviet home computer Orion-128 (KR580VM80A, 2.5 MHz, Radio magazine 1990) and its modifications (Z80 Card II, Orion-2010; Orion-PRO optional) for the Karabas Go, Mini and Mini G boards: Xilinx Spartan-6 XC6SLX25, ISE 14.7 (XST).

Status: phase 4 done on Mini G (IDE on the PPIs, RTC in the registers of the mcu, AY, the Orion-2010 registers and its SD card; floppy Write Track for DSDOS); before it the floppy, Z80 Card II, 10 MHz, 1 MB, wide screens, MS7007, ORDOS files. Next phase 5 (Mini and Go tops, tape, release). Go and Mini tops come in phase 5. Docs, in Russian: `docs/PLAN.md` (research, decisions, architecture, phases), `docs/HARDWARE.md` (the supported hardware, memory map and ports), `docs/BACKLOG.md` (open decisions, things to verify, findings). Follow the phases; record a changed decision in PLAN.md.

All file work goes through the firmware (OSD, `FL` / `F` items, burst): no loader or soft CPU in the core. The machine is our own synchronous Verilog: `orion2010-zxuno` gives the Orion-2010 register map and ori1fpga the timing of the original. Neither has a license file, so they are references, not sources to copy. The core is GPL v3 (`LICENSE`).

The closest sibling is `../karabas-go-core-msx`: a new core with the same split (take `msx_sram`, `msx_fdd_cache`, `nextor_sd`, `wd1793`, `jt49` from it, with credit). Also `../karabas-go-core-rk86` (K580 parts, loading a program into the memory), `../karabas-go-core-profi` (T80se, vg93), `../karabas-go-core-menu` (800 x 600 on all boards).

## Layout

- `src/Makefile`: the ISE flow, as in the converted cores. `src/karabas_<board>.{prj,xst,ut,ucf}`: its inputs. The `.ucf` pins come from core-msx; the timing block at the end describes the planned clocks.
- `src/make_core.py`: a symlink to `../../karabas-go-tools/make_core/make_core.py` (the tools repo next to this one). `src/tools/check_osd.py`: the slot check of `make core`, a copy from core-msx.
- `src/core.json`: the core file description (kgo2, one file for all boards, `orion128.kg`, only Mini G so far). `src/rtl/karabas_minig_top.v` lists its soft switch indexes.
- `src/rtl/orion/`: `orion_system.v` (the machine, the memory map), `orion_cpu.v` (vm80a or T80pa as one bus), `orion_ppi.v` (8255 mode 0), `orion_sram.v` (from msx_sram, with the 16-bit video port), `orion_video.v` (800 x 600 from the SRAM), `orion_kbd.v` (scancodes to the RK-86 and MS7007 matrices), `orion_loader.v` (ROM loader, FL slots, the RAM disk walker), `orion_fdd_cache.v` (from msx_fdd_cache: image cache in the SRAM, one per drive), `orion_ide.v` (the IDE of S. Akimov on a PPI, hdf_ata of the modules), `orion_sd.v` (the bit-serial SD card of the Orion-2010, the card of nextor_sd). `src/rtl/jt49/`: from core-msx. `src/rtl/fdd/wd1793.v`: from core-msx. `src/rtl/karabas_minig_top.v`: the board. `src/rtl/vm80a/` (upstream 1801BM1/vm80a, unchanged), `src/rtl/t80/` (from core-msx).
- `src/roms/`: `M2rk.bin` (Monitor 2, RK-86 keyboard, SRAM 200000), `romdisk1.bin` (ORDOS 4.03, SRAM 100000), from OriZEmu.
- `src/sim/mkrom_card.py`: the test ROM of the Z80 Card ports for `run_boot.sh`.
- `src/orion.prj`, `orion.xst`: the machine alone, `make orion-xst`, `make orion-report`.
- `modules/`: the git submodule [karabas-go-modules](https://github.com/andykarpov/karabas-go-modules), its rules are in `modules/CLAUDE.md`. A change there is made there and taken here by moving the submodule. Clone with `--recursive`.

## Build

- `cd src && make minig` (or `go`, `mini`; no target: all boards), `make minig-xst`, `-impl`, `-core`, `make minig-report`. It sources `/opt/Xilinx/14.7/ISE_DS/settings64.sh`. The boards share `xst/` and `_ngo/`: one build at a time.
- Until the first release build only Mini G. Map with `-t 2` by default (`MAP_T_<board>`); Mini G uses `-t 3`, as `-t 2` misses the HDMI serializer path (`docs/BACKLOG.md`).
- A new source file goes into `karabas_<board>.prj`. No coregen: inferred memories and `kg_pll`, `kg_dcm`.
- The `.bin` and `.kg` files of a release are committed, and `build` of `core.json` is the id `YYMMDDNN`.

## Rules of the core

- **One clock, 40 MHz**, with enables: no derived clocks, no clocks from counters, no writes on `wr_n` edges, no latches. Only the MCU link crosses clocks (`modules/CLAUDE.md`, "Clock crossings").
- **Video: standard timing, syncs always present** (VESA 800 x 600 at 60 Hz): the monitor of the user rejects anything else. The screen is read straight from the SRAM, no frame buffer.
- **Mini / Mini G: `FT_CLK_OUT` always carries about 8 MHz** (ODDR2), or the FT812 hums into the audio.
- **Go: unused `FDC_*` outputs are 0**, the pins are high = active.
- **SDRAM unused**, pins idle: on Mini G2 its `~CS` is the FLASH_CS_N line, drive that 1.
- **OSD:** `CMD_SWITCHES` index = position of the item in `osd`, file, separator and page items included: a moved item changes the registers of the items after it. `F` and `FL` items need different `slot` numbers (one array in the firmware, `check_osd.py` checks it).
- **8080 vs Z80:** `OUT n` of the 8080 repeats the port number on A15..8, so a latch at F8xx also answers `OUT F8`; on the Z80 decode IORQ instead. The beeper on INTE (`EI` / `DI`) exists only on the 8080.
- **Verilog-2001 that XST accepts**, as `modules/CLAUDE.md` says. Imported code keeps its form; local changes are marked `// karabas:` with the reason.
- **ROMs:** the Monitors and ROM disks are not ours. The user allowed M2 and one ROM disk in the repo and the `.kg` (2026-11-05); others come from `/orion` on the SD card through `FL` items.
- Before a step that needs the board or the HDMI capture, tell the user: they may be unplugged. Ask before a firmware flash.

## Verifying a change

- Simulate first: `src/sim/run_boot.sh` (verilator, T80 through `ghdl --synth`, as core-msx; about 12 minutes, `ORD_MS` shortens it; screens in `src/sim/build/*.ppm`). Do not edit the script while it runs. `src/sim/run_fdd.sh MONITOR IMAGE [MS]` boots a Monitor with a disk image through a model of the firmware mounter; `sim_boot --hdd IMAGE` mounts a hard disk / SD image (slot 6); `+ide`, `+sd`, `+fdc`, `+bus` print traces. A phase ends with its check in `docs/PLAN.md`. On the board `TestZ80.BIN` of OriZEmu (Altair-192 test, load it as the Monitor, CPU Z80) checks the dispatcher, PPIs, 50 Hz; drive the OSD step by step and look at each frame: the browser opens on the current file, and a frame of the capture is sometimes black.
- `kosarev/orion128` (MIT, Python) and OriZEmu are the reference for the behaviour; TEST128, TEST256 and TestZ80 are the tests of the machine.
- Compare utilization and timing (`make minig-report`) with the build before the change.

## Memory

The Claude Code memory of this repo is shared with all karabas-go repos: `~/.claude/projects/<this project>/memory` is a symlink to `../karabas-go-notes` (private repo `andykarpov/karabas-go-notes`, `link.sh` there makes the links). Its `MEMORY.md` is split by repo; commit and push it after every memory change.
