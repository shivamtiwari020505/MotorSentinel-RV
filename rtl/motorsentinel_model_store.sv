`timescale 1ns/1ps

// CRC-protected model store for EdgeMatrix-RV.
//
// Software loads the 122-word image produced by model/edgematrix.py:
//   1. pulse begin_i: the model becomes invalid (the safety policy trips and
//      the motor stays off), the write pointer and CRC-32 are reset;
//   2. write the image in order through data_write_i;
//   3. write the expected CRC and pulse commit_i.
// Commit succeeds only if the length, IEEE CRC-32, format word and every
// parameter range are correct. Any failure leaves the model invalid, so a
// truncated, corrupted or out-of-range model can never drive the motor.
module motorsentinel_model_store (
    input  logic            clk,
    input  logic            rst_n,

    input  logic            begin_i,
    input  logic            commit_i,
    input  logic            data_write_i,
    input  logic [31:0]     data_i,
    input  logic [31:0]     expected_crc_i,

    output logic            model_valid_o,
    output logic            loading_o,
    output logic [7:0]      words_o,
    output logic [31:0]     crc_o,
    output logic [4:0]      error_o,

    output logic [511:0]    offset_o,
    output logic [255:0]    scale_o,
    output logic [95:0]     norm_shift_o,
    output logic [1023:0]   w1_o,
    output logic [1023:0]   w2_o,
    output logic [255:0]    b1_o,
    output logic [511:0]    b2_o,
    output logic [5:0]      s1_o,
    output logic [5:0]      s2_o
);

    localparam logic [31:0] FORMAT_WORD = 32'h4d41_0001;
    localparam integer IMAGE_WORDS = 122;
    localparam integer OFFSET_BASE = 1;
    localparam integer NORM_BASE   = 17;
    localparam integer W1_BASE     = 33;
    localparam integer W2_BASE     = 65;
    localparam integer B1_BASE     = 97;
    localparam integer B2_BASE     = 105;
    localparam integer SHIFT_WORD  = 121;

    localparam integer ERR_CRC      = 0;
    localparam integer ERR_LENGTH   = 1;
    localparam integer ERR_FORMAT   = 2;
    localparam integer ERR_RANGE    = 3;
    localparam integer ERR_SEQUENCE = 4;

    logic [31:0] crc_state_q;
    logic [31:0] format_q;
    logic        range_error_q;
    logic        sequence_error_q;

    // Reflected IEEE 802.3 CRC-32, one 32-bit little-endian word per cycle.
    function automatic logic [31:0] crc32_word(
        input logic [31:0] crc,
        input logic [31:0] data
    );
        integer bit_index;
        logic [31:0] value;
        begin
            value = crc;
            for (bit_index = 0; bit_index < 32; bit_index = bit_index + 1)
                value = (value >> 1) ^
                        ((value[0] ^ data[bit_index]) ? 32'hedb8_8320 : 32'h0);
            crc32_word = value;
        end
    endfunction

    wire [7:0] address = words_o;
    wire in_range_bias = (data_i[31:24] == 8'h00) || (data_i[31:24] == 8'hff);
    wire in_range_norm = (data_i[31:22] == 10'd0) && (data_i[21:16] <= 6'd47);
    wire in_range_shifts = (data_i[31:14] == 18'd0) && (data_i[7:6] == 2'd0) &&
                           (data_i[13:8] <= 6'd24) && (data_i[5:0] <= 6'd24);

    wire commit_ok = loading_o && !sequence_error_q && !range_error_q &&
                     (words_o == IMAGE_WORDS) && (format_q == FORMAT_WORD) &&
                     (~crc_state_q == expected_crc_i);

    assign crc_o = ~crc_state_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            model_valid_o    <= 1'b0;
            loading_o        <= 1'b0;
            words_o          <= '0;
            crc_state_q      <= 32'hffff_ffff;
            format_q         <= '0;
            range_error_q    <= 1'b0;
            sequence_error_q <= 1'b0;
            error_o          <= '0;
            offset_o         <= '0;
            scale_o          <= '0;
            norm_shift_o     <= '0;
            w1_o             <= '0;
            w2_o             <= '0;
            b1_o             <= '0;
            b2_o             <= '0;
            s1_o             <= '0;
            s2_o             <= '0;
        end else if (begin_i) begin
            model_valid_o    <= 1'b0;
            loading_o        <= 1'b1;
            words_o          <= '0;
            crc_state_q      <= 32'hffff_ffff;
            format_q         <= '0;
            range_error_q    <= 1'b0;
            sequence_error_q <= 1'b0;
            error_o          <= '0;
        end else if (commit_i) begin
            loading_o     <= 1'b0;
            model_valid_o <= commit_ok;
            error_o[ERR_CRC]      <= ~crc_state_q != expected_crc_i;
            error_o[ERR_LENGTH]   <= words_o != IMAGE_WORDS;
            error_o[ERR_FORMAT]   <= format_q != FORMAT_WORD;
            error_o[ERR_RANGE]    <= range_error_q;
            error_o[ERR_SEQUENCE] <= sequence_error_q || !loading_o;
        end else if (data_write_i) begin
            if (!loading_o || address >= IMAGE_WORDS) begin
                sequence_error_q <= 1'b1;
            end else begin
                crc_state_q <= crc32_word(crc_state_q, data_i);
                words_o     <= words_o + 1'b1;

                if (address == 0) begin
                    format_q <= data_i;
                end else if (address < NORM_BASE) begin
                    offset_o[(address-OFFSET_BASE)*32 +: 32] <= data_i;
                end else if (address < W1_BASE) begin
                    scale_o[(address-NORM_BASE)*16 +: 16] <= data_i[15:0];
                    norm_shift_o[(address-NORM_BASE)*6 +: 6] <= data_i[21:16];
                    if (!in_range_norm)
                        range_error_q <= 1'b1;
                end else if (address < W2_BASE) begin
                    w1_o[(address-W1_BASE)*32 +: 32] <= data_i;
                end else if (address < B1_BASE) begin
                    w2_o[(address-W2_BASE)*32 +: 32] <= data_i;
                end else if (address < B2_BASE) begin
                    b1_o[(address-B1_BASE)*32 +: 32] <= data_i;
                    if (!in_range_bias)
                        range_error_q <= 1'b1;
                end else if (address < SHIFT_WORD) begin
                    b2_o[(address-B2_BASE)*32 +: 32] <= data_i;
                    if (!in_range_bias)
                        range_error_q <= 1'b1;
                end else begin
                    s1_o <= data_i[5:0];
                    s2_o <= data_i[13:8];
                    if (!in_range_shifts)
                        range_error_q <= 1'b1;
                end
            end
        end
    end

endmodule
