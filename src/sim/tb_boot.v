`timescale 1ns / 1ps
`default_nettype wire

// orion_system with a model of the SRAM (two lanes of 2M x 8, /OE low, as msx tb_sys), for sim_boot.
module tb_boot (
	input wire clk,
	input wire reset,
	input wire cpu_z80,
	input wire rom_active,
	input wire [21:0] rom_addr,
	input wire [7:0] rom_data,
	input wire rom_wr,
	input wire [7:0] kb_in,
	input wire [3:0] kb_c_i,
	output wire [7:0] kb_scan,
	output wire [3:0] vmode,
	output wire [1:0] vpage,
	output wire beep,
	input wire [21:0] dbg_addr,
	output wire [7:0] dbg_q
);

wire [20:0] MA;
wire [15:0] MD;
wire [1:0] MWR_N;

orion_system sys (
	.clk(clk), .reset(reset), .cpu_z80(cpu_z80),
	.rom_active(rom_active), .rom_addr(rom_addr), .rom_data(rom_data), .rom_wr(rom_wr),
	.kb_scan(kb_scan), .kb_in(kb_in), .kb_c_o(), .kb_c_i(kb_c_i),
	.vmode(vmode), .vpage(vpage), .beep(beep),
	.MA(MA), .MD(MD), .MWR_N(MWR_N)
);

reg [7:0] lo [0:2097151];
reg [7:0] hi [0:2097151];
assign MD = (MWR_N == 2'b11) ? { hi[MA], lo[MA] } : 16'bz;
assign dbg_q = dbg_addr[0] ? hi[dbg_addr[21:1]] : lo[dbg_addr[21:1]];

always @(posedge clk) begin
	if (!MWR_N[0]) lo[MA] <= MD[7:0];
	if (!MWR_N[1]) hi[MA] <= MD[15:8];
end

endmodule
