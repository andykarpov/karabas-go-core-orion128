#!/bin/bash
# Phase 0 check: the Monitor boots on both processors. Builds sim_boot (verilator) into
# src/sim/build, runs it from src/ and compares the screens: the same ROMs must draw the same text.
#  1. no ROM disk: M2 prints its prompt.
#  2. ROM disk: M2 loads ORDOS, which shows its menu.
set -eu
H=$(cd "$(dirname "$0")" && pwd)
S=$(cd "$H/.." && pwd)
B=$H/build
mkdir -p "$B"
"$H/vhdl2v.sh" "$B/vhdl" > /dev/null 2> "$B/vhdl.log" || { cat "$B/vhdl.log"; exit 1; }
R=$S/rtl
SRC="$H/tb_boot.v $R/orion/orion_system.v $R/orion/orion_cpu.v $R/orion/orion_ppi.v $R/orion/orion_sram.v $R/vm80a/vm80a.v $B/vhdl/t80pa.v"
verilator --language 1364-2005 --cc --exe --build -j 8 -O3 --top-module tb_boot -Mdir "$B/obj" -o sim_boot \
	-Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN -Wno-UNOPTFLAT -Wno-PINMISSING -Wno-PINNOTFOUND \
	--x-initial fast -CFLAGS -O2 $SRC "$H/sim_boot.cpp" > "$B/build.log" 2>&1 || { tail -30 "$B/build.log"; exit 1; }
cd "$S"
SIM=$B/obj/sim_boot
M2=roms/M2rk.bin:0x200000
RD=roms/romdisk1.bin:0x100000
err=0
"$SIM" --rom $M2 --ms 1500 --ppm "$B/m2_8080.ppm"
"$SIM" --rom $M2 --z80 --ms 1500 --ppm "$B/m2_z80.ppm"
"$SIM" --rom $M2 --rom $RD --ms ${ORD_MS:-4000} --ppm "$B/ord_8080.ppm"
"$SIM" --rom $M2 --rom $RD --z80 --ms ${ORD_MS:-4000} --ppm "$B/ord_z80.ppm"
# the prompt line only: below it the cursor blinks, in another phase on each processor
cmp -n $((15 + 8 * 384 * 3)) "$B/m2_8080.ppm" "$B/m2_z80.ppm" || err=1
cmp "$B/ord_8080.ppm" "$B/ord_z80.ppm" || err=1
for f in m2_8080 ord_8080; do
	# a screen with text differs from an empty one
	[ "$(tail -c +16 "$B/$f.ppm" | tr -d '\000' | wc -c)" -gt 0 ] || { echo "$f: empty screen"; err=1; }
done
echo "run_boot: $err errors"
exit $err
