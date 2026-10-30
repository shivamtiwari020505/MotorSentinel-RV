`timescale 1ns/1ps

// Self-checking test of the ADXL345 I2C reader against a behavioral sensor.
//
// Checks sensor configuration, every received sample, I2C Fast-mode timing
// (tLOW, tHIGH, START/STOP setup and hold, bus-free time, data setup), clock
// stretching, NACK recovery, wrong device ID, a stuck SDA line and the
// timer-triggered mode.
module tb_adxl345_reader;

    localparam integer CLK_HZ = 50_000_000;
    localparam integer SAMPLE_COUNT = 256;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #10 clk = ~clk;

    tri1 scl;
    tri1 sda;
    wire drdy;

    logic enable = 1'b0;
    logic use_drdy = 1'b1;
    logic scl_drive_low;
    logic sda_drive_low;
    logic master_active;
    logic scl_release;
    logic sample_nack;
    logic sample_valid;
    logic signed [15:0] sample_x;
    logic signed [15:0] sample_y;
    logic signed [15:0] sample_z;
    logic configured;
    logic id_error;
    logic [7:0] device_id;
    logic [15:0] nack_count;
    logic [31:0] sample_count;

    assign scl = scl_drive_low ? 1'b0 : 1'bz;
    assign sda = sda_drive_low ? 1'b0 : 1'bz;

    motorsentinel_adxl345_reader #(
        .CLK_HZ(CLK_HZ)
    ) dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .enable_i        (enable),
        .use_drdy_i      (use_drdy),
        .scl_i           (scl),
        .sda_i           (sda),
        .drdy_i          (drdy),
        .scl_drive_low_o (scl_drive_low),
        .sda_drive_low_o (sda_drive_low),
        .master_active_o (master_active),
        .scl_release_o   (scl_release),
        .sample_nack_o   (sample_nack),
        .sample_valid_o  (sample_valid),
        .sample_x_o      (sample_x),
        .sample_y_o      (sample_y),
        .sample_z_o      (sample_z),
        .configured_o    (configured),
        .id_error_o      (id_error),
        .device_id_o     (device_id),
        .nack_count_o    (nack_count),
        .sample_count_o  (sample_count)
    );

    adxl345_i2c_model sensor (
        .scl  (scl),
        .sda  (sda),
        .drdy (drdy)
    );

    integer checks = 0;
    integer failures = 0;
    integer received = 0;
    integer k;
    integer t0;
    integer count0;
    integer burst_ns;
    logic [31:0] lfsr = 32'h1234_5678;

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (!condition) begin
                failures = failures + 1;
                $display("FAIL: %s (t=%0t)", message, $time);
            end else begin
                $display("PASS: %s", message);
            end
        end
    endtask

    // ---------------------------------------------------------------
    // Sample checker: the stream must be exactly the sensor's sequence.
    // ---------------------------------------------------------------
    integer sample_mismatches = 0;
    always @(posedge clk) begin
        if (sample_valid) begin
            if ({sample_x, sample_y, sample_z} !== sensor.samples[received]) begin
                sample_mismatches = sample_mismatches + 1;
                $display("  sample %0d: got %h %h %h expected %h", received,
                         sample_x, sample_y, sample_z, sensor.samples[received]);
            end
            received = received + 1;
        end
    end

    // ---------------------------------------------------------------
    // I2C Fast-mode timing monitor (UM10204 Table 10 limits).
    // ---------------------------------------------------------------
    realtime scl_rise = 0;
    realtime scl_fall = 0;
    realtime sda_change = 0;
    realtime start_time = -1;
    realtime stop_time = -1;
    realtime min_low = 1.0e9;
    realtime min_high = 1.0e9;
    realtime min_period = 1.0e9;
    realtime prev_rise = -1;
    integer timing_errors = 0;
    integer stretch_cycles_seen = 0;
    logic after_start = 1'b0;

    // Monitoring starts after reset so the x->1 power-up of the pulled-up
    // lines is not mistaken for bus activity.
    always @(posedge scl) if (rst_n) begin
        if (scl_fall > 0) begin
            if ($realtime - scl_fall < min_low)
                min_low = $realtime - scl_fall;
            if ($realtime - scl_fall < 1300.0) begin
                timing_errors = timing_errors + 1;
                $display("  tLOW violation %0t ns at %0t", $realtime - scl_fall, $time);
            end
        end
        if ($realtime - sda_change < 100.0 && sda_change > 0) begin
            timing_errors = timing_errors + 1;
            $display("  tSU;DAT violation at %0t", $time);
        end
        if (prev_rise > 0 && $realtime - prev_rise < min_period)
            min_period = $realtime - prev_rise;
        prev_rise = $realtime;
        scl_rise = $realtime;
    end

    always @(negedge scl) if (rst_n) begin
        if (scl_rise > 0) begin
            if ($realtime - scl_rise < min_high)
                min_high = $realtime - scl_rise;
            if ($realtime - scl_rise < 600.0) begin
                timing_errors = timing_errors + 1;
                $display("  tHIGH violation at %0t", $time);
            end
        end
        if (after_start && $realtime - start_time < 600.0) begin
            timing_errors = timing_errors + 1;
            $display("  tHD;STA violation at %0t", $time);
        end
        after_start = 1'b0;
        scl_fall = $realtime;
    end

    always @(sda) if (rst_n) begin
        if (scl === 1'b1 && sda === 1'b0) begin  // START
            if ($realtime - scl_rise < 600.0) begin
                timing_errors = timing_errors + 1;
                $display("  tSU;STA violation at %0t", $time);
            end
            if (stop_time > 0 && $realtime - stop_time < 1300.0) begin
                timing_errors = timing_errors + 1;
                $display("  tBUF violation at %0t", $time);
            end
            start_time = $realtime;
            after_start = 1'b1;
        end else if (scl === 1'b1 && sda === 1'b1) begin  // STOP
            if ($realtime - scl_rise < 600.0) begin
                timing_errors = timing_errors + 1;
                $display("  tSU;STO violation at %0t", $time);
            end
            stop_time = $realtime;
        end else begin
            sda_change = $realtime;
        end
    end

    // Count cycles where the master released SCL but a slave held it low.
    always @(posedge clk)
        if (scl_release && scl === 1'b0 && dut.scl_sync_q == 2'b00)
            stretch_cycles_seen = stretch_cycles_seen + 1;

    // Ownership invariant: the master never drives a line it does not own.
    always @(posedge clk)
        if (rst_n && (scl_drive_low || sda_drive_low) && !master_active)
            $fatal(1, "master drove the bus without owning it");

    task automatic wait_samples(input integer target);
        begin
            while (received < target)
                @(posedge clk);
        end
    endtask

    initial begin
`ifdef DUMP_WAVES
        $dumpfile("build/adxl345_reader.vcd");
        $dumpvars(0, tb_adxl345_reader);
`endif
        // Signed extremes first, then a deterministic pseudo-random stream.
        sensor.samples[0] = {16'sh8000, 16'sh7fff, 16'sh0000};
        sensor.samples[1] = {16'shffff, 16'sh0001, 16'sh0100};
        sensor.samples[2] = {16'sh1000, 16'shf000, 16'sh00e5};
        for (k = 3; k < SAMPLE_COUNT; k = k + 1) begin
            lfsr = lfsr ^ (lfsr << 13);
            lfsr = lfsr ^ (lfsr >> 17);
            lfsr = lfsr ^ (lfsr << 5);
            sensor.samples[k] = {lfsr[31:16], lfsr[15:0], lfsr[23:8]};
        end

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);
        check(!scl_drive_low && !sda_drive_low && !master_active,
              "reader releases the bus while disabled");

        // --- Identification, configuration and DATA_READY streaming. ---
        enable = 1'b1;
        wait (configured);
        check(device_id == 8'he5 && !id_error, "DEVID 0xE5 is read and accepted");
        check(sensor.regs[8'h2c] == 8'h0d, "BW_RATE configured for 800 Hz output");
        check(sensor.regs[8'h31] == 8'h0b, "DATA_FORMAT: full resolution, +/-16 g");
        check(sensor.regs[8'h2f] == 8'h00 && sensor.regs[8'h2e] == 8'h80,
              "DATA_READY interrupt routed to INT1");
        check(sensor.regs[8'h2d] == 8'h08, "POWER_CTL measure mode is written last");

        wait_samples(40);
        check(sample_mismatches == 0, "40 DATA_READY samples match the sensor bit-exactly");
        wait (!master_active);
        wait (master_active);
        t0 = $time;
        wait (!master_active);
        burst_ns = $time - t0;
        check(burst_ns < 1_250_000, "one 6-byte burst fits well inside the 1.25 ms sample period");

        // --- Clock stretching. ---
        sensor.stretch_ns = 5000;
        wait_samples(received + 6);
        sensor.stretch_ns = 0;
        check(sample_mismatches == 0, "samples stay exact while the sensor stretches SCL");
        check(stretch_cycles_seen > 200, "master waits for a stretched SCL before continuing");

        // --- NACK recovery: the stream resumes without losing a sample. ---
        count0 = received;
        wait (!master_active);
        sensor.nack_address = 1'b1;
        wait (sample_nack);
        @(posedge clk);
        sensor.nack_address = 1'b0;
        repeat (2) @(posedge clk);
        check(nack_count >= 1, "address NACK is reported to the protocol guard");
        wait (!configured);
        wait (configured);
        wait_samples(count0 + 8);
        check(sample_mismatches == 0 && !sensor.protocol_error,
              "reader re-initializes after NACK and the sequence continues unbroken");

        // --- Wrong device ID is rejected and nothing is streamed. ---
        enable = 1'b0;
        wait (!master_active && !configured);
        repeat (10) @(posedge clk);
        sensor.devid = 8'h00;
        count0 = received;
        enable = 1'b1;
        #(5_000_000);
        check(id_error && !configured && device_id == 8'h00 && received == count0,
              "wrong DEVID is flagged and produces no samples");
        sensor.devid = 8'he5;
        wait (configured);
        wait_samples(count0 + 4);
        check(!id_error && sample_mismatches == 0, "reader recovers once the correct sensor answers");

        // --- Stuck SDA: the master waits and does not claim the bus. ---
        wait (!master_active);
        sensor.hold_sda_low = 1'b1;
        count0 = received;
        #(3_000_000);
        check(!master_active && received == count0,
              "stuck SDA is not claimed by the master (guard can flag it)");
        sensor.hold_sda_low = 1'b0;
        wait_samples(count0 + 4);
        check(sample_mismatches == 0, "streaming resumes after the line is released");

        // --- Timer mode: SAMPLE_HZ polling without DATA_READY. ---
        enable = 1'b0;
        wait (!master_active && !configured);
        use_drdy = 1'b0;
        sensor.drdy_delay_ns = 1_000_000_000;  // INT1 effectively never asserts
        enable = 1'b1;
        wait (configured);
        count0 = received;
        #(10_000_000);
        check((received - count0) >= 7 && (received - count0) <= 9,
              "timer mode polls at 800 samples/s without DATA_READY");
        check(sample_mismatches == 0, "timer-mode samples match the sensor bit-exactly");

        // --- Bus-level summary. ---
        check(!sensor.protocol_error, "no START/STOP inside a byte (framing)");
        check(timing_errors == 0, "all I2C Fast-mode timing limits met");
        $display("INFO: %0d samples, %0d STARTs, burst %0d ns, min tLOW %0.0f ns, min tHIGH %0.0f ns, SCL %0.0f kHz max",
                 received, sensor.starts, burst_ns, min_low, min_high, 1.0e6 / min_period);

        if (failures == 0) begin
            $display("\nPASS: ADXL345 reader %0d checks, %0d samples bit-exact", checks, received);
            $finish;
        end else begin
            $fatal(1, "FAIL: %0d of %0d checks failed", failures, checks);
        end
    end

endmodule
