// sim_boot: tb_boot (orion_system + SRAM model) under verilator.
//
//   sim_boot --rom FILE:ADDR ... [--z80] [--ms N] [--ppm OUT]
//
// The ROMs go in through the ROM loader (one byte every 12 clocks). The machine then runs N ms of
// its time. --ppm writes screen 0 as 384 x 256 (page 0, C000-EFFF, one bit per point, green on
// black: there is no video in phase 0). Prints a checksum of the screen and how many points are lit.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include "Vtb_boot.h"
#include "verilated.h"

static Vtb_boot *top;
static uint64_t clks = 0;

static void tick() {
	top->clk = 0; top->eval();
	top->clk = 1; top->eval();
	clks++;
}

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	top = new Vtb_boot;
	std::vector<std::pair<std::string, uint32_t>> roms;
	int ms = 1000;
	const char *ppm = nullptr;
	bool z80 = false;
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--rom")) {
			std::string s = argv[++i];
			size_t c = s.rfind(':');
			roms.push_back({ s.substr(0, c), (uint32_t)strtoul(s.c_str() + c + 1, nullptr, 0) });
		}
		else if (!strcmp(argv[i], "--z80")) z80 = true;
		else if (!strcmp(argv[i], "--ms")) ms = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--ppm")) ppm = argv[++i];
		else { fprintf(stderr, "bad option %s\n", argv[i]); return 2; }
	}
	top->cpu_z80 = z80;
	top->reset = 1; top->rom_active = 0; top->rom_wr = 0;
	top->kb_in = 0xFF; top->kb_c_i = 0xF;
	for (int i = 0; i < 400; i++) tick();
	top->reset = 0; top->rom_active = 1;
	for (auto &r : roms) {
		FILE *f = fopen(r.first.c_str(), "rb");
		if (!f) { perror(r.first.c_str()); return 2; }
		int c; uint32_t a = r.second;
		while ((c = fgetc(f)) != EOF) {
			top->rom_addr = a++; top->rom_data = c; top->rom_wr = 1; tick();
			top->rom_wr = 0;
			for (int i = 0; i < 11; i++) tick();
		}
		fclose(f);
	}
	for (int i = 0; i < 40; i++) tick();
	top->rom_active = 0;
	uint64_t end = clks + (uint64_t)ms * 40000;
	int beeps = 0, prev = 0;
	while (clks < end) {
		tick();
		if (top->beep && !prev) beeps++;
		prev = top->beep;
	}
	std::vector<uint8_t> scr(48 * 256);
	uint32_t sum = 0, lit = 0;
	for (int c = 0; c < 48; c++)
		for (int r = 0; r < 256; r++) {
			top->dbg_addr = ((0xC000 + c * 256 + r) << 1); top->eval();
			uint8_t b = top->dbg_q;
			scr[r * 48 + c] = b;
			sum = sum * 31 + b;
			lit += __builtin_popcount(b);
		}
	printf("%s %d ms: vmode %d vpage %d beep edges %d screen sum %08x lit %u\n", z80 ? "Z80" : "8080", ms, top->vmode, top->vpage, beeps, sum, lit);
	if (ppm) {
		FILE *f = fopen(ppm, "wb");
		fprintf(f, "P6\n384 256\n255\n");
		for (int y = 0; y < 256; y++)
			for (int x = 0; x < 384; x++) {
				int on = (scr[y * 48 + x / 8] >> (7 - x % 8)) & 1;
				uint8_t p[3] = { 0, (uint8_t)(on ? 255 : 0), 0 };
				fwrite(p, 1, 3, f);
			}
		fclose(f);
	}
	delete top;
	return 0;
}
