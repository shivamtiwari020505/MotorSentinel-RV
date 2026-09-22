`timescale 1ns/1ps

module tb_motorsentinel_guard;

    localparam logic [7:0] REG_ID_VERSION     = 8'h00;
    localparam logic [7:0] REG_CONTROL        = 8'h04;
    localparam logic [7:0] REG_STATUS         = 8'h08;
    localparam logic [7:0] REG_IRQ_STATUS     = 8'h0c;
    localparam logic [7:0] REG_IRQ_ENABLE     = 8'h10;
    localparam logic [7:0] REG_SAMPLE_CFG     = 8'h14;
    localparam logic [7:0] REG_BUS_TIMEOUT    = 8'h18;
    localparam logic [7:0] REG_ANOM_THRESHOLD = 8'h1c;
    localparam logic [7:0] REG_POLICY_CFG     = 8'h20;
    localparam logic [7:0] REG_FAULT_VECTOR   = 8'h38;

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

    logic scl = 1'b1;
    logic sda = 1'b1;
    logic i2c_master_active = 1'b0;
    logic i2c_scl_release = 1'b0;
    logic sample_complete = 1'b0;
    logic sample_nack = 1'b0;
    logic model_valid = 1'b0;
    logic window_valid = 1'b0;
    logic [31:0] anomaly_score = '0;
    logic physical_fault = 1'b0;
    logic internal_fault = 1'b0;

    logic motor_enable;
    logic fault_led;
    logic irq;

    integer checks = 0;
    integer failures = 0;
    integer i;
    logic [31:0] readback;

    always #5 clk = ~clk;

    motorsentinel_guard_apb #(
        // One simulated clock equals one monitor microsecond. This accelerates
        // timeout tests without changing the synthesizable logic.
        .CLK_HZ(1_000_000)
    ) dut (
        .PCLK                 (clk),
        .PRESETn              (rst_n),
        .PSEL                 (psel),
        .PENABLE              (penable),
        .PWRITE               (pwrite),
        .PADDR                (paddr),
        .PWDATA               (pwdata),
        .PRDATA               (prdata),
        .PREADY               (pready),
        .PSLVERR              (pslverr),
        .scl_i                (scl),
        .sda_i                (sda),
        .i2c_master_active_i  (i2c_master_active),
        .i2c_scl_release_i    (i2c_scl_release),
        .sample_complete_i    (sample_complete),
        .sample_nack_i        (sample_nack),
        .model_valid_i        (model_valid),
        .window_valid_i       (window_valid),
        .anomaly_score_i      (anomaly_score),
        .physical_fault_i     (physical_fault),
        .internal_fault_i     (internal_fault),
        .motor_enable_o       (motor_enable),
        .fault_led_o          (fault_led),
        .irq_o                (irq)
    );

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

    task automatic apb_write(input logic [7:0] address,
                             input logic [31:0] data);
        begin
            @(negedge clk);
            psel = 1'b1;
            penable = 1'b0;
            pwrite = 1'b1;
            paddr = address;
            pwdata = data;
            @(negedge clk);
            penable = 1'b1;
            @(negedge clk);
            psel = 1'b0;
            penable = 1'b0;
            pwrite = 1'b0;
            paddr = '0;
            pwdata = '0;
        end
    endtask

    task automatic apb_read(input logic [7:0] address,
                            output logic [31:0] data);
        begin
            @(negedge clk);
            psel = 1'b1;
            penable = 1'b0;
            pwrite = 1'b0;
            paddr = address;
            @(negedge clk);
            penable = 1'b1;
            #1 data = prdata;
            @(negedge clk);
            psel = 1'b0;
            penable = 1'b0;
            paddr = '0;
        end
    endtask

    task automatic pulse_window(input logic [31:0] score);
        begin
            @(negedge clk);
            anomaly_score = score;
            window_valid = 1'b1;
            sample_complete = 1'b1;
            @(negedge clk);
            window_valid = 1'b0;
            sample_complete = 1'b0;
        end
    endtask

    task automatic pulse_nack;
        begin
            @(negedge clk);
            sample_nack = 1'b1;
            @(negedge clk);
            sample_nack = 1'b0;
        end
    endtask

    task automatic recover_and_clear;
        begin
            for (i = 0; i < 4; i = i + 1)
                pulse_window(32'd4);
            apb_write(REG_CONTROL, 32'h0000_0003);
            repeat (2) @(posedge clk);
        end
    endtask

    task automatic arm_motor;
        begin
            apb_write(REG_CONTROL, 32'h0000_0005);
            repeat (2) @(posedge clk);
        end
    endtask

    // Continuous safety invariants.
    always @(negedge clk) begin
        if (rst_n && fault_led && !dut.monitor_only_q && motor_enable)
            $fatal(1, "safety invariant failed: trip did not disable motor");
        if (rst_n && !model_valid && motor_enable)
            $fatal(1, "safety invariant failed: invalid model enabled motor");
    end

    initial begin
`ifdef DUMP_WAVES
        $dumpfile("build/motorsentinel_guard.vcd");
        $dumpvars(0, tb_motorsentinel_guard);
`endif

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        check(!motor_enable, "motor is disabled after reset");
        check(!fault_led, "trip latch is clear after reset");
        check(pready && !pslverr, "APB slave is zero-wait-state and error-free");

        apb_read(REG_ID_VERSION, readback);
        check(readback == 32'h4d53_0100, "core ID and version are readable");
        apb_read(8'hfc, readback);
        check(readback == 0 && !pslverr,
              "unimplemented APB address returns zero without a bus fault");

        apb_write(REG_IRQ_ENABLE, 32'h0000_000f);
        apb_write(REG_SAMPLE_CFG, 32'd0); // Disable missing-sample timeout here.
        apb_write(REG_ANOM_THRESHOLD, 32'd10);
        apb_write(REG_POLICY_CFG, 32'h0003_0402); // NACK=3, recovery=4, confirm=2.

        // Enabling without an atomically committed model must fail safe.
        apb_write(REG_CONTROL, 32'h0000_0005);
        repeat (2) @(posedge clk);
        check(fault_led, "invalid model trips an enabled core");
        apb_read(REG_FAULT_VECTOR, readback);
        check(readback[8], "fault vector records invalid model");
        check(irq, "trip raises enabled interrupt");

        model_valid = 1'b1;
        recover_and_clear();
        check(!fault_led && !motor_enable,
              "recovery clears trip without automatically restarting motor");
        arm_motor();
        check(motor_enable, "explicit arm starts motor after recovery");

        // Learned anomalies require consecutive confirmation.
        pulse_window(32'd11);
        check(!fault_led, "first anomalous window does not trip");
        pulse_window(32'd12);
        repeat (2) @(posedge clk);
        check(fault_led && !motor_enable, "second anomalous window trips motor");
        apb_read(REG_FAULT_VECTOR, readback);
        check(readback[9], "fault vector records learned anomaly");

        apb_write(REG_CONTROL, 32'h0000_0003);
        repeat (2) @(posedge clk);
        check(fault_led, "premature clear request is rejected");
        apb_read(REG_IRQ_STATUS, readback);
        check(readback[2], "rejected clear is reported in IRQ status");
        recover_and_clear();
        check(!fault_led && !motor_enable,
              "anomaly trip clears but remains explicitly disarmed");
        arm_motor();

        // Three consecutive transaction NACKs produce an immediate protocol trip.
        pulse_nack();
        pulse_nack();
        pulse_nack();
        repeat (3) @(posedge clk);
        check(fault_led, "configured NACK streak trips protocol guard");
        apb_read(REG_FAULT_VECTOR, readback);
        check(readback[3], "fault vector records NACK-limit fault");
        recover_and_clear();
        check(!fault_led, "protocol trip clears only after healthy recovery");
        arm_motor();

        // Monitor-only is explicit: faults remain latched but output is not driven low.
        apb_write(REG_CONTROL, 32'h0000_0011);
        @(negedge clk);
        physical_fault = 1'b1;
        @(negedge clk);
        physical_fault = 1'b0;
        repeat (2) @(posedge clk);
        check(fault_led && motor_enable,
              "monitor-only records fault without disabling demonstration motor");
        recover_and_clear();
        apb_write(REG_CONTROL, 32'h0000_0005);

        // SDA held low outside an owned transfer is first unexpected activity,
        // then a timed stuck-line fault. Both causes must remain recorded.
        apb_write(REG_BUS_TIMEOUT, 32'h0003_0002); // stuck=3 us, stretch=2 us.
        @(negedge clk);
        sda = 1'b0;
        repeat (7) @(posedge clk);
        check(fault_led, "unowned SDA low condition trips guard");
        apb_read(REG_FAULT_VECTOR, readback);
        check(readback[1] && readback[5],
              "fault vector records stuck SDA and unexpected activity");
        @(negedge clk);
        sda = 1'b1;
        repeat (4) @(posedge clk);
        recover_and_clear();
        arm_motor();

        // A master waiting for released SCL detects excessive clock stretching.
        @(negedge clk);
        i2c_master_active = 1'b1;
        i2c_scl_release = 1'b1;
        scl = 1'b0;
        repeat (6) @(posedge clk);
        check(fault_led, "excessive I2C clock stretch trips guard");
        apb_read(REG_FAULT_VECTOR, readback);
        check(readback[2], "fault vector records clock-stretch timeout");
        @(negedge clk);
        scl = 1'b1;
        i2c_scl_release = 1'b0;
        i2c_master_active = 1'b0;
        repeat (4) @(posedge clk);
        recover_and_clear();
        arm_motor();

        // SCL held low while the master is idle uses the independent stuck-line path.
        @(negedge clk);
        scl = 1'b0;
        repeat (7) @(posedge clk);
        check(fault_led, "unowned SCL stuck-low condition trips guard");
        apb_read(REG_FAULT_VECTOR, readback);
        check(readback[0], "fault vector records stuck SCL");
        @(negedge clk);
        scl = 1'b1;
        repeat (4) @(posedge clk);
        recover_and_clear();
        arm_motor();

        // Missing complete samples are timed independently of bus-line health.
        apb_write(REG_SAMPLE_CFG, 32'd3);
        repeat (6) @(posedge clk);
        check(fault_led, "missing-sample timeout trips guard");
        apb_read(REG_FAULT_VECTOR, readback);
        check(readback[4], "fault vector records missing sample");
        apb_write(REG_SAMPLE_CFG, 32'd0);
        recover_and_clear();
        arm_motor();

        apb_read(REG_STATUS, readback);
        check(readback[8] && readback[7] && readback[6] && !readback[3],
              "final status reports armed motor, healthy bus and no trip");

        apb_write(REG_IRQ_STATUS, 32'h0000_000f);
        repeat (2) @(posedge clk);
        check(!irq, "write-one-to-clear removes all handled IRQ causes");

        if (failures == 0) begin
            $display("\nPASS: %0d checks completed", checks);
            $finish;
        end else begin
            $fatal(1, "FAIL: %0d of %0d checks failed", failures, checks);
        end
    end

endmodule
