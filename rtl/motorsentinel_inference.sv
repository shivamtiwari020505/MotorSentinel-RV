`timescale 1ns/1ps

// Feature-stream consumer for EdgeMatrix-RV.
//
// Each serialized 32-bit feature is normalized to INT8 as it arrives, using
//   q = sat8(rshift_round((feature - offset) * scale, shift)),
// so normalization adds no latency beyond the 16-word transfer. The last word
// starts the autoencoder. A completed inference publishes a consistent
// snapshot of raw features, q, h and y for software, and pulses window_done_o
// toward the safety policy only while a committed model is valid.
module motorsentinel_inference (
    input  logic            clk,
    input  logic            rst_n,
    input  logic            enable_i,
    input  logic            model_valid_i,

    input  logic            feature_valid_i,
    output logic            feature_ready_o,
    input  logic [3:0]      feature_index_i,
    input  logic [31:0]     feature_data_i,
    input  logic            feature_last_i,
    input  logic [31:0]     window_sequence_i,

    input  logic [511:0]    offset_i,      // offset[i] at [i*32 +: 32]
    input  logic [255:0]    scale_i,       // scale[i]  at [i*16 +: 16]
    input  logic [95:0]     norm_shift_i,  // shift[i]  at [i*6 +: 6]
    input  logic [1023:0]   w1_i,
    input  logic [1023:0]   w2_i,
    input  logic [255:0]    b1_i,
    input  logic [511:0]    b2_i,
    input  logic [5:0]      s1_i,
    input  logic [5:0]      s2_i,

    output logic            window_done_o,
    output logic [11:0]     score_o,
    output logic [31:0]     sequence_o,
    output logic [511:0]    features_o,
    output logic [127:0]    q_o,
    output logic [63:0]     h_o,
    output logic [127:0]    y_o,
    output logic            busy_o
);

    logic [511:0] capture_q;
    logic [127:0] q_capture_q;
    logic [31:0]  capture_sequence_q;
    logic         start_q;
    logic         engine_busy;
    logic         engine_done;
    logic [11:0]  engine_score;
    logic [63:0]  engine_h;
    logic [127:0] engine_y;

    wire feature_fire = feature_valid_i && feature_ready_o;

    assign feature_ready_o = enable_i && !engine_busy && !start_q;
    assign busy_o = engine_busy || start_q;

    // Single-cycle normalizer for the currently presented feature.
    logic signed [31:0] offset_sel;
    logic signed [15:0] scale_sel;
    logic [5:0]         shift_sel;
    logic signed [32:0] centered;
    logic signed [49:0] product;
    logic signed [49:0] rounding;
    logic signed [49:0] shifted;
    logic [7:0]         q_value;

    always_comb begin
        offset_sel = offset_i[feature_index_i*32 +: 32];
        scale_sel  = scale_i[feature_index_i*16 +: 16];
        shift_sel  = norm_shift_i[feature_index_i*6 +: 6];
        centered = $signed({feature_data_i[31], feature_data_i}) -
                   $signed({offset_sel[31], offset_sel});
        product = centered * scale_sel;
        rounding = (shift_sel == 0) ? 50'sd0 : (50'sd1 <<< (shift_sel - 1));
        shifted = (product + rounding) >>> shift_sel;
        if (shifted > 50'sd127)
            q_value = 8'h7f;
        else if (shifted < -50'sd128)
            q_value = 8'h80;
        else
            q_value = shifted[7:0];
    end

    edgematrix_autoencoder u_engine (
        .clk     (clk),
        .rst_n   (rst_n),
        .start_i (start_q),
        .q_i     (q_capture_q),
        .w1_i    (w1_i),
        .w2_i    (w2_i),
        .b1_i    (b1_i),
        .b2_i    (b2_i),
        .s1_i    (s1_i),
        .s2_i    (s2_i),
        .busy_o  (engine_busy),
        .done_o  (engine_done),
        .score_o (engine_score),
        .h_o     (engine_h),
        .y_o     (engine_y)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            capture_q          <= '0;
            q_capture_q        <= '0;
            capture_sequence_q <= '0;
            start_q            <= 1'b0;
            window_done_o      <= 1'b0;
            score_o            <= '0;
            sequence_o         <= '0;
            features_o         <= '0;
            q_o                <= '0;
            h_o                <= '0;
            y_o                <= '0;
        end else begin
            start_q       <= 1'b0;
            window_done_o <= 1'b0;

            if (feature_fire) begin
                capture_q[feature_index_i*32 +: 32] <= feature_data_i;
                q_capture_q[feature_index_i*8 +: 8] <= q_value;
                if (feature_last_i) begin
                    capture_sequence_q <= window_sequence_i;
                    // Without a committed model the window is consumed and
                    // discarded; the safety policy already holds the trip.
                    start_q <= model_valid_i;
                end
            end

            if (engine_done && enable_i && model_valid_i) begin
                window_done_o <= 1'b1;
                score_o       <= engine_score;
                sequence_o    <= capture_sequence_q;
                features_o    <= capture_q;
                q_o           <= q_capture_q;
                h_o           <= engine_h;
                y_o           <= engine_y;
            end
        end
    end

endmodule
