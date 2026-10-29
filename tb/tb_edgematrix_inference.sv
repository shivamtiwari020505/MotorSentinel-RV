`timescale 1ns/1ps

// Bit-exact differential test of the model store, INT8 normalizer and
// EdgeMatrix-RV autoencoder against model/edgematrix.py.
module tb_edgematrix_inference;

    localparam integer IMAGE_WORDS = 122;
    localparam integer MAX_VECTORS = 96;  // tools/generate_system_vectors.py default
    localparam integer EXPECTED_WORDS = 11;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    logic        begin_load = 1'b0;
    logic        commit = 1'b0;
    logic        data_write = 1'b0;
    logic [31:0] data = '0;
    logic [31:0] expected_crc = '0;
    logic        model_valid;
    logic        loading;
    logic [7:0]  words;
    logic [31:0] crc;
    logic [4:0]  model_error;

    logic [511:0]  offset;
    logic [255:0]  scale;
    logic [95:0]   norm_shift;
    logic [1023:0] w1;
    logic [1023:0] w2;
    logic [255:0]  b1;
    logic [511:0]  b2;
    logic [5:0]    s1;
    logic [5:0]    s2;

    logic        feature_valid = 1'b0;
    logic        feature_ready;
    logic [3:0]  feature_index = '0;
    logic [31:0] feature_data = '0;
    logic        feature_last = 1'b0;
    logic        window_done;
    logic [11:0] score;
    logic [31:0] score_sequence;
    logic [511:0] window_features;
    logic [127:0] window_q;
    logic [63:0]  window_h;
    logic [127:0] window_y;
    logic         busy;

    logic [31:0] image [0:IMAGE_WORDS-1];
    logic [31:0] features [0:MAX_VECTORS*16-1];
    logic [31:0] expected [0:MAX_VECTORS*EXPECTED_WORDS-1];

    integer checks = 0;
    integer failures = 0;
    integer vectors;
    integer v;
    integer f;
    integer start_cycle;
    integer cycles = 0;
    integer latency;
    integer max_latency = 0;

    always @(posedge clk) cycles <= cycles + 1;

    motorsentinel_model_store u_store (
        .clk            (clk),
        .rst_n          (rst_n),
        .begin_i        (begin_load),
        .commit_i       (commit),
        .data_write_i   (data_write),
        .data_i         (data),
        .expected_crc_i (expected_crc),
        .model_valid_o  (model_valid),
        .loading_o      (loading),
        .words_o        (words),
        .crc_o          (crc),
        .error_o        (model_error),
        .offset_o       (offset),
        .scale_o        (scale),
        .norm_shift_o   (norm_shift),
        .w1_o           (w1),
        .w2_o           (w2),
        .b1_o           (b1),
        .b2_o           (b2),
        .s1_o           (s1),
        .s2_o           (s2)
    );

    motorsentinel_inference dut (
        .clk               (clk),
        .rst_n             (rst_n),
        .enable_i          (1'b1),
        .model_valid_i     (model_valid),
        .feature_valid_i   (feature_valid),
        .feature_ready_o   (feature_ready),
        .feature_index_i   (feature_index),
        .feature_data_i    (feature_data),
        .feature_last_i    (feature_last),
        .window_sequence_i (32'(v)),
        .offset_i          (offset),
        .scale_i           (scale),
        .norm_shift_i      (norm_shift),
        .w1_i              (w1),
        .w2_i              (w2),
        .b1_i              (b1),
        .b2_i              (b2),
        .s1_i              (s1),
        .s2_i              (s2),
        .window_done_o     (window_done),
        .score_o           (score),
        .sequence_o        (score_sequence),
        .features_o        (window_features),
        .q_o               (window_q),
        .h_o               (window_h),
        .y_o               (window_y),
        .busy_o            (busy)
    );

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (!condition) begin
                failures = failures + 1;
                $display("FAIL: %s (t=%0t)", message, $time);
            end
        end
    endtask

    task automatic pulse_begin;
        begin
            @(negedge clk);
            begin_load = 1'b1;
            @(negedge clk);
            begin_load = 1'b0;
        end
    endtask

    task automatic pulse_commit;
        begin
            @(negedge clk);
            commit = 1'b1;
            @(negedge clk);
            commit = 1'b0;
        end
    endtask

    task automatic load_image(input integer corrupt_word, input integer length);
        integer w;
        begin
            pulse_begin();
            for (w = 0; w < length; w = w + 1) begin
                @(negedge clk);
                data = image[w] ^ ((w == corrupt_word) ? 32'h0000_0100 : 32'h0);
                data_write = 1'b1;
                @(negedge clk);
                data_write = 1'b0;
            end
            pulse_commit();
            @(negedge clk);
        end
    endtask

    initial begin
`ifdef DUMP_WAVES
        $dumpfile("build/edgematrix_inference.vcd");
        $dumpvars(0, tb_edgematrix_inference);
`endif
        $readmemh("build/model_image.hex", image);
        $readmemh("build/inference_features.hex", features);
        $readmemh("build/inference_expected.hex", expected);
        vectors = 0;
        while (vectors < MAX_VECTORS && expected[vectors*EXPECTED_WORDS] !== 32'bx)
            vectors = vectors + 1;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        expected_crc = 32'hffff_ffff;

        // Negative model-load cases must leave the model invalid.
        load_image(-1, IMAGE_WORDS);
        check(!model_valid && model_error[0], "wrong expected CRC is rejected");
        $display("PASS: wrong expected CRC is rejected");
        // Recompute the real CRC through the hardware, then reuse it.
        expected_crc = crc;
        load_image(40, IMAGE_WORDS);
        check(!model_valid && model_error[0], "corrupted weight word fails CRC");
        load_image(-1, IMAGE_WORDS - 1);
        check(!model_valid && model_error[1], "truncated image is rejected");
        pulse_begin();
        @(negedge clk);
        data = image[0] ^ 32'h1;
        data_write = 1'b1;
        @(negedge clk);
        data_write = 1'b0;
        pulse_commit();
        check(!model_valid && model_error[2], "wrong format word is rejected");
        @(negedge clk);
        data = 32'h0;
        data_write = 1'b1;
        @(negedge clk);
        data_write = 1'b0;
        @(negedge clk);
        check(model_error[4] == 1'b0 && !model_valid,
              "write after commit is ignored while the model is invalid");
        load_image(-1, IMAGE_WORDS);
        check(model_valid && model_error == 0 && words == IMAGE_WORDS,
              "correct 122-word image commits with matching CRC");
        $display("PASS: model store rejects CRC, length and format errors; accepts golden image (CRC %08x)", crc);

        for (v = 0; v < vectors; v = v + 1) begin
            wait (feature_ready);
            @(negedge clk);
            for (f = 0; f < 16; f = f + 1) begin
                feature_valid = 1'b1;
                feature_index = f[3:0];
                feature_data = features[v*16 + f];
                feature_last = (f == 15);
                @(posedge clk);
                if (f == 15)
                    start_cycle = cycles;
                @(negedge clk);
            end
            feature_valid = 1'b0;
            feature_last = 1'b0;
            @(posedge window_done);
            latency = cycles - start_cycle;
            if (latency > max_latency)
                max_latency = latency;
            @(negedge clk);
            check(score == expected[v*EXPECTED_WORDS][11:0], "anomaly score");
            for (f = 0; f < 4; f = f + 1)
                check(window_q[f*32 +: 32] == expected[v*EXPECTED_WORDS + 1 + f],
                      "normalized INT8 input");
            for (f = 0; f < 2; f = f + 1)
                check(window_h[f*32 +: 32] == expected[v*EXPECTED_WORDS + 5 + f],
                      "hidden activation");
            for (f = 0; f < 4; f = f + 1)
                check(window_y[f*32 +: 32] == expected[v*EXPECTED_WORDS + 7 + f],
                      "reconstruction");
            for (f = 0; f < 16; f = f + 1)
                check(window_features[f*32 +: 32] == features[v*16 + f],
                      "published raw feature snapshot");
            if (failures != 0) begin
                $display("vector %0d: score rtl=%0d expected=%0d", v, score,
                         expected[v*EXPECTED_WORDS]);
                $fatal(1, "FAIL: inference mismatch");
            end
        end

        if (failures == 0) begin
            $display("PASS: EdgeMatrix-RV matched %0d Python inferences bit-exactly (%0d checks)",
                     vectors, checks);
            $display("INFO: last feature to anomaly score = %0d cycles (%0d ns at 50 MHz)",
                     max_latency, max_latency * 20);
            $finish;
        end else begin
            $fatal(1, "FAIL: %0d of %0d checks failed", failures, checks);
        end
    end

endmodule
