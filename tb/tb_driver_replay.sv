`timescale 1ns/1ps

// Replays the register traffic recorded from the C driver (libmotorsentinel)
// against the real motorsentinel_core_apb RTL.
//
// Trace lines (sw/tests/test_motorsentinel.c --trace):
//   W <offset> <value>          APB write
//   R <offset> <value> <mask>   APB read; (read & mask) must equal (value & mask)
//   P <offset> <mask> <value>   poll until (read & mask) == value
// The driver performs identify, model load, configuration, start and sample
// injection exactly as on the Icicle Kit. Afterwards the bench checks that the
// RTL committed the model, armed the motor and produced window scores equal to
// the Python reference.
module tb_driver_replay;

    localparam logic [7:0] REG_STATUS       = 8'h08;
    localparam logic [7:0] REG_FAULT_VECTOR = 8'h38;
    localparam logic [7:0] REG_WINDOW_COUNT = 8'h70;
    localparam integer POLL_LIMIT = 100_000;
    localparam integer WINDOWS = 2;

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

    always #10 clk = ~clk;

    motorsentinel_core_apb dut (
        .PCLK                (clk),
        .PRESETn             (rst_n),
        .PSEL                (psel),
        .PENABLE             (penable),
        .PWRITE              (pwrite),
        .PADDR               (paddr),
        .PWDATA              (pwdata),
        .PRDATA              (prdata),
        .PREADY              (pready),
        .PSLVERR             (pslverr),
        .scl_i               (1'b1),
        .sda_i               (1'b1),
        .i2c_master_active_i (1'b0),
        .i2c_scl_release_i   (1'b0),
        .sample_nack_i       (1'b0),
        .sample_valid_i      (1'b0),
        .sample_ready_o      (),
        .sample_x_i          (16'd0),
        .sample_y_i          (16'd0),
        .sample_z_i          (16'd0),
        .motor_enable_o      (motor_enable),
        .fault_led_o         (fault_led),
        .irq_o               (irq),
        .enable_o            (),
        .acq_use_drdy_o      (),
        .acq_status_i        (32'd0),
        .acq_samples_i       (32'd0)
    );

    logic [31:0] scores [0:9*21-1];

    integer checks = 0;
    integer failures = 0;
    integer writes = 0;
    integer reads = 0;
    integer polls = 0;
    integer windows_seen = 0;
    integer trace;
    integer fields;
    integer spins;
    logic   done;
    logic [7:0]  op;
    logic [31:0] offset;
    logic [31:0] value;
    logic [31:0] mask;
    logic [31:0] readback;

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (!condition) begin
                failures = failures + 1;
                $display("FAIL: %s (t=%0t)", message, $time);
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

    always @(negedge clk) begin
        if (rst_n && dut.window_done) begin
            check(dut.score == scores[windows_seen][11:0],
                  "window score driven by the C driver matches Python");
            windows_seen = windows_seen + 1;
        end
        if (rst_n && fault_led && motor_enable)
            $fatal(1, "safety invariant failed: trip did not disable motor");
    end

    initial begin
        $readmemh("build/system_scores.hex", scores);
        trace = $fopen("build/driver_trace.txt", "r");
        if (trace == 0)
            $fatal(1, "missing build/driver_trace.txt (run the C trace recorder)");

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        done = 1'b0;
        while (!done) begin
            fields = $fscanf(trace, " %c", op);
            if (fields != 1)
                done = 1'b1;
            else case (op)
                "W": begin
                    fields = $fscanf(trace, " %h %h", offset, value);
                    apb_write(offset[7:0], value);
                    writes = writes + 1;
                end
                "R": begin
                    fields = $fscanf(trace, " %h %h %h", offset, value, mask);
                    apb_read(offset[7:0], readback);
                    reads = reads + 1;
                    if (mask != 0) begin
                        check((readback & mask) == (value & mask),
                              "register read matches the driver's expectation");
                        if ((readback & mask) != (value & mask))
                            $display("  read 0x%02h: rtl %08h expected %08h mask %08h",
                                     offset[7:0], readback, value, mask);
                    end
                end
                "P": begin
                    fields = $fscanf(trace, " %h %h %h", offset, mask, value);
                    polls = polls + 1;
                    spins = 0;
                    apb_read(offset[7:0], readback);
                    while ((readback & mask) != value && spins < POLL_LIMIT) begin
                        apb_read(offset[7:0], readback);
                        spins = spins + 1;
                    end
                    check((readback & mask) == value, "driver wait condition is reached");
                    if ((readback & mask) != value)
                        $display("  poll 0x%02h timed out: %08h", offset[7:0], readback);
                end
                default: $fatal(1, "bad trace opcode %c", op);
            endcase
        end
        $fclose(trace);

        wait (!dut.latency_running_q);
        repeat (8) @(negedge clk);

        apb_read(REG_WINDOW_COUNT, readback);
        check(readback == WINDOWS && windows_seen == WINDOWS,
              "injected samples produced the expected windows");
        apb_read(REG_STATUS, readback);
        check(readback[8] && readback[7] && !readback[3],
              "driver start armed the motor with no trip");
        apb_read(REG_FAULT_VECTOR, readback);
        check(readback == 0, "no fault raised by driver-controlled operation");

        $display("INFO: replayed %0d writes, %0d reads, %0d polls from the C driver",
                 writes, reads, polls);
        if (failures == 0) begin
            $display("PASS: C driver drives the RTL correctly, %0d checks (%0d windows bit-exact)",
                     checks, WINDOWS);
            $finish;
        end else begin
            $fatal(1, "FAIL: %0d of %0d checks failed", failures, checks);
        end
    end

endmodule
