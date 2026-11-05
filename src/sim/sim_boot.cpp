// sim_boot: tb_boot (orion_system + SRAM model) under verilator.
//
//   sim_boot --rom FILE:ADDR ... [--z80] [--ms N] [--ppm OUT] [--key MS:CODE,CODE..] ...
//
// The ROMs go in through the ROM loader (one byte every 12 clocks). The machine then runs N ms of
// its time. --ppm writes the last output frame, 800 x 600. --key sends PS/2 set 2 codes (hex) at
// a time in ms, 100 us apart. Prints a checksum of the frame and how many pixels are not black.
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
	struct Key { uint64_t at; int code; };
	std::vector<Key> keys;
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
		else if (!strcmp(argv[i], "--key")) {
			char *p = argv[++i];
			uint64_t at = strtoul(p, &p, 10) * 40000;
			while (*p == ':' || *p == ',') { keys.push_back({ at, (int)strtoul(p + 1, &p, 16) }); at += 4000; }
		}
		else if (!strcmp(argv[i], "--ms")) ms = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--ppm")) ppm = argv[++i];
		else { fprintf(stderr, "bad option %s\n", argv[i]); return 2; }
	}
	top->cpu_z80 = z80;
	top->reset = 1; top->rom_active = 0; top->rom_wr = 0;
	top->kb_scancode = 0; top->kb_scancode_upd = 0;
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
	uint64_t start = clks, end = clks + (uint64_t)ms * 40000;
	int beeps = 0, prev = 0;
	std::vector<uint8_t> frame(800 * 600 * 3), last(800 * 600 * 3);
	int fx = 0, fy = 0, frames = 0, prev_de = 0, prev_vs = 0;
	size_t kn = 0;
	while (clks < end) {
		tick();
		if (top->beep && !prev) beeps++;
		prev = top->beep;
		if (kn < keys.size() && clks - start >= keys[kn].at) {
			top->kb_scancode = keys[kn++].code;
			top->kb_scancode_upd ^= 1;
		}
		if (top->de) {
			if (fx < 800 && fy < 600) {
				uint32_t c = top->rgb;
				uint8_t *p = &frame[(fy * 800 + fx) * 3];
				p[0] = c >> 16; p[1] = c >> 8; p[2] = c;
			}
			fx++;
		}
		if (!top->de && prev_de) { if (frames && fx != 800) printf("bad line: %d pixels at y %d\n", fx, fy); fx = 0; fy++; }
		if (top->vs && !prev_vs) { if (frames && fy != 600) printf("bad frame: %d lines\n", fy); fy = 0; fx = 0; frames++; last = frame; }
		prev_de = top->de; prev_vs = top->vs;
	}
	uint32_t sum = 0, lit = 0;
	for (size_t i = 0; i < last.size(); i++) { sum = sum * 31 + last[i]; lit += last[i] != 0; }
	printf("%s %d ms: %d frames, beep edges %d, frame sum %08x lit %u\n", z80 ? "Z80" : "8080", ms, frames, beeps, sum, lit);
	if (ppm) {
		FILE *f = fopen(ppm, "wb");
		fprintf(f, "P6\n800 600\n255\n");
		fwrite(last.data(), 1, last.size(), f);
		fclose(f);
	}
	delete top;
	return 0;
}
