`timescale 1ns / 1ps
`default_nettype wire

/*
 orion_cpu.v

 The processor of the machine as one bus: KR580VM80A (vm80a, a cycle accurate model) or Z80
 (T80pa), picked by cpu_z80, the other one is held in reset. Change cpu_z80 only during reset.

 Sixteen clocks of 40 MHz are one state of 400 ns (2.5 MHz). vm80a takes its phases as enables of
 the fast clock: F1 is high for 4 clocks, F2 for 10, with a gap of one clock (the two phases of
 a real 8080 do not overlap). T80pa takes the two edges of its clock as enables.

 The 8080 has no IORQ: OUT n and IN n appear as a write and a read of the address {n, n}, which is
 what the Orion decodes (port F8 is the latch at F800). So io_rd / io_wr come only from the Z80.
*/

module orion_cpu (
	input wire clk,
	input wire reset,
	input wire cpu_z80,

	output wire [15:0] addr,
	output wire [7:0] dout,
	input wire [7:0] din,
	output wire mem_rd,
	output wire mem_wr,
	output wire io_rd,
	output wire io_wr,

	input wire int_n,
	output wire inte     // the INTE pin of the 8080: the beeper of the Monitor; 0 on the Z80
);

reg [3:0] cnt = 4'd0;
reg f1 = 1'b0, f2 = 1'b0;
always @(posedge clk) begin
	cnt <= cnt + 4'd1;
	f1 <= cnt[3:2] == 2'b00;
	f2 <= cnt >= 4'd5 && cnt <= 4'd14;
end

// ------------------------------------------------------------------ KR580VM80A
wire [15:0] a_80;
wire [7:0] do_80;
wire dbin_80, wr_n_80, inte_80;

vm80a_core cpu80 (
	.pin_clk(clk),
	.pin_f1(f1),
	.pin_f2(f2),
	.pin_reset(reset | cpu_z80),
	.pin_a(a_80),
	.pin_dout(do_80),
	.pin_din(din),
	.pin_aena(),
	.pin_dena(),
	.pin_hold(1'b0),
	.pin_hlda(),
	.pin_ready(1'b1),
	.pin_wait(),
	.pin_int(~int_n),
	.pin_inte(inte_80),
	.pin_sync(),
	.pin_dbin(dbin_80),
	.pin_wr_n(wr_n_80)
);

// ------------------------------------------------------------------ Z80
wire [15:0] a_z80;
wire [7:0] do_z80;
wire mreq_n, iorq_n, rd_n, wr_n;

T80pa #(.Mode(0)) cpuz80 (
	.RESET_n(~reset & cpu_z80),
	.CLK(clk),
	.CEN_p(cnt == 4'd15),
	.CEN_n(cnt == 4'd7),
	.WAIT_n(1'b1),
	.INT_n(int_n),
	.NMI_n(1'b1),
	.BUSRQ_n(1'b1),
	.M1_n(),
	.MREQ_n(mreq_n),
	.IORQ_n(iorq_n),
	.RD_n(rd_n),
	.WR_n(wr_n),
	.RFSH_n(),
	.HALT_n(),
	.BUSAK_n(),
	.OUT0(1'b0),
	.A(a_z80),
	.DI(din),
	.DO(do_z80),
	.REG(),
	.DIRSet(1'b0),
	.DIR(212'd0)
);

assign addr = cpu_z80 ? a_z80 : a_80;
assign dout = cpu_z80 ? do_z80 : do_80;
assign mem_rd = cpu_z80 ? ~mreq_n & ~rd_n : dbin_80;
assign mem_wr = cpu_z80 ? ~mreq_n & ~wr_n : ~wr_n_80;
assign io_rd = cpu_z80 & ~iorq_n & ~rd_n;
assign io_wr = cpu_z80 & ~iorq_n & ~wr_n;
assign inte = ~cpu_z80 & inte_80;

endmodule
