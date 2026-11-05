#!/bin/bash
# The machine on both processors. Builds sim_boot (verilator) into src/sim/build, runs it from src/.
#  1. no ROM disk: M2 prints its prompt.
#  2. ROM disk: M2 loads ORDOS, which shows VC. The frames of the two processors must be the same.
#  3. a key (Down) moves the cursor of VC: the frame differs from the one before it.
set -eu
H=$(cd "$(dirname "$0")" && pwd)
S=$(cd "$H/.." && pwd)
B=$H/build
mkdir -p "$B"
"$H/vhdl2v.sh" "$B/vhdl" > /dev/null 2> "$B/vhdl.log" || { cat "$B/vhdl.log"; exit 1; }
R=$S/rtl
SRC="$H/tb_boot.v $R/orion/orion_system.v $R/orion/orion_cpu.v $R/orion/orion_ppi.v $R/orion/orion_sram.v $R/orion/orion_video.v $R/orion/orion_kbd.v $R/vm80a/vm80a.v $B/vhdl/t80pa.v"
verilator --language 1364-2005 --cc --exe --build -j 8 -O3 --top-module tb_boot -Mdir "$B/obj" -o sim_boot \
	-Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN -Wno-UNOPTFLAT -Wno-PINMISSING -Wno-PINNOTFOUND \
	--x-initial fast -CFLAGS -O2 $SRC "$H/sim_boot.cpp" > "$B/build.log" 2>&1 || { tail -30 "$B/build.log"; exit 1; }
cd "$S"
SIM=$B/obj/sim_boot
M2=roms/M2rk.bin:0x200000
RD=roms/romdisk1.bin:0x100000
err=0
T=${ORD_MS:-4000}
"$SIM" --rom $M2 --ms 1500 --ppm "$B/m2_8080.ppm"
"$SIM" --rom $M2 --z80 --ms 1500 --ppm "$B/m2_z80.ppm"
"$SIM" --rom $M2 --rom $RD --ms $T --ppm "$B/ord_8080.ppm"
"$SIM" --rom $M2 --rom $RD --z80 --ms $T --ppm "$B/ord_z80.ppm"
"$SIM" --rom $M2 --rom $RD --ms $((T + 800)) --key $T:E0,72 --key $((T + 100)):E0,F0,72 --ppm "$B/key_8080.ppm"
# the prompt line only (8 points x 2, from y 44): below it the cursor blinks, in another phase on each
cmp -n $((15 + (44 + 16) * 800 * 3)) "$B/m2_8080.ppm" "$B/m2_z80.ppm" || err=1
cmp "$B/ord_8080.ppm" "$B/ord_z80.ppm" || err=1
for f in m2_8080 ord_8080; do
	[ "$(tail -c +16 "$B/$f.ppm" | tr -d '\000' | wc -c)" -gt 0 ] || { echo "$f: empty screen"; err=1; }
done
if cmp -s "$B/ord_8080.ppm" "$B/key_8080.ppm"; then echo "the key changed nothing"; err=1; fi
echo "run_boot: $err errors"
exit $err
