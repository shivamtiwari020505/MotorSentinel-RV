`timescale 1ns/1ps

// Per-sample sensor-integrity monitor; bit-exact with model/integrity.py.
//
// Range, slew and frozen-value checks are evaluated on the accepted sample.
// Replay detection keeps a cyclic-polynomial rolling hash over the last
// 16 samples (rotate/XOR only, no multipliers) and looks it up in a 1024-entry
// direct-mapped tag RAM. Hits are counted per 128-sample block; a block with
// at least replay_threshold_i hits raises a replay event independent of where
// a replayed recording's loop boundary falls.
//
// Pipeline: accept -> hash registered -> RAM read -> compare/write/report.
// sample_ready_o enforces one sample in flight, so the RAM needs no bypass and
// results match the sequential Python model exactly. At 800 samples/s and
// 50 MHz the three-cycle occupancy is negligible. After enable, a 1024-cycle
// sweep clears the table before the first sample is accepted.
module motorsentinel_integrity_monitor (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               enable_i,

    input  logic               sample_valid_i,
    output logic               sample_ready_o,
    input  logic signed [15:0] sample_x_i,
    input  logic signed [15:0] sample_y_i,
    input  logic signed [15:0] sample_z_i,

    input  logic [15:0]        range_limit_i,
    input  logic [15:0]        slew_limit_i,
    input  logic [7:0]         frozen_limit_i,
    input  logic [7:0]         replay_threshold_i,

    output logic               event_valid_o,
    output logic [3:0]         events_o,       // {replay, frozen, slew, range}
    output logic               frozen_active_o,
    output logic [7:0]         block_hits_o
);

    localparam integer TAPS = 16;
    localparam integer TABLE_BITS = 10;
    localparam integer TAG_BITS = 32 - TABLE_BITS;

    localparam integer EV_RANGE  = 0;
    localparam integer EV_SLEW   = 1;
    localparam integer EV_FROZEN = 2;
    localparam integer EV_REPLAY = 3;

    // Tag RAM: {valid, tag}. Not reset, so it maps to embedded LSRAM.
    logic [TAG_BITS:0] table_ram [0:(1<<TABLE_BITS)-1];
    logic [TAG_BITS:0] read_q;

    logic                   swept_q;
    logic [TABLE_BITS-1:0]  sweep_address_q;

    logic [31:0]  history_q [0:TAPS-1];
    logic [31:0]  rolling_q;
    logic signed [15:0] previous_q [0:2];
    logic         have_previous_q;
    logic [7:0]   run_length_q;
    logic [3:0]   primed_q;        // saturates at 15: hash covers 16 samples
    logic [6:0]   block_position_q;
    logic [7:0]   block_hits_q;

    logic         stage1_q;
    logic         stage2_q;
    logic         lookup_q;
    logic         block_end_q;
    logic [2:0]   early_events_q;  // {frozen, slew, range}
    logic [31:0]  hash_q;

    wire sample_fire = sample_valid_i && sample_ready_o;
    assign sample_ready_o = enable_i && swept_q && !stage1_q && !stage2_q;

    function automatic logic [31:0] rotl32(input logic [31:0] value,
                                           input integer amount);
        rotl32 = (value << amount) | (value >> (32 - amount));
    endfunction

    function automatic logic [16:0] magnitude(input logic signed [16:0] value);
        magnitude = value[16] ? 17'(-value) : 17'(value);
    endfunction

    logic signed [15:0] axis [0:2];
    logic        range_hit;
    logic        slew_hit;
    logic        same_as_previous;
    logic [7:0]  run_length_next;
    logic [31:0] mixed;
    logic [31:0] rolling_next;
    integer a;

    always_comb begin
        axis[0] = sample_x_i;
        axis[1] = sample_y_i;
        axis[2] = sample_z_i;
        range_hit = 1'b0;
        slew_hit = 1'b0;
        for (a = 0; a < 3; a = a + 1) begin
            if (range_limit_i != 0 &&
                magnitude({axis[a][15], axis[a]}) > {1'b0, range_limit_i})
                range_hit = 1'b1;
            if (have_previous_q && slew_limit_i != 0 &&
                magnitude($signed({axis[a][15], axis[a]}) -
                          $signed({previous_q[a][15], previous_q[a]})) >
                {1'b0, slew_limit_i})
                slew_hit = 1'b1;
        end
        same_as_previous = have_previous_q &&
                           axis[0] == previous_q[0] &&
                           axis[1] == previous_q[1] &&
                           axis[2] == previous_q[2];
        if (!same_as_previous)
            run_length_next = 8'd1;
        else if (run_length_q == 8'd255)
            run_length_next = 8'd255;
        else
            run_length_next = run_length_q + 1'b1;

        mixed = {sample_x_i, sample_y_i} ^
                rotl32({sample_z_i, sample_z_i ^ 16'ha5c3}, 7);
        rolling_next = rotl32(rolling_q, 1) ^ mixed ^
                       rotl32(history_q[TAPS-1], TAPS);
    end

    wire frozen_hit = (frozen_limit_i != 0) && (run_length_next >= frozen_limit_i);
    wire [TABLE_BITS-1:0] lookup_slot = hash_q[TABLE_BITS-1:0];
    wire [TAG_BITS-1:0] lookup_tag = hash_q[31:TABLE_BITS];
    wire table_hit = read_q[TAG_BITS] && (read_q[TAG_BITS-1:0] == lookup_tag);
    wire [7:0] hits_total = block_hits_q + ((lookup_q && table_hit) ? 8'd1 : 8'd0);

    // Tag RAM ports: sweep write, stage-1 read, stage-2 write.
    always_ff @(posedge clk) begin
        if (enable_i && !swept_q)
            table_ram[sweep_address_q] <= '0;
        else if (stage2_q && lookup_q)
            table_ram[lookup_slot] <= {1'b1, lookup_tag};
        if (stage1_q)
            read_q <= table_ram[lookup_slot];
    end

    integer h;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            swept_q          <= 1'b0;
            sweep_address_q  <= '0;
            rolling_q        <= '0;
            have_previous_q  <= 1'b0;
            run_length_q     <= '0;
            primed_q         <= '0;
            block_position_q <= '0;
            block_hits_q     <= '0;
            stage1_q         <= 1'b0;
            stage2_q         <= 1'b0;
            lookup_q         <= 1'b0;
            block_end_q      <= 1'b0;
            early_events_q   <= '0;
            hash_q           <= '0;
            event_valid_o    <= 1'b0;
            events_o         <= '0;
            frozen_active_o  <= 1'b0;
            block_hits_o     <= '0;
            for (h = 0; h < TAPS; h = h + 1)
                history_q[h] <= '0;
            for (h = 0; h < 3; h = h + 1)
                previous_q[h] <= '0;
        end else if (!enable_i) begin
            swept_q          <= 1'b0;
            sweep_address_q  <= '0;
            rolling_q        <= '0;
            have_previous_q  <= 1'b0;
            run_length_q     <= '0;
            primed_q         <= '0;
            block_position_q <= '0;
            block_hits_q     <= '0;
            stage1_q         <= 1'b0;
            stage2_q         <= 1'b0;
            event_valid_o    <= 1'b0;
            events_o         <= '0;
            frozen_active_o  <= 1'b0;
            for (h = 0; h < TAPS; h = h + 1)
                history_q[h] <= '0;
        end else begin
            event_valid_o <= 1'b0;

            if (!swept_q) begin
                sweep_address_q <= sweep_address_q + 1'b1;
                if (sweep_address_q == {TABLE_BITS{1'b1}})
                    swept_q <= 1'b1;
            end

            stage1_q <= sample_fire;
            stage2_q <= stage1_q;

            if (sample_fire) begin
                history_q[0] <= mixed;
                for (h = 1; h < TAPS; h = h + 1)
                    history_q[h] <= history_q[h-1];
                rolling_q <= rolling_next;
                hash_q    <= rolling_next;
                previous_q[0] <= sample_x_i;
                previous_q[1] <= sample_y_i;
                previous_q[2] <= sample_z_i;
                have_previous_q <= 1'b1;
                run_length_q <= run_length_next;
                frozen_active_o <= frozen_hit;
                early_events_q <= {frozen_hit, slew_hit, range_hit};
                lookup_q <= (primed_q == 4'd15);
                if (primed_q != 4'd15)
                    primed_q <= primed_q + 1'b1;
                block_end_q <= (block_position_q == 7'd127);
                block_position_q <= block_position_q + 1'b1;
            end

            if (stage2_q) begin
                event_valid_o <= 1'b1;
                events_o[EV_RANGE]  <= early_events_q[0];
                events_o[EV_SLEW]   <= early_events_q[1];
                events_o[EV_FROZEN] <= early_events_q[2];
                events_o[EV_REPLAY] <= block_end_q && (replay_threshold_i != 0) &&
                                       (hits_total >= replay_threshold_i);
                if (block_end_q) begin
                    block_hits_o <= hits_total;
                    block_hits_q <= '0;
                end else begin
                    block_hits_q <= hits_total;
                end
            end
        end
    end

endmodule
