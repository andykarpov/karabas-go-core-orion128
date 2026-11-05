`timescale 1ns / 1ps
`default_nettype wire

/*
 orion_system.v

 The Orion-128: the processor, the memory map, the ports and the SRAM, on one clock of 40 MHz.
 docs/HARDWARE.md has the map. Phase 0: the base machine without video and keyboard, their ports
 (vmode, vpage, kb_*) are here for the next phase.

 SRAM (a byte address of 22 bits, orion_sram):
   000000  RAM: a page of 64 KB is {page[5:1], a[15:0], page[0]}, so pages 0 and 1 are the two
           byte lanes of one address (the video reads pixel and colour in one access)
   100000  ROM disk (64 KB here), read through port A of the PPI at F500
   200000  Monitor (2 KB)
 The ROMs arrive by the ROM loader of the mcu: rom_addr is that byte address, the machine is in
 reset while rom_active.

 After reset the Monitor answers everywhere (a read), until the first read at F800-FFFF: this is
 how a CPU that starts at 0000 finds its code at F800.
*/

module orion_system (
	input wire clk,
	input wire reset,
	input wire cpu_z80,          // change it only during reset

	// the ROM loader of the mcu
	input wire rom_active,
	input wire [21:0] rom_addr,
	input wire [7:0] rom_data,
	input wire rom_wr,

	// the keyboard PPI at F400
	output wire [7:0] kb_scan,   // port A
	input wire [7:0] kb_in,      // port B
	output wire [3:0] kb_c_o,    // port C, low half
	input wire [3:0] kb_c_i,     // port C, high half

	output reg [3:0] vmode = 4'd0,  // port F8
	output reg [1:0] vpage = 2'd0,  // port FA (D1..0), as written
	output wire beep,

	output wire [20:0] MA,
	inout wire [15:0] MD,
	output wire [1:0] MWR_N
);

wire run_reset = reset | rom_active;

wire [15:0] a;
wire [7:0] cpu_do;
reg [7:0] cpu_di;
wire mem_rd, mem_wr, io_rd, io_wr, inte;

orion_cpu cpu (
	.clk(clk),
	.reset(run_reset),
	.cpu_z80(cpu_z80),
	.addr(a),
	.dout(cpu_do),
	.din(cpu_di),
	.mem_rd(mem_rd),
	.mem_wr(mem_wr),
	.io_rd(io_rd),
	.io_wr(io_wr),
	.int_n(1'b1),
	.inte(inte)
);

assign beep = inte;

// ------------------------------------------------------------------ decoding
wire top_f800 = a[15:11] == 5'b11111;
wire sel_dev = a[15:10] == 6'b111101;         // F400-F7FF, a memory access
wire sel_f4 = sel_dev && a[9:8] == 2'd0;
wire sel_f5 = sel_dev && a[9:8] == 2'd1;
wire sel_f6 = sel_dev && a[9:8] == 2'd2;

wire wr_any = mem_wr | io_wr;
reg wr_d = 1'b0;
always @(posedge clk)
	wr_d <= wr_any;
wire wr_p = wr_any & ~wr_d;   // one clock at the start of a write

// the latches: writes to F8xx.. or the ports F8.. of the Z80
wire lat_f8 = (mem_wr && a[15:8] == 8'hF8) || (io_wr && a[7:0] == 8'hF8);
wire lat_f9 = (mem_wr && a[15:8] == 8'hF9) || (io_wr && a[7:0] == 8'hF9);
wire lat_fa = (mem_wr && a[15:8] == 8'hFA) || (io_wr && a[7:0] == 8'hFA);

reg [1:0] mbank = 2'd0;       // port F9: 4 pages, 256 KB
always @(posedge clk) begin
	if (run_reset) begin
		vmode <= 4'd0;
		vpage <= 2'd0;
		mbank <= 2'd0;
	end
	else if (wr_p) begin
		if (lat_f8) vmode <= cpu_do[3:0];
		if (lat_f9) mbank <= cpu_do[1:0];
		if (lat_fa) vpage <= cpu_do[1:0];
	end
end

// the Monitor everywhere after reset
reg ipl = 1'b1;
always @(posedge clk)
	if (run_reset)
		ipl <= 1'b1;
	else if (mem_rd && top_f800)
		ipl <= 1'b0;

// ------------------------------------------------------------------ the PPIs
wire [7:0] ppi4_do, ppi5_do, ppi6_do;
wire [7:0] rd_pb, rd_pc, kb_pc;
wire [7:0] sram_do;

orion_ppi ppi_kbd (
	.clk(clk), .reset(run_reset), .a(a[1:0]), .wr(wr_p & mem_wr & sel_f4), .din(cpu_do), .dout(ppi4_do),
	.pa_i(8'hFF), .pb_i(kb_in), .pc_i({kb_c_i, 4'hF}),
	.pa_o(kb_scan), .pb_o(), .pc_o(kb_pc)
);
assign kb_c_o = kb_pc[3:0];

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
wire [1:0] page = (a[15:12] == 4'hF) ? 2'd0 : mbank;   // F000-F3FF: always page 0
wire [21:0] ram_addr = { 4'd0, page[1], a, page[0] };

wire sel_rom = !mem_wr && (ipl || top_f800);
wire sel_rd = sel_f5 && a[1:0] == 2'd0;

wire [21:0] sram_addr = sel_rom ? { 11'b10000000000, a[10:0] } :
                        sel_rd  ? { 6'b010000, rd_pc, rd_pb } :
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
end

// the ROM loader: a byte waits for its slot, the mcu writes one in ten clocks or less often
reg aux_req = 1'b0;
reg [21:0] aux_addr = 22'd0;
reg [7:0] aux_din = 8'd0;
wire aux_ack;
always @(posedge clk) begin
	if (rom_wr) begin
		aux_req <= 1'b1;
		aux_addr <= rom_addr;
		aux_din <= rom_data;
	end
	else if (aux_ack)
		aux_req <= 1'b0;
end

orion_sram sram (
	.clk(clk),
	.addr(sram_addr),
	.we(sram_we),
	.din(cpu_do),
	.dout(sram_do),
	.aux_req(aux_req),
	.aux_we(1'b1),
	.aux_addr(aux_addr),
	.aux_din(aux_din),
	.aux_ack(aux_ack),
	.aux_dout(),
	.MA(MA),
	.MD(MD),
	.MWR_N(MWR_N)
);

endmodule
