#!/usr/bin/env python3
"""Writes the test ROM of the Z80 Card II ports (a Monitor of 2 KB at F800, the Z80 only). Results in
page 0: E000 the dispatcher (5A), E001 all RAM (77), E002 count of interrupts of 50 Hz, E003 port FB
reads back (C0), E004 port FE page of the ROM disk (read through F500). Then it shows screen 1 on
the screen of 512 points with lines at the two ends of row 0.
usage: mkrom_card.py OUT"""
import sys

code = bytearray()
labels = {}
fix = []
ORG = 0xF800
def e(*b): code.extend(b)
def here(): return ORG + len(code)
def jp(name): e(0xC3); fix.append((len(code), name)); e(0, 0)
def ld_a(v): e(0x3E, v)
def out(p): e(0xD3, p)
def sta(a): e(0x32, a & 255, a >> 8)
def lda(a): e(0x3A, a & 255, a >> 8)

jp('start')
labels['start'] = here()
e(0x31, 0xC0, 0xF3)          # ld sp,F3C0
# the dispatcher: page 1 segment 2 at 0000
ld_a(0x06); out(0xFB); ld_a(0x5A); sta(0x0123); ld_a(0x80); out(0xFB)
ld_a(1); out(0xF9); lda(0x8123); e(0x47); e(0xAF); out(0xF9); e(0x78); sta(0xE000)
# all RAM, from a stub at 1000
e(0x21); fix.append((len(code), 'stub')); e(0, 0)   # ld hl,stub
e(0x11, 0x00, 0x10)          # ld de,1000
e(0x01, 32, 0)               # ld bc,32
e(0xED, 0xB0)                # ldir
e(0xC3, 0x00, 0x10)          # jp 1000
labels['stub'] = here()
ld_a(0xA0); out(0xFB); ld_a(0x77); sta(0xF900); lda(0xF900); e(0x47); ld_a(0x80); out(0xFB)
e(0x78); sta(0xE001); jp('back')
code.extend(bytes(32 - (here() - labels['stub'])))
labels['back'] = here()
# the handler at 0038
e(0x21); fix.append((len(code), 'isr')); e(0, 0)
e(0x11, 0x38, 0x00); e(0x01, 16, 0); e(0xED, 0xB0)
e(0xED, 0x56)                # im 1
ld_a(0xC0); out(0xFB)
e(0xDB, 0xFB); sta(0xE003)   # in a,(FB)
e(0xFB)                      # ei
# the ROM disk page 3 at 0: byte 0 of 130000
ld_a(0x90); sta(0xF503); ld_a(3); out(0xFE); e(0xAF); sta(0xF501); sta(0xF502); lda(0xF500); sta(0xE004)
# screen 1, 512 points, mono
ld_a(0x81); out(0xFA); e(0xAF); out(0xF8)
ld_a(0xFF); sta(0x8000); sta(0xBF00)
labels['loop'] = here()
jp('loop')
labels['isr'] = here()
e(0xF5); lda(0xE002); e(0x3C); sta(0xE002); e(0xF1); e(0xFB); e(0xC9)
for off, name in fix:
    a = labels[name]
    code[off] = a & 255
    code[off + 1] = a >> 8
open(sys.argv[1], 'wb').write(bytes(code).ljust(2048, b'\xFF'))
