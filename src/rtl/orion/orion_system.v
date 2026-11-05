`timescale 1ns / 1ps
`default_nettype wire

/*
 orion_system.v

 The Orion-128: the processor, the memory map, the ports and the SRAM, on one clock of 40 MHz.
 docs/HARDWARE.md has the map.

 SRAM (a byte address of 22 bits, orion_sram):
   000000  RAM, 1 MB: a page of 64 KB is {page[3:1], a[15:0], page[0]}, so pages 0 and 1 are the two
           byte lanes of one address (the video reads pixel and colour in one access)
   100000  ROM disk, 1 MB (the roms of core.json or an FL item), read through port A of the PPI at
           F500, 16 pages of 64 KB by port FE
   200000  Monitor (2 KB)
   240000  the disk images A and B (orion_fdd_cache), 820 KB each
 Hard disks: orion_ide on the PPIs F500 and F600. Clock: F760 address, F761 data, or F7B1 address,
 F7B0 data, in the registers of the mcu. AY: ports FFFD, BFFD of the Z80, or F7A1 register number
 and read, F7A0 write.
 The ROMs arrive by the ROM loader of the mcu: rom_addr is that byte address, the machine is in
 reset while rom_active.

 After reset the Monitor answers everywhere (a read), until the first read at F800-FFFF: this is
 how a CPU that starts at 0000 finds its code at F800.
*/

module orion_system (
	input wire clk,
	input wire reset,
	input wire cpu_z80,          // a change is a short reset
	input wire [1:0] cpu_speed,  // the Z80: 0 2.5, 1 5, 2 10 MHz
	input wire [1:0] ram_size,   // 0 256, 1 512 KB, 2 1 MB
	input wire kb_ms7007,        // MS7007 keyboard (else RK-86), change it with a reset

	// the ROM loader of the mcu
	input wire rom_active,
	input wire [21:0] rom_addr,
	input wire [7:0] rom_data,
	input wire rom_wr,

	// the file loader of the mcu, orion_loader; the machine is in reset meanwhile
	input wire file_active,
	input wire [7:0] file_slot,
	input wire [31:0] file_addr,
	input wire [7:0] file_data,
	input wire file_wr,

	// the file mounter of the mcu: the disks A and B are its slots 4 and 5, the hard disks 6 and 7
	input wire [7:0] img_mounted,
	input wire [63:0] img_size,
	input wire [7:0] img_wp,
	input wire img_data_wr,
	input wire [8:0] img_data_addr,
	input wire [7:0] img_data,
	input wire img_result_wr,
	input wire [7:0] img_result,
	input wire [15:0] img_sum,
	output wire img_q_wr,
	output wire [23:0] img_q_di,
	input wire img_q_ack,

	input wire [7:0] kb_scancode,
	input wire kb_scancode_upd,

	output wire [23:0] rgb,
	output wire hs,
	output wire vs,
	output wire de,

	output wire [7:0] rtc_a,
	output wire [7:0] rtc_di,
	input wire [7:0] rtc_do,
	output wire rtc_cs,
	output wire rtc_wr_n,

	output wire beep,
	output wire [9:0] ay_sound,

	output wire [20:0] MA,
	inout wire [15:0] MD,
	output wire [1:0] MWR_N
);

// a change of the processor resets the machine for 16 states, the new one starts from the Monitor
reg z80 = 1'b0;
reg [7:0] sw_cnt = 8'd0;
always @(posedge clk) begin
	if (sw_cnt != 8'd0)
		sw_cnt <= sw_cnt - 8'd1;
	else if (cpu_z80 != z80) begin
		z80 <= cpu_z80;
		sw_cnt <= 8'd255;
	end
end

wire run_reset = reset | rom_active | file_active | (sw_cnt != 8'd0);

wire [15:0] a;
wire [7:0] cpu_do;
reg [7:0] cpu_di;
wire mem_rd, mem_wr, io_rd, io_wr, inte, inta;
wire rd_ok;
wire int_n;

orion_cpu cpu (
	.clk(clk),
	.reset(run_reset),
	.cpu_z80(z80),
	.speed(cpu_speed),
	.rd_ok(rd_ok),
	.addr(a),
	.dout(cpu_do),
	.din(cpu_di),
	.mem_rd(mem_rd),
	.mem_wr(mem_wr),
	.io_rd(io_rd),
	.io_wr(io_wr),
	.int_n(int_n),
	.inta(inta),
	.inte(inte)
);

// ------------------------------------------------------------------ decoding
wire full = z80 & fb[5];                       // Z80 Card: all of 0000-FFFF is RAM
wire top_f800 = !full && a[15:11] == 5'b11111;
wire sel_dev = !full && a[15:10] == 6'b111101; // F400-F7FF, a memory access
wire sel_f4 = sel_dev && a[9:8] == 2'd0;
wire sel_f5 = sel_dev && a[9:8] == 2'd1;
wire sel_f6 = sel_dev && a[9:8] == 2'd2;
wire sel_f7 = sel_dev && a[9:8] == 2'd3;
wire sel_fdc, sel_rgu, fdc_drq;
wire sel_rtc_a = sel_f7 && (a[7:0] == 8'h60 || a[7:0] == 8'hB1);
wire sel_rtc_d = sel_f7 && (a[7:0] == 8'h61 || a[7:0] == 8'hB0);
reg [7:0] rtc_ar = 8'd0;
wire ay_io = z80 && a[15] && a[7:0] == 8'hFD;             // FFFD (A14 = 1), BFFD (A14 = 0)
wire sel_ay_mem = sel_f7 && a[7:4] == 4'hA;
wire [7:0] ay_do;
wire sdc_busy, sdc_done, sdc_error, sdc_in_strobe;
wire [2:0] sdc_slot;
wire [8:0] sdc_byte_addr;
wire [7:0] sdc_in_data;
wire [7:0] fdc_do;
wire [7:0] sdc_img_mounted;
wire [63:0] sdc_img_size;

wire wr_any = mem_wr | io_wr;
reg wr_d = 1'b0;
always @(posedge clk)
	wr_d <= wr_any;
wire wr_p = wr_any & ~wr_d;   // one clock at the start of a write

// the latches: writes to F8xx.. or the ports F8.. of the Z80
wire mw = mem_wr && !full;
wire lat_f8 = (mw && a[15:8] == 8'hF8) || (io_wr && a[7:0] == 8'hF8);
wire lat_f9 = (mw && a[15:8] == 8'hF9) || (io_wr && a[7:0] == 8'hF9);
wire lat_fa = (mw && a[15:8] == 8'hFA) || (io_wr && a[7:0] == 8'hFA);
wire lat_fb = z80 && ((mw && a[15:8] == 8'hFB) || (io_wr && a[7:0] == 8'hFB));
wire lat_fc = z80 && ((mw && a[15:8] == 8'hFC) || (io_wr && a[7:0] == 8'hFC));
wire lat_fe = z80 && io_wr && a[7:0] == 8'hFE;
wire lat_ff = z80 && io_wr && a[7:0] == 8'hFF;

reg [7:0] vmode = 8'd0;       // port F8: D3..0 the mode, D7 screen of 480 points
reg [7:0] pfa = 8'd0;         // port FA: D1..0 the screen, D7 screen of 512 points
reg [3:0] mbank = 4'd0;       // port F9: the page of 64 KB
reg [7:0] pfc = 8'd0;         // port FC: the colours of the pseudocolour mode
reg [4:0] pfe = 5'd0;         // port FE: D3..0 the page of the ROM disk, D4 sound
reg snd_ff = 1'b0;            // toggled by a write to port FF
// port FB, Z80 Card II: D7 = 0 the dispatcher: 0000-3FFF is the segment D1..0 of page D3..2;
// D6 interrupts, D5 all RAM
reg [7:0] fb = 8'h80;

always @(posedge clk) begin
	if (run_reset) begin
		vmode <= 8'd0;
		pfa <= 8'd0;
		mbank <= 4'd0;
		pfc <= 8'd0;
		pfe <= 5'd0;
		snd_ff <= 1'b0;
		fb <= 8'h80;
	end
	else if (wr_p) begin
		if (lat_f8) vmode <= cpu_do;
		if (lat_f9) mbank <= cpu_do[3:0];
		if (lat_fa) pfa <= cpu_do;
		if (lat_fb) fb <= cpu_do;
		if (lat_fc) pfc <= cpu_do;
		if (lat_fe) pfe <= cpu_do[4:0];
		if (lat_ff) snd_ff <= ~snd_ff;
	end
end

assign beep = z80 ? (pfe[4] ^ snd_ff) : inte;

// the interrupt of the Z80 Card: 50 Hz, the line is held until the Z80 takes it or 64 states of
// 2.5 MHz later
reg [19:0] tick = 20'd0;
reg [10:0] int_hold = 11'd0;
always @(posedge clk) begin
	tick <= (tick == 20'd799999) ? 20'd0 : tick + 20'd1;
	if (run_reset || inta || !fb[6])
		int_hold <= 11'd0;
	else if (tick == 20'd0)
		int_hold <= 11'd1024;
	else if (int_hold != 11'd0)
		int_hold <= int_hold - 11'd1;
end
assign int_n = !(z80 && int_hold != 11'd0);

// the Monitor everywhere after reset
reg ipl = 1'b1;
always @(posedge clk)
	if (run_reset)
		ipl <= 1'b1;
	else if (mem_rd && top_f800)
		ipl <= 1'b0;

// ------------------------------------------------------------------ the PPIs
wire [7:0] ppi4_do, ppi5_do, ppi6_do;
wire [7:0] rd_pb, rd_pc;
wire rd_pa_in, us_pa_in;
wire [7:0] rd_pa, us_pa, us_pb, us_pc;
wire [7:0] ide_hi, ide_lo;
wire [7:0] sram_do;
wire [7:0] kb_scan, kb_ret;
wire [3:0] kb_pc;

orion_kbd kbd (
	.clk(clk), .reset(run_reset), .ms7007(kb_ms7007), .scancode(kb_scancode), .scancode_upd(kb_scancode_upd),
	.scan(kb_scan), .ret(kb_ret), .pc_hi(kb_pc)
);

orion_ppi ppi_kbd (
	.clk(clk), .reset(run_reset), .a(a[1:0]), .wr(wr_p & mem_wr & sel_f4), .din(cpu_do), .dout(ppi4_do),
	.pa_i(8'hFF), .pb_i(kb_ret), .pc_i({kb_pc, 4'hF}),
	.pa_in(), .pa_o(kb_scan), .pb_o(), .pc_o()
);

// the ROM disk: B and C are the address, A the byte; or the IDE (orion_ide), with A as an output
orion_ppi ppi_rd (
	.clk(clk), .reset(run_reset), .a(a[1:0]), .wr(wr_p & mem_wr & sel_f5), .din(cpu_do), .dout(ppi5_do),
	.pa_i(sram_do), .pb_i(ide_hi), .pc_i(ide_lo),
	.pa_in(rd_pa_in), .pa_o(rd_pa), .pb_o(rd_pb), .pc_o(rd_pc)
);

// the user port: the IDE of DSDOS
orion_ppi ppi_usr (
	.clk(clk), .reset(run_reset), .a(a[1:0]), .wr(wr_p & mem_wr & sel_f6), .din(cpu_do), .dout(ppi6_do),
	.pa_i(8'hFF), .pb_i(ide_hi), .pc_i(ide_lo),
	.pa_in(us_pa_in), .pa_o(us_pa), .pb_o(us_pb), .pc_o(us_pc)
);

// ------------------------------------------------------------------ the memory
wire disp = z80 && !fb[7] && a[15:14] == 2'b00;
wire [1:0] page_mask_hi = ram_size == 2'd0 ? 2'b00 : ram_size == 2'd1 ? 2'b01 : 2'b11;
wire [3:0] bank = mbank & { page_mask_hi, 2'b11 };
wire [3:0] page = disp ? { 2'b00, fb[3:2] } :
                  (!full && a[15:12] == 4'hF) ? 4'd0 : bank;  // F000-F3FF: always page 0
wire [15:0] ram_a = disp ? { fb[1:0], a[13:0] } : a;
wire [21:0] ram_addr = { 2'd0, page[3:1], ram_a, page[0] };

wire sel_rom = !mem_wr && !full && (ipl || top_f800);
wire sel_rd = sel_f5 && a[1:0] == 2'd0;

wire [21:0] sram_addr = sel_rom ? { 11'b10000000000, a[10:0] } :
                        sel_rd  ? { 2'b01, pfe[3:0], rd_pc, rd_pb } :
                        ram_addr;
wire sram_we = mem_wr && !sel_dev && !top_f800;

always @* begin
	cpu_di = 8'hFF;
	if (mem_rd) begin
		if (sel_rom) cpu_di = sram_do;
		else if (sel_f4) cpu_di = ppi4_do;
		else if (sel_f5) cpu_di = ppi5_do;
		else if (sel_f6) cpu_di = ppi6_do;
		else if (sel_rtc_a) cpu_di = rtc_ar;
		else if (sel_rtc_d) cpu_di = rtc_do;
		else if (sel_ay_mem && a[0]) cpu_di = ay_do;
		else if (sel_fdc) cpu_di = fdc_do;
		else if (sel_rgu) cpu_di = { 6'd0, fdc_drq, 1'b0 };
		else if (!sel_dev) cpu_di = sram_do;
	end
	else if (io_rd && a[7:0] == 8'hFB)
		cpu_di = fb;
	else if (io_rd && ay_io && a[14])
		cpu_di = ay_do;
end

// ------------------------------------------------------------------ the clock
// the registers of the mcu (kg_mcu_rtc): a write is a clock long
always @(posedge clk)
	if (wr_p && mem_wr && sel_rtc_a)
		rtc_ar <= cpu_do;
assign rtc_a = rtc_ar;
assign rtc_di = cpu_do;
assign rtc_cs = wr_p && mem_wr && sel_rtc_d;
assign rtc_wr_n = !rtc_cs;

// ------------------------------------------------------------------ AY
// 1.75 MHz: 3.5 MHz of 40 (+7 of 80) divided by jt49
reg [6:0] ay_acc = 7'd0;
reg ay_ce = 1'b0;
always @(posedge clk) begin
	ay_ce <= ay_acc >= 7'd73;
	ay_acc <= (ay_acc >= 7'd73) ? ay_acc + 7'd7 - 7'd80 : ay_acc + 7'd7;
end

reg [3:0] ay_reg = 4'd0;
wire ay_wr_reg = wr_p && ((io_wr && ay_io && a[14]) || (mem_wr && sel_ay_mem && a[0]));
wire ay_wr_data = wr_p && ((io_wr && ay_io && !a[14]) || (mem_wr && sel_ay_mem && !a[0]));
always @(posedge clk)
	if (run_reset)
		ay_reg <= 4'd0;
	else if (ay_wr_reg)
		ay_reg <= cpu_do[3:0];

jt49 ay (
	.rst_n(~run_reset),
	.clk(clk),
	.clk_en(ay_ce),
	.addr(ay_reg),
	.cs_n(1'b0),
	.wr_n(~ay_wr_data),
	.din(cpu_do),
	.sel(1'b0),
	.dout(ay_do),
	.sound(ay_sound),
	.A(),
	.B(),
	.C(),
	.sample(),
	.IOA_in(8'hFF),
	.IOA_out(),
	.IOB_in(8'hFF),
	.IOB_out()
);

// ------------------------------------------------------------------ the hard disks
wire [1:0] hd_rd, hd_wr;
wire [31:0] hd_sector;
wire [7:0] hd_byte_out;
wire sdc_hd = sdc_slot[2:1] == 2'b11;

orion_ide ide (
	.clk(clk),
	.reset(run_reset),
	.f5_on(!rd_pa_in),
	.f5_ctl(rd_pa),
	.f5_hi(rd_pb),
	.f5_lo(rd_pc),
	.f6_on(!us_pa_in),
	.f6_ctl(us_pa),
	.f6_hi(us_pb),
	.f6_lo(us_pc),
	.do_hi(ide_hi),
	.do_lo(ide_lo),
	.img_mounted(sdc_img_mounted[7:6]),
	.img_size(sdc_img_size),
	.sdc_rd(hd_rd),
	.sdc_wr(hd_wr),
	.sdc_sector(hd_sector),
	.sdc_busy(sdc_busy && sdc_hd),
	.sdc_done(sdc_done && sdc_hd),
	.sdc_error(sdc_error && sdc_hd),
	.sdc_byte_in_strobe(sdc_in_strobe && sdc_hd),
	.sdc_byte_addr(sdc_byte_addr),
	.sdc_byte_in_data(sdc_in_data),
	.sdc_byte_out_data(hd_byte_out)
);

// ------------------------------------------------------------------ the disk drive
// KR1818VG93 at F700-F703, F710-F713 (an incomplete decoder), the control register at F704, F714,
// F720: D0 the drive, D4 the side, inverted. Read, the control register shows DRQ in D1.
// F708, F718 is the same register of the controller by M. Korotkin: D0 the side, D1 the drive
// (DSDOS writes there when F704 does not read FF).
assign sel_fdc = sel_f7 && a[7:5] == 3'd0 && a[3:2] == 2'd0;
assign sel_rgu = sel_f7 && (a[7:0] == 8'h20 || (a[7:5] == 3'd0 && a[3:0] == 4'd4));
wire sel_rgk = sel_f7 && a[7:5] == 3'd0 && a[3:0] == 4'd8;

reg [7:0] rgu = 8'd0;
always @(posedge clk)
	if (run_reset)
		rgu <= 8'd0;
	else if (wr_p && mem_wr && sel_rgu)
		rgu <= cpu_do;
	else if (wr_p && mem_wr && sel_rgk)
		rgu <= { 3'd0, ~cpu_do[0], 3'd0, cpu_do[1] };

// 5 MHz: a read of the Z80 at 10 MHz lasts 250 ns
reg [2:0] fdc_div = 3'd0;
always @(posedge clk)
	fdc_div <= fdc_div + 3'd1;

wire drive = rgu[0];
reg disk_a = 1'b0, disk_b = 1'b0;
always @(posedge clk) begin
	if (sdc_img_mounted[4]) disk_a <= |sdc_img_size[31:0];
	if (sdc_img_mounted[5]) disk_b <= |sdc_img_size[31:0];
end

wire [31:0] sd_lba;
wire sd_rd, sd_wr, sd_ack_a, sd_ack_b, sd_wr_a, sd_wr_b;
wire [8:0] sd_addr_a, sd_addr_b;
wire [7:0] sd_do_a, sd_do_b, sd_buff_din;

wd1793 #(.RWMODE(1), .EDSK(0)) fdc (
	.clk_sys(clk),
	.ce(fdc_div == 3'd0),
	.reset(run_reset),
	.io_en(sel_fdc),
	.rd(mem_rd),
	.wr(mem_wr),
	.addr(a[1:0]),
	.din(cpu_do),
	.dout(fdc_do),
	.drq(fdc_drq),
	.intrq(),
	.busy(),
	.wp(drive ? img_wp[5] : img_wp[4]),
	.size_code(3'd3),         // 5 sectors of 1024 bytes
	.layout(1'b0),            // track, side, sector
	.side(~rgu[4]),
	.ready(drive ? disk_b : disk_a),
	.img_mounted(sdc_img_mounted[4] | sdc_img_mounted[5]),
	.img_size(sdc_img_size[19:0]),
	.prepare(),
	.sd_lba(sd_lba),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack_a | sd_ack_b),
	.sd_buff_addr(drive ? sd_addr_b : sd_addr_a),
	.sd_buff_dout(drive ? sd_do_b : sd_do_a),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_wr_a | sd_wr_b),
	.input_active(1'b0),
	.input_addr(20'd0),
	.input_data(8'd0),
	.input_wr(1'b0),
	.buff_addr(),
	.buff_read(),
	.buff_din(8'd0)
);

wire aux_req, aux_we, aux_ack;
wire [21:0] aux_addr;
wire [7:0] aux_din, aux_dout;

wire [7:0] sdc_byte_out_a, sdc_byte_out_b;
wire [31:0] sdc_sector_a, sdc_sector_b;
wire sdc_rd_a, sdc_wr_a, sdc_rd_b, sdc_wr_b;

// no reset: a reset of the machine during a request leaves img_sdc to finish it
img_sdc #(
	.OUT_LATENCY(3),
	.TIMEOUT(24'd8000000)     // 200 ms at 40 MHz
) sdc (
	.clk(clk),
	.reset(1'b0),
	.img_mounted(img_mounted),
	.img_size(img_size),
	.img_data_wr(img_data_wr),
	.img_data_addr(img_data_addr),
	.img_data(img_data),
	.img_result_wr(img_result_wr),
	.img_result(img_result),
	.img_sum(img_sum),
	.img_q_wr(img_q_wr),
	.img_q_di(img_q_di),
	.img_q_ack(img_q_ack),
	.sdc_img_mounted(sdc_img_mounted),
	.sdc_img_size(sdc_img_size),
	.sdc_rd({ hd_rd, sdc_rd_b, sdc_rd_a, 4'd0 }),
	.sdc_wr({ hd_wr, sdc_wr_b, sdc_wr_a, 4'd0 }),
	.sdc_sector((sdc_rd_a || sdc_wr_a) ? sdc_sector_a : (sdc_rd_b || sdc_wr_b) ? sdc_sector_b : hd_sector),
	.sdc_busy(sdc_busy),
	.sdc_done(sdc_done),
	.sdc_error(sdc_error),
	.sdc_slot(sdc_slot),
	.sdc_byte_in_strobe(sdc_in_strobe),
	.sdc_byte_addr(sdc_byte_addr),
	.sdc_byte_in_data(sdc_in_data),
	.sdc_byte_out_data(sdc_hd ? hd_byte_out : sdc_slot == 3'd5 ? sdc_byte_out_b : sdc_byte_out_a),
	.active()
);

wire fd_req_a, fd_we_a, fd_req_b, fd_we_b, ld_req, ld_we;
wire [21:0] fd_addr_a, fd_addr_b, ld_addr;
wire [7:0] fd_din_a, fd_din_b, ld_din;
reg [1:0] own = 2'd0;         // the aux port: 1 loader, 2 disk A, 3 disk B
wire loading = rom_active | file_active;

orion_fdd_cache #(.BASE(22'h240000), .SLOT(3'd4)) cache_a (
	.clk(clk),
	.img_mounted(sdc_img_mounted[4]),
	.img_size(sdc_img_size[31:0]),
	.sd_rd(sd_rd & ~drive),
	.sd_wr(sd_wr & ~drive),
	.sd_lba(sd_lba),
	.sd_ack(sd_ack_a),
	.sd_buff_addr(sd_addr_a),
	.sd_buff_dout(sd_do_a),
	.sd_buff_wr(sd_wr_a),
	.sd_buff_din(sd_buff_din),
	.sdc_rd(sdc_rd_a),
	.sdc_wr(sdc_wr_a),
	.sdc_sector(sdc_sector_a),
	.sdc_busy(sdc_busy),
	.sdc_done(sdc_done),
	.sdc_error(sdc_error),
	.sdc_slot(sdc_slot),
	.sdc_byte_in_strobe(sdc_in_strobe),
	.sdc_byte_addr(sdc_byte_addr),
	.sdc_byte_in_data(sdc_in_data),
	.sdc_byte_out_data(sdc_byte_out_a),
	.pause(loading),
	.aux_req(fd_req_a),
	.aux_we(fd_we_a),
	.aux_addr(fd_addr_a),
	.aux_din(fd_din_a),
	.aux_ack(aux_ack && own == 2'd2),
	.aux_dout(aux_dout),
	.filling(),
	.filled()
);

orion_fdd_cache #(.BASE(22'h30D000), .SLOT(3'd5)) cache_b (
	.clk(clk),
	.img_mounted(sdc_img_mounted[5]),
	.img_size(sdc_img_size[31:0]),
	.sd_rd(sd_rd & drive),
	.sd_wr(sd_wr & drive),
	.sd_lba(sd_lba),
	.sd_ack(sd_ack_b),
	.sd_buff_addr(sd_addr_b),
	.sd_buff_dout(sd_do_b),
	.sd_buff_wr(sd_wr_b),
	.sd_buff_din(sd_buff_din),
	.sdc_rd(sdc_rd_b),
	.sdc_wr(sdc_wr_b),
	.sdc_sector(sdc_sector_b),
	.sdc_busy(sdc_busy),
	.sdc_done(sdc_done),
	.sdc_error(sdc_error),
	.sdc_slot(sdc_slot),
	.sdc_byte_in_strobe(sdc_in_strobe),
	.sdc_byte_addr(sdc_byte_addr),
	.sdc_byte_in_data(sdc_in_data),
	.sdc_byte_out_data(sdc_byte_out_b),
	.pause(loading),
	.aux_req(fd_req_b),
	.aux_we(fd_we_b),
	.aux_addr(fd_addr_b),
	.aux_din(fd_din_b),
	.aux_ack(aux_ack && own == 2'd3),
	.aux_dout(aux_dout),
	.filling(),
	.filled()
);

// a master holds its request until the ack and drops it at that edge
always @(posedge clk) begin
	if (aux_ack)
		own <= 2'd0;
	else if (own == 2'd0)
		own <= ld_req ? 2'd1 : fd_req_a ? 2'd2 : fd_req_b ? 2'd3 : 2'd0;
end
assign aux_req = own == 2'd1 ? ld_req : own == 2'd2 ? fd_req_a : own == 2'd3 ? fd_req_b : 1'b0;
assign aux_we = own == 2'd1 ? ld_we : own == 2'd2 ? fd_we_a : fd_we_b;
assign aux_addr = own == 2'd1 ? ld_addr : own == 2'd2 ? fd_addr_a : fd_addr_b;
assign aux_din = own == 2'd1 ? ld_din : own == 2'd2 ? fd_din_a : fd_din_b;

orion_loader loader (
	.clk(clk),
	.rom_active(rom_active),
	.rom_addr(rom_addr),
	.rom_data(rom_data),
	.rom_wr(rom_wr),
	.file_active(file_active),
	.file_slot(file_slot),
	.file_addr(file_addr),
	.file_data(file_data),
	.file_wr(file_wr),
	.tick(tick == 20'd0),
	.aux_req(ld_req),
	.aux_we(ld_we),
	.aux_addr(ld_addr),
	.aux_din(ld_din),
	.aux_ack(aux_ack && own == 2'd1),
	.aux_dout(aux_dout)
);

wire vid_req, vid_valid;
wire [20:0] vid_addr;
wire [15:0] vid_dout;

orion_video video (
	.clk(clk),
	.vmode(vmode[3:0]),
	.vpage(pfa[1:0]),
	.w512(pfa[7]),
	.w480(vmode[7]),
	.pcolor(pfc),
	.vid_req(vid_req),
	.vid_addr(vid_addr),
	.vid_dout(vid_dout),
	.vid_valid(vid_valid),
	.rgb(rgb),
	.hs(hs),
	.vs(vs),
	.de(de)
);

orion_sram sram (
	.clk(clk),
	.addr(sram_addr),
	.we(sram_we),
	.din(cpu_do),
	.dout(sram_do),
	.rd_ok(rd_ok),
	.aux_req(aux_req),
	.aux_we(aux_we),
	.aux_addr(aux_addr),
	.aux_din(aux_din),
	.aux_ack(aux_ack),
	.aux_dout(aux_dout),
	.vid_req(vid_req),
	.vid_addr(vid_addr),
	.vid_dout(vid_dout),
	.vid_valid(vid_valid),
	.MA(MA),
	.MD(MD),
	.MWR_N(MWR_N)
);

endmodule
