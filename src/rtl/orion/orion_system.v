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

	input wire [7:0] kb_scancode,
	input wire kb_scancode_upd,

	output wire [23:0] rgb,
	output wire hs,
	output wire vs,
	output wire de,

	output wire beep,

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
	.pa_o(kb_scan), .pb_o(), .pc_o()
);

// the ROM disk: B and C are the address, A the byte
orion_ppi ppi_rd (
	.clk(clk), .reset(run_reset), .a(a[1:0]), .wr(wr_p & mem_wr & sel_f5), .din(cpu_do), .dout(ppi5_do),
	.pa_i(sram_do), .pb_i(8'hFF), .pc_i(8'hFF),
	.pa_o(), .pb_o(rd_pb), .pc_o(rd_pc)
);

// the user port, nothing on it yet
orion_ppi ppi_usr (
	.clk(clk), .reset(run_reset), .a(a[1:0]), .wr(wr_p & mem_wr & sel_f6), .din(cpu_do), .dout(ppi6_do),
	.pa_i(8'hFF), .pb_i(8'hFF), .pc_i(8'hFF),
	.pa_o(), .pb_o(), .pc_o()
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
		else if (!sel_dev) cpu_di = sram_do;
	end
	else if (io_rd && a[7:0] == 8'hFB)
		cpu_di = fb;
end

wire aux_req, aux_we, aux_ack;
wire [21:0] aux_addr;
wire [7:0] aux_din, aux_dout;

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
	.aux_req(aux_req),
	.aux_we(aux_we),
	.aux_addr(aux_addr),
	.aux_din(aux_din),
	.aux_ack(aux_ack),
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
