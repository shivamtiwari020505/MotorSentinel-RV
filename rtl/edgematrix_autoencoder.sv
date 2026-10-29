`timescale 1ns/1ps

// EdgeMatrix-RV: INT8 16 -> 8 -> 16 autoencoder on one 8x8 systolic array.
//
// The network is scheduled as four weight-stationary 8x8 tiles:
//   tile 0: acc1[j]  = sum_{i<8}   W1[j][i] * q[i]
//   tile 1: acc1[j] += sum_{i>=8}  W1[j][i] * q[i]
//   tile 2: acc2[i]  = sum_j W2[i][j]   * h[j]   for outputs 0..7
//   tile 3: acc2[i]  = sum_j W2[i][j]   * h[j]   for outputs 8..15
// Bias, round-half-up requantization, ReLU, INT8 saturation and the 12-bit L1
// reconstruction score follow model/edgematrix.py bit-for-bit. Latency is
// fixed and data-independent, which keeps the safety response deterministic.
module edgematrix_autoencoder (
    input  logic            clk,
    input  logic            rst_n,

    input  logic            start_i,
    input  logic [127:0]    q_i,      // q[i]      at [i*8 +: 8]
    input  logic [1023:0]   w1_i,     // W1[j][i]  at byte j*16+i
    input  logic [1023:0]   w2_i,     // W2[i][j]  at byte i*8+j
    input  logic [255:0]    b1_i,     // b1[j]     at [j*32 +: 32]
    input  logic [511:0]    b2_i,     // b2[i]     at [i*32 +: 32]
    input  logic [5:0]      s1_i,
    input  logic [5:0]      s2_i,

    output logic            busy_o,
    output logic            done_o,
    output logic [11:0]     score_o,
    output logic [63:0]     h_o,
    output logic [127:0]    y_o
);

    localparam integer N = 8;

    typedef enum logic [2:0] {
        S_IDLE,
        S_LOAD,
        S_FEED,
        S_COLLECT,
        S_HIDDEN,
        S_OUTPUT,
        S_SCORE
    } state_t;

    state_t      state_q;
    logic [1:0]  tile_q;
    logic [7:0]  collected_q;
    logic [127:0] q_q;

    logic signed [31:0] acc1_q [0:N-1];
    logic signed [31:0] acc2_q [0:2*N-1];

    logic [N*N*8-1:0] tile_weights;
    logic [N*8-1:0]   tile_activations;
    logic             weight_load;
    logic             input_valid;
    logic [N-1:0]     output_valid;
    logic [N*32-1:0]  results;

    function automatic logic signed [7:0] sat8(input logic signed [33:0] value);
        if (value > 34'sd127)
            sat8 = 8'sd127;
        else if (value < -34'sd128)
            sat8 = -8'sd128;
        else
            sat8 = value[7:0];
    endfunction

    // Round half toward positive infinity, then arithmetic shift.
    function automatic logic signed [33:0] rshift_round(
        input logic signed [33:0] value,
        input logic [5:0]         shift
    );
        logic signed [33:0] bias;
        begin
            bias = (shift == 0) ? 34'sd0 : (34'sd1 <<< (shift - 1));
            rshift_round = (value + bias) >>> shift;
        end
    endfunction

    edgematrix_array #(
        .ROWS  (N),
        .COLS  (N),
        .DATA_W(8),
        .ACC_W (32)
    ) u_array (
        .clk         (clk),
        .rst_n       (rst_n),
        .weight_load (weight_load),
        .weights     (tile_weights),
        .input_valid (input_valid),
        .activations (tile_activations),
        .output_valid(output_valid),
        .results     (results)
    );

    // PE(r, c) multiplies activation row r into output column c.
    integer tr;
    integer tc;
    always_comb begin
        for (tr = 0; tr < N; tr = tr + 1) begin
            case (tile_q)
                2'd0: tile_activations[tr*8 +: 8] = q_q[tr*8 +: 8];
                2'd1: tile_activations[tr*8 +: 8] = q_q[(N+tr)*8 +: 8];
                default: tile_activations[tr*8 +: 8] = h_o[tr*8 +: 8];
            endcase
            for (tc = 0; tc < N; tc = tc + 1) begin
                case (tile_q)
                    2'd0: tile_weights[(tr*N+tc)*8 +: 8] = w1_i[(tc*16+tr)*8 +: 8];
                    2'd1: tile_weights[(tr*N+tc)*8 +: 8] = w1_i[(tc*16+N+tr)*8 +: 8];
                    2'd2: tile_weights[(tr*N+tc)*8 +: 8] = w2_i[(tc*N+tr)*8 +: 8];
                    default: tile_weights[(tr*N+tc)*8 +: 8] = w2_i[((N+tc)*N+tr)*8 +: 8];
                endcase
            end
        end
    end

    assign weight_load = (state_q == S_LOAD);
    assign input_valid = (state_q == S_FEED);
    assign busy_o = (state_q != S_IDLE);

    integer k;
    logic signed [33:0] hidden_value [0:N-1];
    logic [7:0]         hidden_next  [0:N-1];
    logic [7:0]         output_next  [0:2*N-1];
    logic signed [8:0]  difference;
    logic [11:0]        score_sum;
    always_comb begin
        for (k = 0; k < N; k = k + 1) begin
            hidden_value[k] = rshift_round(
                34'(acc1_q[k]) + 34'($signed(b1_i[k*32 +: 32])), s1_i);
            hidden_next[k] = (hidden_value[k] < 0) ? 8'd0 : sat8(hidden_value[k]);
        end
        for (k = 0; k < 2*N; k = k + 1)
            output_next[k] = sat8(rshift_round(
                34'(acc2_q[k]) + 34'($signed(b2_i[k*32 +: 32])), s2_i));

        score_sum = 12'd0;
        for (k = 0; k < 2*N; k = k + 1) begin
            difference = $signed({y_o[k*8+7], y_o[k*8 +: 8]}) -
                         $signed({q_q[k*8+7], q_q[k*8 +: 8]});
            score_sum = score_sum +
                (difference[8] ? 12'(-difference) : 12'(difference));
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q     <= S_IDLE;
            tile_q      <= 2'd0;
            collected_q <= '0;
            q_q         <= '0;
            h_o         <= '0;
            y_o         <= '0;
            score_o     <= '0;
            done_o      <= 1'b0;
            for (k = 0; k < N; k = k + 1)
                acc1_q[k] <= '0;
            for (k = 0; k < 2*N; k = k + 1)
                acc2_q[k] <= '0;
        end else begin
            done_o <= 1'b0;
            case (state_q)
                S_IDLE: begin
                    if (start_i) begin
                        q_q    <= q_i;
                        tile_q <= 2'd0;
                        state_q <= S_LOAD;
                    end
                end

                S_LOAD: begin
                    collected_q <= '0;
                    state_q <= S_FEED;
                end

                S_FEED: state_q <= S_COLLECT;

                S_COLLECT: begin
                    for (k = 0; k < N; k = k + 1) begin
                        if (output_valid[k]) begin
                            case (tile_q)
                                2'd0: acc1_q[k] <= $signed(results[k*32 +: 32]);
                                2'd1: acc1_q[k] <= acc1_q[k] + $signed(results[k*32 +: 32]);
                                2'd2: acc2_q[k] <= $signed(results[k*32 +: 32]);
                                default: acc2_q[N+k] <= $signed(results[k*32 +: 32]);
                            endcase
                        end
                    end
                    if ((collected_q | output_valid) == {N{1'b1}}) begin
                        case (tile_q)
                            2'd0: begin tile_q <= 2'd1; state_q <= S_LOAD; end
                            2'd1: state_q <= S_HIDDEN;
                            2'd2: begin tile_q <= 2'd3; state_q <= S_LOAD; end
                            default: state_q <= S_OUTPUT;
                        endcase
                    end
                    collected_q <= collected_q | output_valid;
                end

                S_HIDDEN: begin
                    for (k = 0; k < N; k = k + 1)
                        h_o[k*8 +: 8] <= hidden_next[k];
                    tile_q  <= 2'd2;
                    state_q <= S_LOAD;
                end

                S_OUTPUT: begin
                    for (k = 0; k < 2*N; k = k + 1)
                        y_o[k*8 +: 8] <= output_next[k];
                    state_q <= S_SCORE;
                end

                S_SCORE: begin
                    score_o <= score_sum;
                    done_o  <= 1'b1;
                    state_q <= S_IDLE;
                end

                default: state_q <= S_IDLE;
            endcase
        end
    end

endmodule
