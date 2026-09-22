`timescale 1ns/1ps

// Bit-exact 256-sample, 50%-overlapped vibration feature extractor.
//
// Two accumulation contexts start 128 accepted samples apart. A completed
// context is scanned from synchronous sample RAM to calculate exact
// window-mean-centered zero crossings. Other features are accumulated during
// acquisition. Results enter a two-window FIFO and are serialized as sixteen
// 32-bit words.
module motorsentinel_feature_extractor (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               enable_i,

    input  logic               sample_valid_i,
    output logic               sample_ready_o,
    input  logic signed [15:0] sample_x_i,
    input  logic signed [15:0] sample_y_i,
    input  logic signed [15:0] sample_z_i,

    output logic               feature_valid_o,
    input  logic               feature_ready_i,
    output logic [3:0]         feature_index_o,
    output logic [31:0]        feature_data_o,
    output logic               feature_last_o,
    output logic [31:0]        window_sequence_o,
    output logic [1:0]         queued_windows_o
);

    localparam integer BANKS = 2;
    localparam integer AXES  = 3;
    localparam integer BANDS = 4;

    logic signed [15:0] sample_axis [0:AXES-1];
    logic signed [31:0] sample_square_signed [0:AXES-1];

    logic               active_q [0:BANKS-1];
    logic [7:0]         sample_count_q [0:BANKS-1];
    logic signed [23:0] sum_q [0:BANKS-1][0:AXES-1];
    logic [38:0]        square_sum_q [0:BANKS-1][0:AXES-1];
    logic signed [15:0] minimum_q [0:BANKS-1][0:AXES-1];
    logic signed [15:0] maximum_q [0:BANKS-1][0:AXES-1];

    logic signed [19:0] haar_first_q [0:BANKS-1][0:AXES-1][0:BANDS-1];
    logic signed [19:0] haar_second_q [0:BANKS-1][0:AXES-1][0:BANDS-1];
    logic [47:0]        haar_energy_q [0:BANKS-1][0:BANDS-1];

    logic signed [23:0] sum_next [0:BANKS-1][0:AXES-1];
    logic [38:0]        square_sum_next [0:BANKS-1][0:AXES-1];
    logic signed [15:0] minimum_next [0:BANKS-1][0:AXES-1];
    logic signed [15:0] maximum_next [0:BANKS-1][0:AXES-1];
    logic [16:0]        peak_to_peak_next [0:BANKS-1][0:AXES-1];

    logic signed [19:0] haar_second_with_sample [0:BANKS-1][0:AXES-1][0:BANDS-1];
    logic signed [20:0] haar_difference [0:BANKS-1][0:AXES-1][0:BANDS-1];
    logic signed [41:0] haar_square_signed [0:BANKS-1][0:AXES-1][0:BANDS-1];
    logic [47:0]        haar_increment [0:BANKS-1][0:BANDS-1];
    logic [47:0]        haar_energy_next [0:BANKS-1][0:BANDS-1];

    // Explicit memories keep the intended two independent synchronous RAMs
    // visible to Libero/Synplify instead of relying on a multidimensional port.
    logic signed [15:0] sample_x_bank0 [0:255];
    logic signed [15:0] sample_y_bank0 [0:255];
    logic signed [15:0] sample_z_bank0 [0:255];
    logic signed [15:0] sample_x_bank1 [0:255];
    logic signed [15:0] sample_y_bank1 [0:255];
    logic signed [15:0] sample_z_bank1 [0:255];

    logic [6:0]  hop_count_q;
    logic        last_started_bank_q;
    logic        restart_bank_q;
    logic [31:0] next_window_sequence_q;

    logic        finalize_pending_q;
    logic        scan_active_q;
    logic        scan_complete_q;
    logic        scan_bank_q;
    logic [7:0]  scan_read_address_q;
    logic        scan_reads_done_q;
    logic        scan_data_valid_q;
    logic [7:0]  scan_process_index_q;
    logic signed [15:0] scan_x_q;
    logic signed [15:0] scan_y_q;
    logic signed [15:0] scan_z_q;
    logic signed [23:0] scan_sum_q [0:AXES-1];
    logic [7:0]  zcr_count_q [0:AXES-1];
    logic        zcr_previous_valid_q [0:AXES-1];
    logic        zcr_previous_sign_q [0:AXES-1];
    logic signed [24:0] centered_value [0:AXES-1];
    logic [7:0]  zcr_count_next [0:AXES-1];

    logic [31:0] pending_features_q [0:15];
    logic [31:0] pending_sequence_q;

    logic [31:0] result_memory [0:1][0:15];
    logic [31:0] result_sequence_q [0:1];
    logic        result_write_pointer_q;
    logic        result_read_pointer_q;
    logic [1:0]  result_count_q;
    logic [3:0]  serializer_index_q;

    wire completion_pending =
        (active_q[0] && sample_count_q[0] == 8'd255) ||
        (active_q[1] && sample_count_q[1] == 8'd255);
    wire completed_bank =
        (active_q[0] && sample_count_q[0] == 8'd255) ? 1'b0 : 1'b1;

    wire sample_fire = sample_valid_i && sample_ready_o;
    wire feature_fire = feature_valid_o && feature_ready_i;
    wire pop_window = feature_fire && feature_last_o;
    wire result_space_available = (result_count_q < 2) || pop_window;
    wire push_window = finalize_pending_q && scan_complete_q &&
                       result_space_available;

    assign sample_ready_o = enable_i && !finalize_pending_q;
    // Disable is an immediate interface quiesce as well as a synchronous
    // state flush. Gating valid prevents a consumer from observing a transfer
    // on the same edge that enable_i clears the queued window.
    assign feature_valid_o = enable_i && (result_count_q != 0);
    assign feature_index_o = serializer_index_q;
    assign feature_last_o = feature_valid_o && (serializer_index_q == 4'd15);
    assign feature_data_o = feature_valid_o ?
        result_memory[result_read_pointer_q][serializer_index_q] : 32'd0;
    assign window_sequence_o = feature_valid_o ?
        result_sequence_q[result_read_pointer_q] : 32'd0;
    assign queued_windows_o = result_count_q;

    function automatic logic haar_block_start(
        input logic [7:0] index,
        input integer band
    );
        begin
            case (band)
                0: haar_block_start = (index[0]   == 1'b0);
                1: haar_block_start = (index[1:0] == 2'd0);
                2: haar_block_start = (index[2:0] == 3'd0);
                default: haar_block_start = (index[3:0] == 4'd0);
            endcase
        end
    endfunction

    function automatic logic haar_first_half(
        input logic [7:0] index,
        input integer band
    );
        begin
            case (band)
                0: haar_first_half = (index[0]   < 1'd1);
                1: haar_first_half = (index[1:0] < 2'd2);
                2: haar_first_half = (index[2:0] < 3'd4);
                default: haar_first_half = (index[3:0] < 4'd8);
            endcase
        end
    endfunction

    function automatic logic haar_block_last(
        input logic [7:0] index,
        input integer band
    );
        begin
            case (band)
                0: haar_block_last = (index[0]   == 1'd1);
                1: haar_block_last = (index[1:0] == 2'd3);
                2: haar_block_last = (index[2:0] == 3'd7);
                default: haar_block_last = (index[3:0] == 4'd15);
            endcase
        end
    endfunction

    integer cb;
    integer ca;
    integer ck;
    always @* begin
        sample_axis[0] = sample_x_i;
        sample_axis[1] = sample_y_i;
        sample_axis[2] = sample_z_i;

        for (ca = 0; ca < AXES; ca = ca + 1) begin
            sample_square_signed[ca] =
                $signed(sample_axis[ca]) * $signed(sample_axis[ca]);
        end

        for (cb = 0; cb < BANKS; cb = cb + 1) begin
            for (ca = 0; ca < AXES; ca = ca + 1) begin
                sum_next[cb][ca] = sum_q[cb][ca] +
                    {{8{sample_axis[ca][15]}}, sample_axis[ca]};
                square_sum_next[cb][ca] = square_sum_q[cb][ca] +
                    {{7{1'b0}}, sample_square_signed[ca]};

                if (sample_count_q[cb] == 0 ||
                    $signed(sample_axis[ca]) < $signed(minimum_q[cb][ca]))
                    minimum_next[cb][ca] = sample_axis[ca];
                else
                    minimum_next[cb][ca] = minimum_q[cb][ca];

                if (sample_count_q[cb] == 0 ||
                    $signed(sample_axis[ca]) > $signed(maximum_q[cb][ca]))
                    maximum_next[cb][ca] = sample_axis[ca];
                else
                    maximum_next[cb][ca] = maximum_q[cb][ca];

                peak_to_peak_next[cb][ca] =
                    $unsigned($signed({maximum_next[cb][ca][15],
                                      maximum_next[cb][ca]}) -
                              $signed({minimum_next[cb][ca][15],
                                      minimum_next[cb][ca]}));
            end

            for (ck = 0; ck < BANDS; ck = ck + 1) begin
                haar_increment[cb][ck] = 48'd0;
                for (ca = 0; ca < AXES; ca = ca + 1) begin
                    haar_second_with_sample[cb][ca][ck] =
                        haar_second_q[cb][ca][ck] +
                        {{4{sample_axis[ca][15]}}, sample_axis[ca]};
                    haar_difference[cb][ca][ck] =
                        $signed({haar_first_q[cb][ca][ck][19],
                                 haar_first_q[cb][ca][ck]}) -
                        $signed({haar_second_with_sample[cb][ca][ck][19],
                                 haar_second_with_sample[cb][ca][ck]});
                    haar_square_signed[cb][ca][ck] =
                        $signed(haar_difference[cb][ca][ck]) *
                        $signed(haar_difference[cb][ca][ck]);
                    haar_increment[cb][ck] = haar_increment[cb][ck] +
                        {{6{1'b0}}, haar_square_signed[cb][ca][ck]};
                end

                if (haar_block_last(sample_count_q[cb], ck))
                    haar_energy_next[cb][ck] =
                        haar_energy_q[cb][ck] + haar_increment[cb][ck];
                else
                    haar_energy_next[cb][ck] = haar_energy_q[cb][ck];
            end
        end
    end

    logic signed [15:0] scan_axis [0:AXES-1];
    integer za;
    always @* begin
        scan_axis[0] = scan_x_q;
        scan_axis[1] = scan_y_q;
        scan_axis[2] = scan_z_q;
        for (za = 0; za < AXES; za = za + 1) begin
            centered_value[za] =
                ($signed({{9{scan_axis[za][15]}}, scan_axis[za]}) <<< 8) -
                $signed({scan_sum_q[za][23], scan_sum_q[za]});
            zcr_count_next[za] = zcr_count_q[za];
            if (centered_value[za] != 0 &&
                zcr_previous_valid_q[za] &&
                zcr_previous_sign_q[za] != centered_value[za][24])
                zcr_count_next[za] = zcr_count_q[za] + 1'b1;
        end
    end

    // Sample RAM writes and synchronous finalization reads. RAM contents are
    // deliberately not reset so synthesis can infer embedded memory.
    always_ff @(posedge clk) begin
        if (sample_fire) begin
            if (active_q[0]) begin
                sample_x_bank0[sample_count_q[0]] <= sample_x_i;
                sample_y_bank0[sample_count_q[0]] <= sample_y_i;
                sample_z_bank0[sample_count_q[0]] <= sample_z_i;
            end
            if (active_q[1]) begin
                sample_x_bank1[sample_count_q[1]] <= sample_x_i;
                sample_y_bank1[sample_count_q[1]] <= sample_y_i;
                sample_z_bank1[sample_count_q[1]] <= sample_z_i;
            end
        end

        if (scan_active_q && !scan_reads_done_q) begin
            if (scan_bank_q == 1'b0) begin
                scan_x_q <= sample_x_bank0[scan_read_address_q];
                scan_y_q <= sample_y_bank0[scan_read_address_q];
                scan_z_q <= sample_z_bank0[scan_read_address_q];
            end else begin
                scan_x_q <= sample_x_bank1[scan_read_address_q];
                scan_y_q <= sample_y_bank1[scan_read_address_q];
                scan_z_q <= sample_z_bank1[scan_read_address_q];
            end
            scan_process_index_q <= scan_read_address_q;
        end
    end

    integer rb;
    integer ra;
    integer rk;
    integer rf;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active_q[0] <= 1'b1;
            active_q[1] <= 1'b0;
            sample_count_q[0] <= 8'd0;
            sample_count_q[1] <= 8'd0;
            hop_count_q <= 7'd0;
            last_started_bank_q <= 1'b0;
            restart_bank_q <= 1'b0;
            next_window_sequence_q <= 32'd0;
            finalize_pending_q <= 1'b0;
            scan_active_q <= 1'b0;
            scan_complete_q <= 1'b0;
            scan_bank_q <= 1'b0;
            scan_read_address_q <= 8'd0;
            scan_reads_done_q <= 1'b0;
            scan_data_valid_q <= 1'b0;
            pending_sequence_q <= 32'd0;
            for (rb = 0; rb < BANKS; rb = rb + 1) begin
                for (ra = 0; ra < AXES; ra = ra + 1) begin
                    sum_q[rb][ra] <= '0;
                    square_sum_q[rb][ra] <= '0;
                    minimum_q[rb][ra] <= '0;
                    maximum_q[rb][ra] <= '0;
                    for (rk = 0; rk < BANDS; rk = rk + 1) begin
                        haar_first_q[rb][ra][rk] <= '0;
                        haar_second_q[rb][ra][rk] <= '0;
                    end
                end
                for (rk = 0; rk < BANDS; rk = rk + 1)
                    haar_energy_q[rb][rk] <= '0;
            end
            for (ra = 0; ra < AXES; ra = ra + 1) begin
                scan_sum_q[ra] <= '0;
                zcr_count_q[ra] <= '0;
                zcr_previous_valid_q[ra] <= 1'b0;
                zcr_previous_sign_q[ra] <= 1'b0;
            end
            for (rf = 0; rf < 16; rf = rf + 1)
                pending_features_q[rf] <= '0;
        end else if (!enable_i) begin
            active_q[0] <= 1'b1;
            active_q[1] <= 1'b0;
            sample_count_q[0] <= 8'd0;
            sample_count_q[1] <= 8'd0;
            hop_count_q <= 7'd0;
            last_started_bank_q <= 1'b0;
            restart_bank_q <= 1'b0;
            next_window_sequence_q <= 32'd0;
            finalize_pending_q <= 1'b0;
            scan_active_q <= 1'b0;
            scan_complete_q <= 1'b0;
            scan_bank_q <= 1'b0;
            scan_read_address_q <= 8'd0;
            scan_reads_done_q <= 1'b0;
            scan_data_valid_q <= 1'b0;
            pending_sequence_q <= 32'd0;
            for (rb = 0; rb < BANKS; rb = rb + 1) begin
                for (ra = 0; ra < AXES; ra = ra + 1) begin
                    sum_q[rb][ra] <= '0;
                    square_sum_q[rb][ra] <= '0;
                    minimum_q[rb][ra] <= '0;
                    maximum_q[rb][ra] <= '0;
                    for (rk = 0; rk < BANDS; rk = rk + 1) begin
                        haar_first_q[rb][ra][rk] <= '0;
                        haar_second_q[rb][ra][rk] <= '0;
                    end
                end
                for (rk = 0; rk < BANDS; rk = rk + 1)
                    haar_energy_q[rb][rk] <= '0;
            end
            for (ra = 0; ra < AXES; ra = ra + 1) begin
                scan_sum_q[ra] <= '0;
                zcr_count_q[ra] <= '0;
                zcr_previous_valid_q[ra] <= 1'b0;
                zcr_previous_sign_q[ra] <= 1'b0;
            end
        end else begin
            if (sample_fire) begin
                for (rb = 0; rb < BANKS; rb = rb + 1) begin
                    if (active_q[rb]) begin
                        sum_q[rb][0] <= sum_next[rb][0];
                        sum_q[rb][1] <= sum_next[rb][1];
                        sum_q[rb][2] <= sum_next[rb][2];
                        square_sum_q[rb][0] <= square_sum_next[rb][0];
                        square_sum_q[rb][1] <= square_sum_next[rb][1];
                        square_sum_q[rb][2] <= square_sum_next[rb][2];
                        minimum_q[rb][0] <= minimum_next[rb][0];
                        minimum_q[rb][1] <= minimum_next[rb][1];
                        minimum_q[rb][2] <= minimum_next[rb][2];
                        maximum_q[rb][0] <= maximum_next[rb][0];
                        maximum_q[rb][1] <= maximum_next[rb][1];
                        maximum_q[rb][2] <= maximum_next[rb][2];

                        for (rk = 0; rk < BANDS; rk = rk + 1) begin
                            haar_energy_q[rb][rk] <= haar_energy_next[rb][rk];
                            for (ra = 0; ra < AXES; ra = ra + 1) begin
                                if (haar_block_start(sample_count_q[rb], rk)) begin
                                    haar_first_q[rb][ra][rk] <=
                                        {{4{sample_axis[ra][15]}}, sample_axis[ra]};
                                    haar_second_q[rb][ra][rk] <= '0;
                                end else if (haar_first_half(sample_count_q[rb], rk)) begin
                                    haar_first_q[rb][ra][rk] <=
                                        haar_first_q[rb][ra][rk] +
                                        {{4{sample_axis[ra][15]}}, sample_axis[ra]};
                                end else if (haar_block_last(sample_count_q[rb], rk)) begin
                                    haar_first_q[rb][ra][rk] <= '0;
                                    haar_second_q[rb][ra][rk] <= '0;
                                end else begin
                                    haar_second_q[rb][ra][rk] <=
                                        haar_second_q[rb][ra][rk] +
                                        {{4{sample_axis[ra][15]}}, sample_axis[ra]};
                                end
                            end
                        end

                        if (sample_count_q[rb] == 8'd255) begin
                            active_q[rb] <= 1'b0;
                            sample_count_q[rb] <= 8'd0;
                        end else begin
                            sample_count_q[rb] <= sample_count_q[rb] + 1'b1;
                        end
                    end
                end

                if (completion_pending) begin
                    finalize_pending_q <= 1'b1;
                    scan_active_q <= 1'b1;
                    scan_complete_q <= 1'b0;
                    scan_bank_q <= completed_bank;
                    restart_bank_q <= completed_bank;
                    scan_read_address_q <= 8'd0;
                    scan_reads_done_q <= 1'b0;
                    scan_data_valid_q <= 1'b0;
                    pending_sequence_q <= next_window_sequence_q;
                    next_window_sequence_q <= next_window_sequence_q + 1'b1;

                    for (ra = 0; ra < AXES; ra = ra + 1) begin
                        scan_sum_q[ra] <= sum_next[completed_bank][ra];
                        zcr_count_q[ra] <= 8'd0;
                        zcr_previous_valid_q[ra] <= 1'b0;
                        zcr_previous_sign_q[ra] <= 1'b0;
                        pending_features_q[ra] <=
                            {{8{sum_next[completed_bank][ra][23]}},
                             ($signed(sum_next[completed_bank][ra]) >>> 8)};
                        pending_features_q[3+ra] <=
                            {1'b0, square_sum_next[completed_bank][ra][38:8]};
                        pending_features_q[6+ra] <=
                            {16'd0, peak_to_peak_next[completed_bank][ra][15:0]};
                    end

                    pending_features_q[12] <=
                        haar_energy_next[completed_bank][3][44:13];
                    pending_features_q[13] <=
                        haar_energy_next[completed_bank][2][43:12];
                    pending_features_q[14] <=
                        haar_energy_next[completed_bank][1][42:11];
                    pending_features_q[15] <=
                        haar_energy_next[completed_bank][0][41:10];
                end

                if (hop_count_q == 7'd127) begin
                    hop_count_q <= 7'd0;
                    last_started_bank_q <= ~last_started_bank_q;
                    if (!completion_pending) begin
                        if (last_started_bank_q == 1'b0) begin
                            active_q[1] <= 1'b1;
                            sample_count_q[1] <= 8'd0;
                            for (ra = 0; ra < AXES; ra = ra + 1) begin
                                sum_q[1][ra] <= '0;
                                square_sum_q[1][ra] <= '0;
                                minimum_q[1][ra] <= '0;
                                maximum_q[1][ra] <= '0;
                                for (rk = 0; rk < BANDS; rk = rk + 1) begin
                                    haar_first_q[1][ra][rk] <= '0;
                                    haar_second_q[1][ra][rk] <= '0;
                                end
                            end
                            for (rk = 0; rk < BANDS; rk = rk + 1)
                                haar_energy_q[1][rk] <= '0;
                        end else begin
                            active_q[0] <= 1'b1;
                            sample_count_q[0] <= 8'd0;
                            for (ra = 0; ra < AXES; ra = ra + 1) begin
                                sum_q[0][ra] <= '0;
                                square_sum_q[0][ra] <= '0;
                                minimum_q[0][ra] <= '0;
                                maximum_q[0][ra] <= '0;
                                for (rk = 0; rk < BANDS; rk = rk + 1) begin
                                    haar_first_q[0][ra][rk] <= '0;
                                    haar_second_q[0][ra][rk] <= '0;
                                end
                            end
                            for (rk = 0; rk < BANDS; rk = rk + 1)
                                haar_energy_q[0][rk] <= '0;
                        end
                    end
                end else begin
                    hop_count_q <= hop_count_q + 1'b1;
                end
            end

            if (scan_active_q) begin
                if (!scan_reads_done_q) begin
                    scan_data_valid_q <= 1'b1;
                    if (scan_read_address_q == 8'd255)
                        scan_reads_done_q <= 1'b1;
                    else
                        scan_read_address_q <= scan_read_address_q + 1'b1;
                end else begin
                    scan_data_valid_q <= 1'b0;
                end

                if (scan_data_valid_q) begin
                    for (ra = 0; ra < AXES; ra = ra + 1) begin
                        if (centered_value[ra] != 0) begin
                            zcr_count_q[ra] <= zcr_count_next[ra];
                            zcr_previous_valid_q[ra] <= 1'b1;
                            zcr_previous_sign_q[ra] <= centered_value[ra][24];
                        end
                    end

                    if (scan_process_index_q == 8'd255) begin
                        scan_active_q <= 1'b0;
                        scan_complete_q <= 1'b1;
                        scan_data_valid_q <= 1'b0;
                        pending_features_q[9] <= {24'd0, zcr_count_next[0]};
                        pending_features_q[10] <= {24'd0, zcr_count_next[1]};
                        pending_features_q[11] <= {24'd0, zcr_count_next[2]};
                    end
                end
            end

            if (push_window) begin
                for (rf = 0; rf < 16; rf = rf + 1)
                    result_memory[result_write_pointer_q][rf] <=
                        pending_features_q[rf];
                result_sequence_q[result_write_pointer_q] <= pending_sequence_q;
                finalize_pending_q <= 1'b0;
                scan_complete_q <= 1'b0;

                if (restart_bank_q == 1'b0) begin
                    active_q[0] <= 1'b1;
                    sample_count_q[0] <= 8'd0;
                    for (ra = 0; ra < AXES; ra = ra + 1) begin
                        sum_q[0][ra] <= '0;
                        square_sum_q[0][ra] <= '0;
                        minimum_q[0][ra] <= '0;
                        maximum_q[0][ra] <= '0;
                        for (rk = 0; rk < BANDS; rk = rk + 1) begin
                            haar_first_q[0][ra][rk] <= '0;
                            haar_second_q[0][ra][rk] <= '0;
                        end
                    end
                    for (rk = 0; rk < BANDS; rk = rk + 1)
                        haar_energy_q[0][rk] <= '0;
                end else begin
                    active_q[1] <= 1'b1;
                    sample_count_q[1] <= 8'd0;
                    for (ra = 0; ra < AXES; ra = ra + 1) begin
                        sum_q[1][ra] <= '0;
                        square_sum_q[1][ra] <= '0;
                        minimum_q[1][ra] <= '0;
                        maximum_q[1][ra] <= '0;
                        for (rk = 0; rk < BANDS; rk = rk + 1) begin
                            haar_first_q[1][ra][rk] <= '0;
                            haar_second_q[1][ra][rk] <= '0;
                        end
                    end
                    for (rk = 0; rk < BANDS; rk = rk + 1)
                        haar_energy_q[1][rk] <= '0;
                end
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result_write_pointer_q <= 1'b0;
            result_read_pointer_q <= 1'b0;
            result_count_q <= 2'd0;
            serializer_index_q <= 4'd0;
        end else if (!enable_i) begin
            result_write_pointer_q <= 1'b0;
            result_read_pointer_q <= 1'b0;
            result_count_q <= 2'd0;
            serializer_index_q <= 4'd0;
        end else begin
            case ({push_window, pop_window})
                2'b10: result_count_q <= result_count_q + 1'b1;
                2'b01: result_count_q <= result_count_q - 1'b1;
                default: result_count_q <= result_count_q;
            endcase

            if (push_window)
                result_write_pointer_q <= ~result_write_pointer_q;

            if (feature_fire) begin
                if (feature_last_o) begin
                    serializer_index_q <= 4'd0;
                    result_read_pointer_q <= ~result_read_pointer_q;
                end else begin
                    serializer_index_q <= serializer_index_q + 1'b1;
                end
            end
        end
    end

endmodule
