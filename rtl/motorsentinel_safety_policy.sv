`timescale 1ns/1ps

// Deterministic safety policy for the MotorSentinel-RV data plane.
// Faults latch independently of software. A clear request succeeds only after
// the configured number of healthy inference windows and an idle sensor bus.
module motorsentinel_safety_policy (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        enable_i,
    input  logic        arm_request_i,
    input  logic        disarm_request_i,
    input  logic        monitor_only_i,
    input  logic        clear_request_i,
    input  logic        model_valid_i,
    input  logic        bus_healthy_i,

    input  logic        window_valid_i,
    input  logic [31:0] anomaly_score_i,
    input  logic [31:0] anomaly_threshold_i,
    input  logic [7:0]  anomaly_confirm_i,
    input  logic [7:0]  recovery_windows_i,

    input  logic [5:0]  protocol_fault_i,
    input  logic        physical_fault_i,
    input  logic        internal_fault_i,

    output logic        motor_enable_o,
    output logic        armed_o,
    output logic        trip_o,
    output logic        data_valid_o,
    output logic [15:0] fault_vector_o,
    output logic        clear_accepted_o,
    output logic        clear_rejected_o
);

    localparam integer FAULT_PHYSICAL      = 6;
    localparam integer FAULT_INTERNAL      = 7;
    localparam integer FAULT_MODEL_INVALID = 8;
    localparam integer FAULT_ANOMALY       = 9;

    logic [7:0] anomaly_count_q;
    logic [7:0] recovery_count_q;

    wire [7:0] anomaly_confirm_eff =
        (anomaly_confirm_i == 0) ? 8'd1 : anomaly_confirm_i;
    wire [7:0] recovery_windows_eff =
        (recovery_windows_i == 0) ? 8'd1 : recovery_windows_i;

    wire healthy_window = window_valid_i && model_valid_i && bus_healthy_i &&
                          !physical_fault_i && !internal_fault_i &&
                          (anomaly_score_i <= anomaly_threshold_i);
    wire recovery_ready = recovery_count_q >= recovery_windows_eff;
    wire clear_allowed = trip_o && recovery_ready && model_valid_i &&
                         bus_healthy_i && !physical_fault_i &&
                         !internal_fault_i;

    assign clear_accepted_o = clear_request_i && clear_allowed;
    assign clear_rejected_o = clear_request_i && !clear_allowed;

    // monitor_only keeps the demonstration motor running while all fault and
    // data-valid semantics remain visible. Reset and an invalid model are
    // always safe regardless of this diagnostic mode.
    assign motor_enable_o = armed_o && model_valid_i &&
                            (monitor_only_i || !trip_o);
    assign data_valid_o = enable_i && model_valid_i && !trip_o;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            trip_o         <= 1'b0;
            armed_o        <= 1'b0;
            fault_vector_o <= '0;
            anomaly_count_q <= '0;
            recovery_count_q <= '0;
        end else begin
            if (!enable_i) begin
                armed_o <= 1'b0;
                anomaly_count_q <= '0;
                recovery_count_q <= '0;
            end else begin
                if (disarm_request_i)
                    armed_o <= 1'b0;

                if (arm_request_i && model_valid_i && bus_healthy_i &&
                    !trip_o && !disarm_request_i)
                    armed_o <= 1'b1;

                if (trip_o && healthy_window) begin
                    if (recovery_count_q < recovery_windows_eff)
                        recovery_count_q <= recovery_count_q + 1'b1;
                end else if (trip_o && window_valid_i) begin
                    recovery_count_q <= '0;
                end else if (!trip_o) begin
                    recovery_count_q <= '0;
                end

                if (window_valid_i) begin
                    if (anomaly_score_i > anomaly_threshold_i) begin
                        if (anomaly_count_q < anomaly_confirm_eff)
                            anomaly_count_q <= anomaly_count_q + 1'b1;
                        if ((anomaly_count_q + 1'b1) >= anomaly_confirm_eff) begin
                            trip_o <= 1'b1;
                            fault_vector_o[FAULT_ANOMALY] <= 1'b1;
                            if (!monitor_only_i)
                                armed_o <= 1'b0;
                        end
                    end else begin
                        anomaly_count_q <= '0;
                    end
                end

                if (protocol_fault_i != 0) begin
                    trip_o <= 1'b1;
                    fault_vector_o[5:0] <= fault_vector_o[5:0] |
                                                   protocol_fault_i;
                    if (!monitor_only_i)
                        armed_o <= 1'b0;
                end

                if (physical_fault_i) begin
                    trip_o <= 1'b1;
                    fault_vector_o[FAULT_PHYSICAL] <= 1'b1;
                    if (!monitor_only_i)
                        armed_o <= 1'b0;
                end

                if (internal_fault_i) begin
                    trip_o <= 1'b1;
                    fault_vector_o[FAULT_INTERNAL] <= 1'b1;
                    if (!monitor_only_i)
                        armed_o <= 1'b0;
                end

                if (!model_valid_i) begin
                    trip_o <= 1'b1;
                    fault_vector_o[FAULT_MODEL_INVALID] <= 1'b1;
                    armed_o <= 1'b0;
                end
            end

            // Recovery has priority over stale sticky fault inputs. The same
            // accepted pulse clears the protocol monitor on this clock edge.
            if (clear_accepted_o) begin
                trip_o          <= 1'b0;
                fault_vector_o  <= '0;
                anomaly_count_q <= '0;
                recovery_count_q <= '0;
            end
        end
    end

endmodule
