`timescale 1ns / 1ps
`default_nettype wire

/*
 orion_video.v

 The screen of the Orion read straight from the SRAM as VESA 800 x 600 at 60 Hz (40.0 MHz, 1056 x
 628, positive syncs), no frame buffer. A point of the Orion is 2 x 2 output pixels: the picture
 of 384 x 256 is 768 x 512 in the middle (x 16..783, y 44..555), the rest is black.

 A cell of 8 points is 16 clocks. Its 16-bit read (pixels in page 0, colours in page 1, the two
 lanes of one SRAM address) is asked 16 clocks before the cell starts, and the word is loaded into
 the shift registers at the start of the cell. orion_sram answers within 6 clocks.

 The screen address {~vpage, column, row}: screen 0 at C000. vmode D2..0 as written to port F8:
 000 mono, 001 mono palette 2, 01x blank, 100 / 101 four colours, 11x sixteen colours by cells
 (pixel 1: low tetrade of the colour byte, 0: high). Colour bits are IRGB. The sources differ in
 the palettes 2 and the brightness, see docs/BACKLOG.md.
*/

module orion_video (
	input wire clk,
	input wire [2:0] vmode,
	input wire [1:0] vpage,

	output wire vid_req,
	output wire [20:0] vid_addr,
	input wire [15:0] vid_dout,
	input wire vid_valid,

	output reg [23:0] rgb = 24'd0,
	output reg hs = 1'b0,
	output reg vs = 1'b0,
	output reg de = 1'b0
);

parameter H_TOTAL = 1056, H_VISIBLE = 800, H_SYNC = 840, H_SYNC_END = 968;
parameter V_TOTAL = 628, V_VISIBLE = 600, V_SYNC = 601, V_SYNC_END = 605;
parameter V_TOP = 44;     // the first line of the picture

reg [10:0] hcnt = 11'd0;
reg [9:0] vcnt = 10'd0;
always @(posedge clk) begin
	if (hcnt == H_TOTAL - 1) begin
		hcnt <= 11'd0;
		vcnt <= (vcnt == V_TOTAL - 1) ? 10'd0 : vcnt + 10'd1;
	end
	else
		hcnt <= hcnt + 11'd1;
end

wire [9:0] vrel = vcnt - V_TOP;
wire in_y = vcnt >= V_TOP && vcnt < V_TOP + 512;
wire [7:0] row = vrel[8:1];
wire [5:0] col = hcnt[9:4];
wire cell_start = hcnt[3:0] == 4'd0;

assign vid_req = in_y && cell_start && hcnt < 11'd768;      // cells 0..47
assign vid_addr = { 5'd0, ~vpage, col, row };

reg [15:0] hold = 16'd0;
always @(posedge clk)
	if (vid_valid)
		hold <= vid_dout;

// the cell 0 starts at x = 16: the word asked at hcnt = 0 is loaded at hcnt = 16
wire show = in_y && hcnt >= 11'd16 && hcnt < 11'd784;
reg [7:0] pix = 8'd0, cpl = 8'd0, attr = 8'd0;
always @(posedge clk) begin
	if (cell_start) begin
		pix <= show ? hold[7:0] : 8'd0;
		cpl <= show ? hold[15:8] : 8'd0;
		attr <= show ? hold[15:8] : 8'd0;
	end
	else if (hcnt[0] == 1'b0) begin
		pix <= { pix[6:0], 1'b0 };
		cpl <= { cpl[6:0], 1'b0 };
	end
end

reg [3:0] code;
always @* begin
	case (vmode)
		3'b000: code = pix[7] ? 4'hA : 4'h0;
		3'b001: code = pix[7] ? 4'hE : 4'h9;
		3'b100: case ({ pix[7], cpl[7] })
				2'b00: code = 4'h0;
				2'b01: code = 4'hC;
				2'b10: code = 4'hA;
				2'b11: code = 4'h9;
			endcase
		3'b101: case ({ pix[7], cpl[7] })
				2'b00: code = 4'hB;
				2'b01: code = 4'hF;
				2'b10: code = 4'hE;
				2'b11: code = 4'hD;
			endcase
		3'b110, 3'b111: code = pix[7] ? attr[3:0] : attr[7:4];
		default: code = 4'h0;
	endcase
end

wire [7:0] level = code[3] ? 8'hFF : 8'hAA;

// the pixel of hcnt is out two clocks later: the shift register, then rgb
reg de_d = 1'b0, hs_d = 1'b0, vs_d = 1'b0;
always @(posedge clk) begin
	de_d <= hcnt < H_VISIBLE && vcnt < V_VISIBLE;
	hs_d <= hcnt >= H_SYNC && hcnt < H_SYNC_END;
	vs_d <= vcnt >= V_SYNC && vcnt < V_SYNC_END;
	de <= de_d;
	hs <= hs_d;
	vs <= vs_d;
	rgb <= { code[2] ? level : 8'd0, code[1] ? level : 8'd0, code[0] ? level : 8'd0 };
end

endmodule
