`timescale 1ns/1ps

module tb_motorsentinel_feature_extractor;

    localparam integer SAMPLE_COUNT = 1024;
    localparam integer WINDOW_COUNT = 7;
    localparam integer EXPECTED_COUNT = WINDOW_COUNT * 16;
    localparam integer WINDOW_SIZE = 256;
    localparam integer HOP_SIZE = 128;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic enable = 1'b0;
    logic sample_valid = 1'b0;
    logic sample_ready;
    logic signed [15:0] sample_x = '0;
    logic signed [15:0] sample_y = '0;
    logic signed [15:0] sample_z = '0;
    logic feature_valid;
    logic feature_ready = 1'b0;
    logic [3:0] feature_index;
    logic [31:0] feature_data;
    logic feature_last;
    logic [31:0] window_sequence;
    logic [1:0] queued_windows;

    logic [47:0] sample_memory [0:SAMPLE_COUNT-1];
    logic [31:0] expected_memory [0:EXPECTED_COUNT-1];

    string samples_file;
    string expected_file;
    integer main_sample_index = 0;
    integer expected_index = 0;
    integer cycle_count = 0;
    integer checks = 0;
    integer failures = 0;
    integer partial_index;
    integer vector_index;
    logic main_phase = 1'b0;
    logic saw_input_stall = 1'b0;
    logic saw_full_result_queue = 1'b0;
    logic [15:0] stalled_feature_mask = '0;
    logic stall_tracking = 1'b0;
    logic [3:0] stalled_index;
    logic [31:0] stalled_data;
    logic stalled_last;
    logic [31:0] stalled_sequence;

    always #5 clk = ~clk;

    motorsentinel_feature_extractor dut (
        .clk                 (clk),
        .rst_n               (rst_n),
        .enable_i            (enable),
        .sample_valid_i      (sample_valid),
        .sample_ready_o      (sample_ready),
        .sample_x_i          (sample_x),
        .sample_y_i          (sample_y),
        .sample_z_i          (sample_z),
        .feature_valid_o     (feature_valid),
        .feature_ready_i     (feature_ready),
        .feature_index_o     (feature_index),
        .feature_data_o      (feature_data),
        .feature_last_o      (feature_last),
        .window_sequence_o   (window_sequence),
        .queued_windows_o    (queued_windows)
    );

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            // Four-state strictness is intentional: an X or Z must never be
            // accepted as a passing Boolean condition.
            if (condition !== 1'b1) begin
                failures = failures + 1;
                $display("FAIL: %s (t=%0t)", message, $time);
            end
        end
    endtask

    task automatic drive_word(input logic [47:0] packed_sample);
        begin
            sample_x = packed_sample[47:32];
            sample_y = packed_sample[31:16];
            sample_z = packed_sample[15:0];
        end
    endtask

    // Main-stream source. Once valid is raised, both valid and data remain
    // stable until the extractor accepts the sample.
    always @(negedge clk) begin
        if (rst_n)
            cycle_count = cycle_count + 1;

        if (main_phase) begin
            // Hold output for long enough to fill both result slots, then
            // drain concurrently with the remaining input stream. After that
            // initial hold, stall every serializer index for at least one
            // cycle before allowing it to advance.
            if (main_sample_index < 500) begin
                feature_ready = 1'b0;
            end else if (feature_valid && !$isunknown(feature_index) &&
                         !stalled_feature_mask[feature_index]) begin
                feature_ready = 1'b0;
            end else begin
                feature_ready = 1'b1;
            end

            if (!(sample_valid && !sample_ready)) begin
                if (main_sample_index < SAMPLE_COUNT &&
                    ((cycle_count % 11) != 3)) begin
                    sample_valid = 1'b1;
                    drive_word(sample_memory[main_sample_index]);
                end else begin
                    sample_valid = 1'b0;
                end
            end
        end
    end

    always @(posedge clk) begin
        if (rst_n && enable) begin
            if (main_phase && sample_valid && sample_ready)
                main_sample_index = main_sample_index + 1;

            if (main_phase && sample_valid && !sample_ready)
                saw_input_stall = 1'b1;
            if (main_phase && queued_windows == 2)
                saw_full_result_queue = 1'b1;

            check(!$isunknown(queued_windows),
                  "result queue depth is always known");
            if (!$isunknown(queued_windows))
                check(queued_windows <= 2,
                      "result queue depth never exceeds two");

            if (!main_phase && feature_valid) begin
                failures = failures + 1;
                $display("FAIL: partial window produced output (t=%0t)", $time);
            end

            if (main_phase && feature_valid) begin
                check(!$isunknown(window_sequence),
                      "valid output has a known window sequence");
                if (!$isunknown(window_sequence)) begin
                    check(window_sequence < WINDOW_COUNT,
                          "valid output sequence is in range");
                    if (window_sequence < WINDOW_COUNT)
                        check(main_sample_index >=
                              (WINDOW_SIZE + HOP_SIZE * window_sequence),
                              "window output is not emitted before its final accepted sample");
                end
            end

            if (stall_tracking) begin
                check(feature_valid, "valid must remain asserted during stall");
                check(feature_index === stalled_index,
                      "feature index remains stable during stall");
                check(feature_data === stalled_data,
                      "feature data remains stable during stall");
                check(feature_last === stalled_last,
                      "feature last remains stable during stall");
                check(window_sequence === stalled_sequence,
                      "window sequence remains stable during stall");
            end

            if (feature_valid && !feature_ready) begin
                stall_tracking = 1'b1;
                stalled_index = feature_index;
                stalled_data = feature_data;
                stalled_last = feature_last;
                stalled_sequence = window_sequence;
                if (main_phase && !$isunknown(feature_index))
                    stalled_feature_mask[feature_index] = 1'b1;
            end else begin
                stall_tracking = 1'b0;
            end

            if (main_phase && feature_valid && feature_ready) begin
                if (expected_index >= EXPECTED_COUNT) begin
                    failures = failures + 1;
                    $display("FAIL: unexpected extra feature output");
                end else begin
                    check(window_sequence === (expected_index / 16),
                          "window sequence matches expected order");
                    check(feature_index === (expected_index % 16),
                          "feature index matches expected order");
                    check(feature_last === ((expected_index % 16) == 15),
                          "feature_last marks only feature 15");
                    check(feature_data === expected_memory[expected_index],
                          "RTL feature matches bit-exact Python model");
                    expected_index = expected_index + 1;
                end
            end
        end
    end

    initial begin
        if (!$value$plusargs("SAMPLES=%s", samples_file))
            samples_file = "build/feature_samples.hex";
        if (!$value$plusargs("EXPECTED=%s", expected_file))
            expected_file = "build/feature_expected.hex";

        // Missing or truncated vector files must leave an X that the checks
        // below reject instead of accidentally comparing uninitialized data.
        for (vector_index = 0; vector_index < SAMPLE_COUNT;
             vector_index = vector_index + 1)
            sample_memory[vector_index] = 'x;
        for (vector_index = 0; vector_index < EXPECTED_COUNT;
             vector_index = vector_index + 1)
            expected_memory[vector_index] = 'x;

        $readmemh(samples_file, sample_memory);
        $readmemh(expected_file, expected_memory);

        for (vector_index = 0; vector_index < SAMPLE_COUNT;
             vector_index = vector_index + 1)
            check(!$isunknown(sample_memory[vector_index]),
                  "every input vector word is loaded and known");
        for (vector_index = 0; vector_index < EXPECTED_COUNT;
             vector_index = vector_index + 1)
            check(!$isunknown(expected_memory[vector_index]),
                  "every expected feature word is loaded and known");

`ifdef DUMP_WAVES
        $dumpfile("build/motorsentinel_features.vcd");
        $dumpvars(0, tb_motorsentinel_feature_extractor);
`endif

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        enable = 1'b1;
        feature_ready = 1'b1;

        // Feed and then discard a partial window to prove disable flushes all
        // overlapping state and stale RAM contents are ignored.
        for (partial_index = 0; partial_index < 173; partial_index = partial_index + 1) begin
            @(negedge clk);
            sample_valid = 1'b1;
            drive_word(sample_memory[partial_index]);
            while (!sample_ready)
                @(negedge clk);
            @(posedge clk);
        end
        @(negedge clk);
        sample_valid = 1'b0;
        enable = 1'b0;
        repeat (3) @(posedge clk);
        @(negedge clk);
        enable = 1'b1;
        feature_ready = 1'b0;
        main_phase = 1'b1;

        while (cycle_count < 10000 &&
               !(main_sample_index == SAMPLE_COUNT &&
                 expected_index == EXPECTED_COUNT &&
                 queued_windows == 0 && !feature_valid)) begin
            @(negedge clk);
        end

        check(cycle_count < 10000, "regression completes before timeout");
        check(main_sample_index == SAMPLE_COUNT,
              "all 1024 source samples are accepted exactly once");
        check(expected_index == EXPECTED_COUNT,
              "all seven feature vectors are emitted");
        check(saw_input_stall, "post-pass applies visible input backpressure");
        check(saw_full_result_queue,
              "two-entry result queue is exercised under output stall");
        check(stalled_feature_mask === 16'hffff,
              "backpressure is applied to every serializer index");
        check(queued_windows == 0 && !feature_valid,
              "serializer drains without extra output");

        if (failures == 0) begin
            $display("PASS: feature extractor matched %0d Python values (%0d checks)",
                     EXPECTED_COUNT, checks);
            $finish;
        end else begin
            $fatal(1, "FAIL: %0d checks failed out of %0d", failures, checks);
        end
    end

endmodule
