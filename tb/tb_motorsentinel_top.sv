`timescale 1ns/1ps

// Pins-to-motor integration test of motorsentinel_top.
//
// A behavioral ADXL345 on open-drain SCL/SDA serves the healthy-motor
// scenario stream from tools/generate_system_vectors.py. The bench loads the
// model over APB, arms the motor and checks that
//   * the reader configures the sensor and streams through the full core,
//   * window anomaly scores match the Python reference bit-exactly,
//   * real I2C traffic never trips the protocol guard (no false alarms),
//   * bus-level attacks on the real pins (NACK storm, stuck SDA) disable
//     the motor with the correct fault provenance.
// The fabric clock is reduced to keep simulation time short; the reader
// derives all I2C timing from CLK_HZ, so the protocol itself is unchanged.
module tb_motorsentinel_top;

    localparam integer CLK_HZ = 4_000_000;
    localparam integer HALF_PERIOD_NS = 125;
    localparam integer IMAGE_WORDS = 122;
    localparam integer WINDOWS = 2;

    localparam logic [7:0] REG_CONTROL          = 8'h04;
    localparam logic [7:0] REG_ANOM_THRESHOLD   = 8'h1c;
    localparam logic [7:0] REG_POLICY_CFG       = 8'h20;
    localparam logic [7:0] REG_FAULT_VECTOR     = 8'h38;
    localparam logic [7:0] REG_MODEL_CMD        = 8'h50;
    localparam logic [7:0] REG_MODEL_DATA       = 8'h54;
    localparam logic [7:0] REG_MODEL_CRC        = 8'h58;
    localparam logic [7:0] REG_MODEL_STATUS     = 8'h5c;
    localparam logic [7:0] REG_INTEGRITY_LIMITS = 8'h64;
    localparam logic [7:0] REG_INTEGRITY_CFG    = 8'h68;
    localparam logic [7:0] REG_INTEGRITY_STATUS = 8'h6c;
    localparam logic [7:0] REG_WINDOW_COUNT     = 8'h70;
    localparam logic [7:0] REG_ACQ_STATUS       = 8'he8;
    localparam logic [7:0] REG_ACQ_SAMPLES      = 8'hec;

    logic        clk = 1'b0;
    logic        rst_n = 1'b0;
    logic        psel = 1'b0;
    logic        penable = 1'b0;
    logic        pwrite = 1'b0;
    logic [7:0]  paddr = '0;
    logic [31:0] pwdata = '0;
    logic [31:0] prdata;
    logic        pready;
    logic        pslverr;
    logic        motor_enable;
    logic        fault_led;
    logic        irq;
    logic        scl_drive_low;
    logic        sda_drive_low;

    tri1 scl;
    tri1 sda;
    wire int1;

    always #(HALF_PERIOD_NS) clk = ~clk;

    assign scl = scl_drive_low ? 1'b0 : 1'bz;
    assign sda = sda_drive_low ? 1'b0 : 1'bz;

    motorsentinel_top #(
        .CLK_HZ(CLK_HZ)
    ) dut (
        .PCLK            (clk),
        .PRESETn         (rst_n),
        .PSEL            (psel),
        .PENABLE         (penable),
        .PWRITE          (pwrite),
        .PADDR           (paddr),
        .PWDATA          (pwdata),
        .PRDATA          (prdata),
        .PREADY          (pready),
        .PSLVERR         (pslverr),
        .scl_i           (scl),
        .sda_i           (sda),
        .scl_drive_low_o (scl_drive_low),
        .sda_drive_low_o (sda_drive_low),
        .adxl_int1_i     (int1),
        .motor_enable_o  (motor_enable),
        .fault_led_o     (fault_led),
        .irq_o           (irq)
    );

    adxl345_i2c_model sensor (
        .scl  (scl),
        .sda  (sda),
        .drdy (int1)
    );

    logic [31:0] image    [0:IMAGE_WORDS-1];
    logic [31:0] config_w [0:5];
    logic [47:0] stream   [0:9*2816-1];  // all scenarios; healthy is first
    logic [31:0] scores   [0:9*21-1];

    integer checks = 0;
    integer failures = 0;
    integer windows_seen = 0;
    integer k;
    logic [31:0] readback;
    logic        monitoring = 1'b0;

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

    task automatic apb_write(input logic [7:0] address, input logic [31:0] data);
        begin
            @(negedge clk);
            psel = 1'b1; penable = 1'b0; pwrite = 1'b1; paddr = address; pwdata = data;
            @(negedge clk);
            penable = 1'b1;
            @(negedge clk);
            psel = 1'b0; penable = 1'b0; pwrite = 1'b0;
        end
    endtask

    task automatic apb_read(input logic [7:0] address, output logic [31:0] data);
        begin
            @(negedge clk);
            psel = 1'b1; penable = 1'b0; pwrite = 1'b0; paddr = address;
            @(negedge clk);
            penable = 1'b1;
            #1 data = prdata;
            @(negedge clk);
            psel = 1'b0; penable = 1'b0;
        end
    endtask

    task automatic bring_up;
        integer word;
        begin
            @(negedge clk);
            rst_n = 1'b0;
            sensor.sample_index = 0;
            sensor.nack_address = 1'b0;
            sensor.hold_sda_low = 1'b0;
            repeat (4) @(negedge clk);
            rst_n = 1'b1;
            apb_write(REG_MODEL_CMD, 32'h1);
            for (word = 0; word < IMAGE_WORDS; word = word + 1)
                apb_write(REG_MODEL_DATA, image[word]);
            apb_write(REG_MODEL_CRC, config_w[0]);
            apb_write(REG_MODEL_CMD, 32'h2);
            apb_write(REG_ANOM_THRESHOLD, config_w[1]);
            apb_write(REG_POLICY_CFG, 32'h0003_0400 | config_w[5]);
            apb_write(REG_INTEGRITY_LIMITS, config_w[2]);
            apb_write(REG_INTEGRITY_CFG, config_w[3]);
            apb_read(REG_MODEL_STATUS, readback);
            check(readback[0], "model committed over APB");
            apb_write(REG_CONTROL, 32'h0000_0005);  // enable + arm
            repeat (2) @(negedge clk);
            check(motor_enable && !fault_led, "motor armed with a valid model");
        end
    endtask

    // Bit-exact check of every window decision while monitoring.
    always @(negedge clk) begin
        if (monitoring && dut.u_core.window_done) begin
            check(dut.u_core.score == scores[windows_seen][11:0],
                  "window score from the I2C pins matches Python bit-exactly");
            windows_seen = windows_seen + 1;
        end
    end

    // Safety invariant for the whole run.
    always @(negedge clk)
        if (rst_n && fault_led && motor_enable)
            $fatal(1, "safety invariant failed: trip did not disable motor");

    initial begin
`ifdef DUMP_WAVES
        $dumpfile("build/motorsentinel_top.vcd");
        $dumpvars(0, tb_motorsentinel_top);
`endif
        $readmemh("build/model_image.hex", image);
        $readmemh("build/system_config.hex", config_w);
        $readmemh("build/system_samples.hex", stream);
        $readmemh("build/system_scores.hex", scores);
        for (k = 0; k < 2816; k = k + 1)
            sensor.samples[k] = stream[k];
        sensor.drdy_delay_ns = 20_000;

        // --- Healthy motor through the real I2C path. ---
        bring_up();
        monitoring = 1'b1;
        wait (windows_seen == WINDOWS);
        repeat (20) @(negedge clk);
        monitoring = 1'b0;
        apb_read(REG_FAULT_VECTOR, readback);
        check(readback == 0 && motor_enable,
              "real I2C traffic raises no protocol, integrity or anomaly fault");
        apb_read(REG_ACQ_STATUS, readback);
        check(readback[7:0] == 8'he5 && readback[8] && !readback[9] && readback[10],
              "ACQ_STATUS reports DEVID 0xE5, configured, DATA_READY mode");
        apb_read(REG_ACQ_SAMPLES, readback);
        check(readback == dut.u_core.accepted_samples_q && readback >= 384,
              "every acquired sample entered the data plane (no overrun)");
        apb_read(REG_INTEGRITY_STATUS, readback);
        check(readback[4:0] == 0, "no integrity event on healthy acquisition");

        // --- Attack 1: the sensor bus NACKs every transaction. ---
        sensor.nack_address = 1'b1;
        wait (fault_led);
        apb_read(REG_FAULT_VECTOR, readback);
        check(readback[3] && !readback[4] && !motor_enable,
              "NACK storm on the real bus disables the motor (NACK-limit fault)");

        // --- Attack 2: SDA held low by a rogue device. ---
        bring_up();
        wait (dut.u_reader.configured_o);
        wait (!dut.u_reader.master_active_o);
        sensor.hold_sda_low = 1'b1;
        wait (fault_led);
        apb_read(REG_FAULT_VECTOR, readback);
        check((readback[1] || readback[5]) && !motor_enable,
              "SDA held low by another device disables the motor (stuck/rogue bus)");
        sensor.hold_sda_low = 1'b0;

        if (failures == 0) begin
            $display("\nPASS: pins-to-motor integration, %0d checks (%0d windows bit-exact)",
                     checks, WINDOWS);
            $finish;
        end else begin
            $fatal(1, "FAIL: %0d of %0d checks failed", failures, checks);
        end
    end

endmodule
