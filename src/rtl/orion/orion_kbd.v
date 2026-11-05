`timescale 1ns / 1ps
`default_nettype wire

/*
 orion_kbd.v

 The PS/2 set 2 scancodes of kg_mcu as the RK-86 keyboard of the Orion: a matrix of 8 columns,
 scan is port A of the PPI (0 = column read), ret its port B (0 = pressed), and three lines on
 the high half of port C: { RUS/LAT (Caps Lock), US (Ctrl), SS (Shift), 1 }, all active low.

 The layout is that of orion2010-zxuno (orionkeyboard.v). A column of the matrix is entry 0, 7, 6 .. 1
 of its table for scan bits 0, 1, 2 .. 7, as there.
*/

module orion_kbd (
	input wire clk,
	input wire reset,
	input wire [7:0] scancode,
	input wire scancode_upd,    // toggles with each byte
	input wire [7:0] scan,
	output wire [7:0] ret,
	output wire [3:0] pc_hi
);

reg upd_d = 1'b0;
reg ext = 1'b0, rel = 1'b0;
reg ss = 1'b0, us = 1'b0, rl = 1'b0;
reg [63:0] km = 64'd0;        // { entry, bit }

reg [6:0] pos;                // { valid, entry, bit }
always @* begin
	case ({ ext, scancode })
		9'h16C: pos = 7'o100;  // Home
		9'h171: pos = 7'o101;  // Delete
		9'h076: pos = 7'o102;  // Esc
		9'h005: pos = 7'o103;  // F1
		9'h006: pos = 7'o104;  // F2
		9'h004: pos = 7'o105;  // F3
		9'h00C: pos = 7'o106;  // F4
		9'h003: pos = 7'o107;  // F5
		9'h022: pos = 7'o110;  // X
		9'h035: pos = 7'o111;  // Y
		9'h01A: pos = 7'o112;  // Z
		9'h054: pos = 7'o113;  // [
		9'h05D: pos = 7'o114;  // backslash
		9'h05B: pos = 7'o115;  // ]
		9'h00E: pos = 7'o116;  // `
		9'h029: pos = 7'o117;  // Space
		9'h04D: pos = 7'o120;  // P
		9'h015: pos = 7'o121;  // Q
		9'h02D: pos = 7'o122;  // R
		9'h01B: pos = 7'o123;  // S
		9'h02C: pos = 7'o124;  // T
		9'h03C: pos = 7'o125;  // U
		9'h02A: pos = 7'o126;  // V
		9'h01D: pos = 7'o127;  // W
		9'h033: pos = 7'o130;  // H
		9'h043: pos = 7'o131;  // I
		9'h03B: pos = 7'o132;  // J
		9'h042: pos = 7'o133;  // K
		9'h04B: pos = 7'o134;  // L
		9'h03A: pos = 7'o135;  // M
		9'h031: pos = 7'o136;  // N
		9'h044: pos = 7'o137;  // O
		9'h052: pos = 7'o140;  // '
		9'h01C: pos = 7'o141;  // A
		9'h032: pos = 7'o142;  // B
		9'h021: pos = 7'o143;  // C
		9'h023: pos = 7'o144;  // D
		9'h024: pos = 7'o145;  // E
		9'h02B: pos = 7'o146;  // F
		9'h034: pos = 7'o147;  // G
		9'h03E, 9'h075: pos = 7'o150;  // 8
		9'h046, 9'h07D: pos = 7'o151;  // 9
		9'h04C, 9'h07C: pos = 7'o152;  // ; (keypad *)
		9'h04E, 9'h079: pos = 7'o153;  // - (keypad +)
		9'h041: pos = 7'o154;          // ,
		9'h055, 9'h07B: pos = 7'o155;  // = (keypad -)
		9'h049, 9'h071: pos = 7'o156;  // .
		9'h04A, 9'h14A: pos = 7'o157;  // /
		9'h045, 9'h070: pos = 7'o160;  // 0
		9'h016, 9'h069: pos = 7'o161;  // 1
		9'h01E, 9'h072: pos = 7'o162;  // 2
		9'h026, 9'h07A: pos = 7'o163;  // 3
		9'h025, 9'h06B: pos = 7'o164;  // 4
		9'h02E, 9'h073: pos = 7'o165;  // 5
		9'h036, 9'h074: pos = 7'o166;  // 6
		9'h03D, 9'h06C: pos = 7'o167;  // 7
		9'h00D: pos = 7'o170;          // Tab
		9'h170: pos = 7'o171;          // Insert
		9'h05A, 9'h15A: pos = 7'o172;  // Enter
		9'h066: pos = 7'o173;          // Backspace
		9'h16B: pos = 7'o174;          // Left
		9'h175: pos = 7'o175;          // Up
		9'h174: pos = 7'o176;          // Right
		9'h172: pos = 7'o177;          // Down
		default: pos = 7'o000;
	endcase
end

always @(posedge clk) begin
	upd_d <= scancode_upd;
	if (reset) begin
		ext <= 1'b0;
		rel <= 1'b0;
		ss <= 1'b0;
		us <= 1'b0;
		rl <= 1'b0;
		km <= 64'd0;
	end
	else if (scancode_upd != upd_d) begin
		if (scancode == 8'hE0)
			ext <= 1'b1;
		else if (scancode == 8'hF0)
			rel <= 1'b1;
		else begin
			ext <= 1'b0;
			rel <= 1'b0;
			if ({ ext, scancode } == 9'h012 || { ext, scancode } == 9'h059)
				ss <= ~rel;
			else if (scancode == 8'h14)      // both Ctrl keys
				us <= ~rel;
			else if ({ ext, scancode } == 9'h058)
				rl <= ~rel;
			else if (pos[6])
				km[pos[5:0]] <= ~rel;
		end
	end
end

function [7:0] col;
	input [2:0] e;
	col = { km[{ e, 3'd7 }], km[{ e, 3'd6 }], km[{ e, 3'd5 }], km[{ e, 3'd4 }],
	        km[{ e, 3'd3 }], km[{ e, 3'd2 }], km[{ e, 3'd1 }], km[{ e, 3'd0 }] };
endfunction

assign ret = ~( (scan[0] ? 8'd0 : col(3'd0)) | (scan[1] ? 8'd0 : col(3'd7)) |
                (scan[2] ? 8'd0 : col(3'd6)) | (scan[3] ? 8'd0 : col(3'd5)) |
                (scan[4] ? 8'd0 : col(3'd4)) | (scan[5] ? 8'd0 : col(3'd3)) |
                (scan[6] ? 8'd0 : col(3'd2)) | (scan[7] ? 8'd0 : col(3'd1)) );
assign pc_hi = { ~rl, ~us, ~ss, 1'b1 };

endmodule
