`timescale 1ns/1ps

// MotorSentinel-RV integrated FPGA data plane (Libero top-level candidate).
//
// One 256-byte APB3 slot:
//   0x00-0x3f  verified Milestone 1 safety kernel (motorsentinel_guard_apb)
//   0x40-0xff  data-plane extension: model store, integrity monitor, sample
//              injection, latency instrumentation and inference telemetry
//
// Data path, entirely in fabric and independent of Linux:
//   samples -> integrity monitor --------------------------> physical fault
//           -> feature extractor -> normalizer -> EdgeMatrix-RV -> score
//   score + protocol faults + physical faults -> safety policy -> motor
module motorsentinel_core_apb #(
    parameter integer CLK_HZ = 50_000_000
) (
    input  logic               PCLK,
    input  logic               PRESETn,
    input  logic               PSEL,
    input  logic               PENABLE,
    input  logic               PWRITE,
    input  logic [7:0]         PADDR,
    input  logic [31:0]        PWDATA,
    output logic [31:0]        PRDATA,
    output logic               PREADY,
    output logic               PSLVERR,

    // I2C line observation and acquisition-master status.
    input  logic               scl_i,
    input  logic               sda_i,
    input  logic               i2c_master_active_i,
    input  logic               i2c_scl_release_i,
    input  logic               sample_nack_i,

    // Accelerometer sample stream from the acquisition block. The producer
    // cannot be stalled at 800 samples/s; a sample offered while not ready is
    // dropped and reported as an internal overrun fault.
    input  logic               sample_valid_i,
    output logic               sample_ready_o,
    input  logic signed [15:0] sample_x_i,
    input  logic signed [15:0] sample_y_i,
    input  logic signed [15:0] sample_z_i,

    output logic               motor_enable_o,
    output logic               fault_led_o,
    output logic               irq_o
);

    localparam logic [7:0] REG_CORE_ID          = 8'h40;
    localparam logic [7:0] REG_CORE_CONTROL     = 8'h44;
    localparam logic [7:0] REG_INJECT_XY        = 8'h48;
    localparam logic [7:0] REG_INJECT_Z         = 8'h4c;
    localparam logic [7:0] REG_MODEL_CMD        = 8'h50;
    localparam logic [7:0] REG_MODEL_DATA       = 8'h54;
    localparam logic [7:0] REG_MODEL_CRC        = 8'h58;
    localparam logic [7:0] REG_MODEL_STATUS     = 8'h5c;
    localparam logic [7:0] REG_MODEL_CRC_ACTUAL = 8'h60;
    localparam logic [7:0] REG_INTEGRITY_LIMITS = 8'h64;
    localparam logic [7:0] REG_INTEGRITY_CFG    = 8'h68;
    localparam logic [7:0] REG_INTEGRITY_STATUS = 8'h6c;
    localparam logic [7:0] REG_WINDOW_COUNT     = 8'h70;
    localparam logic [7:0] REG_LAST_SEQUENCE    = 8'h74;
    localparam logic [7:0] REG_LATENCY          = 8'h78;
    localparam logic [7:0] REG_INFERENCE_STATUS = 8'h7c;
    localparam logic [7:0] REG_FEATURE_BASE     = 8'h80;  // 16 words
    localparam logic [7:0] REG_Q_BASE           = 8'hc0;  // 4 words
    localparam logic [7:0] REG_Y_BASE           = 8'hd0;  // 4 words
    localparam logic [7:0] REG_H_BASE           = 8'he0;  // 2 words

    // ------------------------------------------------------------------
    // APB split
    // ------------------------------------------------------------------
    wire        guard_select = (PADDR[7:6] == 2'b00);
    wire        ext_write = PSEL && PENABLE && PWRITE && !guard_select;
    logic [31:0] guard_prdata;
    logic        guard_pready;
    logic        guard_pslverr;
    logic [31:0] ext_prdata;

    assign PREADY  = 1'b1;
    assign PSLVERR = 1'b0;
    assign PRDATA  = guard_select ? guard_prdata : ext_prdata;

    // ------------------------------------------------------------------
    // Extension registers
    // ------------------------------------------------------------------
    logic        inject_mode_q;
    logic [15:0] inject_x_q;
    logic [15:0] inject_y_q;
    logic [31:0] expected_crc_q;
    logic [15:0] range_limit_q;
    logic [15:0] slew_limit_q;
    logic [7:0]  frozen_limit_q;
    logic [7:0]  replay_threshold_q;
    logic [4:0]  integrity_status_q;
    logic [31:0] window_count_q;
    logic [31:0] accepted_samples_q;
    logic        latency_running_q;
    logic [15:0] latency_count_q;
    logic [15:0] last_latency_q;
    logic [15:0] max_latency_q;

    wire inject_push  = ext_write && PADDR == REG_INJECT_Z;
    wire model_begin  = ext_write && PADDR == REG_MODEL_CMD && PWDATA[0];
    wire model_commit = ext_write && PADDR == REG_MODEL_CMD && PWDATA[1];
    wire model_write  = ext_write && PADDR == REG_MODEL_DATA;

    // ------------------------------------------------------------------
    // Sample source selection and flow control
    // ------------------------------------------------------------------
    logic               enable;
    logic               feature_sample_ready;
    logic               integrity_ready;
    logic               sample_valid;
    logic signed [15:0] sample_x;
    logic signed [15:0] sample_y;
    logic signed [15:0] sample_z;

    wire datapath_ready = enable && feature_sample_ready && integrity_ready;

    always_comb begin
        if (inject_mode_q) begin
            sample_valid = inject_push;
            sample_x = inject_x_q;
            sample_y = inject_y_q;
            sample_z = PWDATA[15:0];
        end else begin
            sample_valid = sample_valid_i;
            sample_x = sample_x_i;
            sample_y = sample_y_i;
            sample_z = sample_z_i;
        end
    end

    assign sample_ready_o = !inject_mode_q && datapath_ready;
    wire sample_fire = sample_valid && datapath_ready;
    wire sample_overrun = enable && sample_valid && !datapath_ready;

    // ------------------------------------------------------------------
    // Model store
    // ------------------------------------------------------------------
    logic          model_valid;
    logic          model_loading;
    logic [7:0]    model_words;
    logic [31:0]   model_crc;
    logic [4:0]    model_error;
    logic [511:0]  offset;
    logic [255:0]  scale;
    logic [95:0]   norm_shift;
    logic [1023:0] w1;
    logic [1023:0] w2;
    logic [255:0]  b1;
    logic [511:0]  b2;
    logic [5:0]    s1;
    logic [5:0]    s2;

    motorsentinel_model_store u_model_store (
        .clk            (PCLK),
        .rst_n          (PRESETn),
        .begin_i        (model_begin),
        .commit_i       (model_commit),
        .data_write_i   (model_write),
        .data_i         (PWDATA),
        .expected_crc_i (expected_crc_q),
        .model_valid_o  (model_valid),
        .loading_o      (model_loading),
        .words_o        (model_words),
        .crc_o          (model_crc),
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

    // ------------------------------------------------------------------
    // Sensor-integrity monitor
    // ------------------------------------------------------------------
    logic       integrity_event_valid;
    logic [3:0] integrity_events;
    logic       frozen_active;
    logic [7:0] replay_block_hits;

    motorsentinel_integrity_monitor u_integrity (
        .clk                (PCLK),
        .rst_n              (PRESETn),
        .enable_i           (enable),
        .sample_valid_i     (sample_fire),
        .sample_ready_o     (integrity_ready),
        .sample_x_i         (sample_x),
        .sample_y_i         (sample_y),
        .sample_z_i         (sample_z),
        .range_limit_i      (range_limit_q),
        .slew_limit_i       (slew_limit_q),
        .frozen_limit_i     (frozen_limit_q),
        .replay_threshold_i (replay_threshold_q),
        .event_valid_o      (integrity_event_valid),
        .events_o           (integrity_events),
        .frozen_active_o    (frozen_active),
        .block_hits_o       (replay_block_hits)
    );

    wire physical_fault = frozen_active ||
                          (integrity_event_valid && (integrity_events != 0));

    // ------------------------------------------------------------------
    // Feature extraction and EdgeMatrix-RV inference
    // ------------------------------------------------------------------
    logic        feature_valid;
    logic        feature_ready;
    logic [3:0]  feature_index;
    logic [31:0] feature_data;
    logic        feature_last;
    logic [31:0] feature_sequence;
    logic [1:0]  queued_windows;

    motorsentinel_feature_extractor u_features (
        .clk               (PCLK),
        .rst_n             (PRESETn),
        .enable_i          (enable),
        .sample_valid_i    (sample_fire),
        .sample_ready_o    (feature_sample_ready),
        .sample_x_i        (sample_x),
        .sample_y_i        (sample_y),
        .sample_z_i        (sample_z),
        .feature_valid_o   (feature_valid),
        .feature_ready_i   (feature_ready),
        .feature_index_o   (feature_index),
        .feature_data_o    (feature_data),
        .feature_last_o    (feature_last),
        .window_sequence_o (feature_sequence),
        .queued_windows_o  (queued_windows)
    );

    logic          window_done;
    logic [11:0]   score;
    logic [31:0]   score_sequence;
    logic [511:0]  window_features;
    logic [127:0]  window_q;
    logic [63:0]   window_h;
    logic [127:0]  window_y;
    logic          inference_busy;

    motorsentinel_inference u_inference (
        .clk               (PCLK),
        .rst_n             (PRESETn),
        .enable_i          (enable),
        .model_valid_i     (model_valid),
        .feature_valid_i   (feature_valid),
        .feature_ready_o   (feature_ready),
        .feature_index_i   (feature_index),
        .feature_data_i    (feature_data),
        .feature_last_i    (feature_last),
        .window_sequence_i (feature_sequence),
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
        .busy_o            (inference_busy)
    );

    // ------------------------------------------------------------------
    // Verified safety kernel
    // ------------------------------------------------------------------
    motorsentinel_guard_apb #(
        .CLK_HZ(CLK_HZ)
    ) u_guard (
        .PCLK                (PCLK),
        .PRESETn             (PRESETn),
        .PSEL                (PSEL && guard_select),
        .PENABLE             (PENABLE),
        .PWRITE              (PWRITE),
        .PADDR               (PADDR),
        .PWDATA              (PWDATA),
        .PRDATA              (guard_prdata),
        .PREADY              (guard_pready),
        .PSLVERR             (guard_pslverr),
        .scl_i               (scl_i),
        .sda_i               (sda_i),
        .i2c_master_active_i (i2c_master_active_i),
        .i2c_scl_release_i   (i2c_scl_release_i),
        .sample_complete_i   (sample_fire),
        .sample_nack_i       (sample_nack_i),
        .model_valid_i       (model_valid),
        .window_valid_i      (window_done),
        .anomaly_score_i     ({20'd0, score}),
        .physical_fault_i    (physical_fault),
        .internal_fault_i    (sample_overrun),
        .motor_enable_o      (motor_enable_o),
        .fault_led_o         (fault_led_o),
        .irq_o               (irq_o),
        .enable_o            (enable)
    );

    // ------------------------------------------------------------------
    // Extension register state and latency instrumentation
    // ------------------------------------------------------------------
    // A window closes on accepted sample 256 and every 128 samples after it.
    wire [31:0] accepted_next = accepted_samples_q + 1'b1;
    wire window_closes = sample_fire && (accepted_next >= 32'd256) &&
                         (accepted_next[6:0] == 7'd0);

    always_ff @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            inject_mode_q      <= 1'b0;
            inject_x_q         <= '0;
            inject_y_q         <= '0;
            expected_crc_q     <= '0;
            range_limit_q      <= 16'd4000;
            slew_limit_q       <= 16'd1024;
            frozen_limit_q     <= 8'd32;
            replay_threshold_q <= 8'd16;
            integrity_status_q <= '0;
            window_count_q     <= '0;
            accepted_samples_q <= '0;
            latency_running_q  <= 1'b0;
            latency_count_q    <= '0;
            last_latency_q     <= '0;
            max_latency_q      <= '0;
        end else begin
            if (ext_write) begin
                case (PADDR)
                    REG_CORE_CONTROL: inject_mode_q <= PWDATA[0];
                    REG_INJECT_XY: begin
                        inject_x_q <= PWDATA[15:0];
                        inject_y_q <= PWDATA[31:16];
                    end
                    REG_MODEL_CRC: expected_crc_q <= PWDATA;
                    REG_INTEGRITY_LIMITS: begin
                        range_limit_q <= PWDATA[15:0];
                        slew_limit_q  <= PWDATA[31:16];
                    end
                    REG_INTEGRITY_CFG: begin
                        frozen_limit_q     <= PWDATA[7:0];
                        replay_threshold_q <= PWDATA[15:8];
                    end
                    default: ;
                endcase
            end

            if (ext_write && PADDR == REG_INTEGRITY_STATUS)
                integrity_status_q <= integrity_status_q & ~PWDATA[4:0];
            if (integrity_event_valid)
                integrity_status_q[3:0] <= integrity_status_q[3:0] | integrity_events;
            if (sample_overrun)
                integrity_status_q[4] <= 1'b1;

            if (!enable) begin
                accepted_samples_q <= '0;
                latency_running_q  <= 1'b0;
            end else begin
                if (sample_fire)
                    accepted_samples_q <= accepted_next;
                if (window_closes) begin
                    latency_running_q <= 1'b1;
                    latency_count_q   <= 16'd1;
                end else if (latency_running_q) begin
                    if (window_done) begin
                        latency_running_q <= 1'b0;
                        last_latency_q <= latency_count_q;
                        if (latency_count_q > max_latency_q)
                            max_latency_q <= latency_count_q;
                    end else if (latency_count_q != 16'hffff) begin
                        latency_count_q <= latency_count_q + 1'b1;
                    end
                end
            end

            if (window_done)
                window_count_q <= window_count_q + 1'b1;
        end
    end

    always_comb begin
        ext_prdata = 32'h0000_0000;
        if (PADDR >= REG_FEATURE_BASE && PADDR < REG_Q_BASE)
            ext_prdata = window_features[PADDR[5:2]*32 +: 32];
        else if (PADDR >= REG_Q_BASE && PADDR < REG_Q_BASE + 8'h10)
            ext_prdata = window_q[PADDR[3:2]*32 +: 32];
        else if (PADDR >= REG_Y_BASE && PADDR < REG_Y_BASE + 8'h10)
            ext_prdata = window_y[PADDR[3:2]*32 +: 32];
        else if (PADDR >= REG_H_BASE && PADDR < REG_H_BASE + 8'h08)
            ext_prdata = window_h[PADDR[2]*32 +: 32];
        else begin
            case (PADDR)
                REG_CORE_ID:          ext_prdata = 32'h4d53_0300; // "MS", data plane v3.0
                REG_CORE_CONTROL:     ext_prdata = {31'd0, inject_mode_q};
                REG_INJECT_XY:        ext_prdata = {inject_y_q, inject_x_q};
                REG_MODEL_CRC:        ext_prdata = expected_crc_q;
                REG_MODEL_STATUS:     ext_prdata = {8'd0, model_words, 3'd0,
                                                    model_error, 6'd0,
                                                    model_loading, model_valid};
                REG_MODEL_CRC_ACTUAL: ext_prdata = model_crc;
                REG_INTEGRITY_LIMITS: ext_prdata = {slew_limit_q, range_limit_q};
                REG_INTEGRITY_CFG:    ext_prdata = {16'd0, replay_threshold_q,
                                                    frozen_limit_q};
                REG_INTEGRITY_STATUS: ext_prdata = {16'd0, replay_block_hits,
                                                    3'd0, integrity_status_q};
                REG_WINDOW_COUNT:     ext_prdata = window_count_q;
                REG_LAST_SEQUENCE:    ext_prdata = score_sequence;
                REG_LATENCY:          ext_prdata = {max_latency_q, last_latency_q};
                REG_INFERENCE_STATUS: ext_prdata = {11'd0, datapath_ready,
                                                    queued_windows,
                                                    inference_busy, frozen_active,
                                                    4'd0, score};
                default:              ext_prdata = 32'h0000_0000;
            endcase
        end
    end

endmodule
