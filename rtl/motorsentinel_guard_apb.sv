`timescale 1ns/1ps

// APB3-integrated vertical slice of the MotorSentinel-RV safety path.
module motorsentinel_guard_apb #(
    parameter integer CLK_HZ = 50_000_000
) (
    input  logic        PCLK,
    input  logic        PRESETn,
    input  logic        PSEL,
    input  logic        PENABLE,
    input  logic        PWRITE,
    input  logic [7:0]  PADDR,
    input  logic [31:0] PWDATA,
    output logic [31:0] PRDATA,
    output logic        PREADY,
    output logic        PSLVERR,

    input  logic        scl_i,
    input  logic        sda_i,
    input  logic        i2c_master_active_i,
    input  logic        i2c_scl_release_i,
    input  logic        sample_complete_i,
    input  logic        sample_nack_i,

    input  logic        model_valid_i,
    input  logic        window_valid_i,
    input  logic [31:0] anomaly_score_i,
    input  logic        physical_fault_i,
    input  logic        internal_fault_i,

    output logic        motor_enable_o,
    output logic        fault_led_o,
    output logic        irq_o
);

    localparam logic [7:0] REG_ID_VERSION     = 8'h00;
    localparam logic [7:0] REG_CONTROL        = 8'h04;
    localparam logic [7:0] REG_STATUS         = 8'h08;
    localparam logic [7:0] REG_IRQ_STATUS     = 8'h0c;
    localparam logic [7:0] REG_IRQ_ENABLE     = 8'h10;
    localparam logic [7:0] REG_SAMPLE_CFG     = 8'h14;
    localparam logic [7:0] REG_BUS_TIMEOUT    = 8'h18;
    localparam logic [7:0] REG_ANOM_THRESHOLD = 8'h1c;
    localparam logic [7:0] REG_POLICY_CFG     = 8'h20;
    localparam logic [7:0] REG_ANOM_SCORE     = 8'h34;
    localparam logic [7:0] REG_FAULT_VECTOR   = 8'h38;

    logic        enable_q;
    logic        monitor_only_q;
    logic        arm_request_q;
    logic        disarm_request_q;
    logic        clear_request_q;
    logic [3:0]  irq_status_q;
    logic [3:0]  irq_enable_q;
    logic [31:0] sample_timeout_us_q;
    logic [15:0] stretch_limit_us_q;
    logic [15:0] stuck_limit_us_q;
    logic [31:0] anomaly_threshold_q;
    logic [7:0]  anomaly_confirm_q;
    logic [7:0]  recovery_windows_q;
    logic [7:0]  nack_limit_q;

    logic [5:0]  protocol_fault;
    logic        bus_idle;
    logic        bus_healthy;
    logic        trip;
    logic        data_valid;
    logic        armed;
    logic [15:0] fault_vector;
    logic        clear_accepted;
    logic        clear_rejected;
    logic        trip_d_q;

    wire apb_write = PSEL && PENABLE && PWRITE;
    wire [3:0] irq_events = {
        (protocol_fault != 0),
        clear_rejected,
        clear_accepted,
        (trip && !trip_d_q)
    };

    assign PREADY = 1'b1;
    assign PSLVERR = 1'b0;
    assign fault_led_o = trip;
    assign irq_o = |(irq_status_q & irq_enable_q);

    motorsentinel_protocol_guard #(
        .CLK_HZ(CLK_HZ)
    ) u_protocol_guard (
        .clk                 (PCLK),
        .rst_n               (PRESETn),
        .enable_i            (enable_q),
        .clear_i             (clear_accepted),
        .scl_i               (scl_i),
        .sda_i               (sda_i),
        .master_active_i     (i2c_master_active_i),
        .scl_release_i       (i2c_scl_release_i),
        .sample_complete_i   (sample_complete_i),
        .sample_nack_i       (sample_nack_i),
        .stretch_limit_us_i  (stretch_limit_us_q),
        .stuck_limit_us_i    (stuck_limit_us_q),
        .sample_timeout_us_i (sample_timeout_us_q),
        .nack_limit_i        (nack_limit_q),
        .fault_o             (protocol_fault),
        .bus_idle_o          (bus_idle),
        .bus_healthy_o       (bus_healthy)
    );

    motorsentinel_safety_policy u_safety_policy (
        .clk                 (PCLK),
        .rst_n               (PRESETn),
        .enable_i            (enable_q),
        .arm_request_i       (arm_request_q),
        .disarm_request_i    (disarm_request_q),
        .monitor_only_i      (monitor_only_q),
        .clear_request_i     (clear_request_q),
        .model_valid_i       (model_valid_i),
        .bus_healthy_i       (bus_healthy),
        .window_valid_i      (window_valid_i),
        .anomaly_score_i     (anomaly_score_i),
        .anomaly_threshold_i (anomaly_threshold_q),
        .anomaly_confirm_i   (anomaly_confirm_q),
        .recovery_windows_i  (recovery_windows_q),
        .protocol_fault_i    (protocol_fault),
        .physical_fault_i    (physical_fault_i),
        .internal_fault_i    (internal_fault_i),
        .motor_enable_o      (motor_enable_o),
        .armed_o             (armed),
        .trip_o              (trip),
        .data_valid_o        (data_valid),
        .fault_vector_o      (fault_vector),
        .clear_accepted_o    (clear_accepted),
        .clear_rejected_o    (clear_rejected)
    );

    always_ff @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            enable_q              <= 1'b0;
            monitor_only_q        <= 1'b0;
            arm_request_q          <= 1'b0;
            disarm_request_q       <= 1'b0;
            clear_request_q       <= 1'b0;
            irq_status_q          <= '0;
            irq_enable_q          <= '0;
            sample_timeout_us_q   <= 32'd2500;
            stretch_limit_us_q    <= 16'd100;
            stuck_limit_us_q      <= 16'd1000;
            anomaly_threshold_q   <= 32'd1000;
            anomaly_confirm_q     <= 8'd2;
            recovery_windows_q    <= 8'd4;
            nack_limit_q          <= 8'd3;
            trip_d_q              <= 1'b0;
        end else begin
            clear_request_q <= 1'b0;
            arm_request_q <= 1'b0;
            disarm_request_q <= 1'b0;
            trip_d_q <= trip;

            if (apb_write && PADDR == REG_CONTROL) begin
                enable_q       <= PWDATA[0];
                clear_request_q <= PWDATA[1];
                arm_request_q   <= PWDATA[2];
                disarm_request_q <= PWDATA[3];
                monitor_only_q <= PWDATA[4];
            end
            if (apb_write && PADDR == REG_IRQ_ENABLE)
                irq_enable_q <= PWDATA[3:0];
            if (apb_write && PADDR == REG_SAMPLE_CFG)
                sample_timeout_us_q <= PWDATA;
            if (apb_write && PADDR == REG_BUS_TIMEOUT) begin
                stretch_limit_us_q <= PWDATA[15:0];
                stuck_limit_us_q   <= PWDATA[31:16];
            end
            if (apb_write && PADDR == REG_ANOM_THRESHOLD)
                anomaly_threshold_q <= PWDATA;
            if (apb_write && PADDR == REG_POLICY_CFG) begin
                anomaly_confirm_q  <= PWDATA[7:0];
                recovery_windows_q <= PWDATA[15:8];
                nack_limit_q       <= PWDATA[23:16];
            end

            if (apb_write && PADDR == REG_IRQ_STATUS)
                irq_status_q <= (irq_status_q & ~PWDATA[3:0]) | irq_events;
            else
                irq_status_q <= irq_status_q | irq_events;
        end
    end

    always_comb begin
        PRDATA = 32'h0000_0000;
        case (PADDR)
            REG_ID_VERSION:     PRDATA = 32'h4d53_0100; // "MS", v1.0
            REG_CONTROL:        PRDATA = {27'd0, monitor_only_q, 3'd0,
                                          enable_q};
            REG_STATUS:         PRDATA = {23'd0, armed, motor_enable_o,
                                          bus_healthy, monitor_only_q,
                                          data_valid, trip, window_valid_i,
                                          model_valid_i, 1'b1};
            REG_IRQ_STATUS:     PRDATA = {28'd0, irq_status_q};
            REG_IRQ_ENABLE:     PRDATA = {28'd0, irq_enable_q};
            REG_SAMPLE_CFG:     PRDATA = sample_timeout_us_q;
            REG_BUS_TIMEOUT:    PRDATA = {stuck_limit_us_q,
                                          stretch_limit_us_q};
            REG_ANOM_THRESHOLD: PRDATA = anomaly_threshold_q;
            REG_POLICY_CFG:     PRDATA = {8'd0, nack_limit_q,
                                          recovery_windows_q,
                                          anomaly_confirm_q};
            REG_ANOM_SCORE:     PRDATA = anomaly_score_i;
            REG_FAULT_VECTOR:   PRDATA = {16'd0, fault_vector};
            default:            PRDATA = 32'h0000_0000;
        endcase
    end

endmodule
