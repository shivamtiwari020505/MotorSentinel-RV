`timescale 1ns/1ps

// MotorSentinel-RV sensor-bus watchdog.
//
// SCL and SDA are synchronized internally. Timeout configuration is expressed
// in microseconds so the software-visible values do not depend on fabric clock
// frequency. Fault outputs are sticky and are cleared only after the safety
// policy accepts an explicit recovery request.
module motorsentinel_protocol_guard #(
    parameter integer CLK_HZ = 50_000_000
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        enable_i,
    input  logic        clear_i,

    input  logic        scl_i,
    input  logic        sda_i,
    input  logic        master_active_i,
    input  logic        scl_release_i,
    input  logic        sample_complete_i,
    input  logic        sample_nack_i,

    input  logic [15:0] stretch_limit_us_i,
    input  logic [15:0] stuck_limit_us_i,
    input  logic [31:0] sample_timeout_us_i,
    input  logic [7:0]  nack_limit_i,

    output logic [5:0]  fault_o,
    output logic        bus_idle_o,
    output logic        bus_healthy_o
);

    localparam integer US_DIV = (CLK_HZ < 1_000_000) ? 1 : (CLK_HZ / 1_000_000);
    localparam integer US_DIV_W = (US_DIV <= 1) ? 1 : $clog2(US_DIV);

    localparam integer FAULT_SCL_STUCK  = 0;
    localparam integer FAULT_SDA_STUCK  = 1;
    localparam integer FAULT_STRETCH    = 2;
    localparam integer FAULT_NACK_LIMIT = 3;
    localparam integer FAULT_NO_SAMPLE  = 4;
    localparam integer FAULT_UNEXPECTED = 5;

    logic [US_DIV_W-1:0] us_div_count_q;
    logic                us_tick;

    logic scl_meta_q;
    logic scl_sync_q;
    logic sda_meta_q;
    logic sda_sync_q;
    logic sda_prev_q;

    logic [15:0] scl_stuck_count_q;
    logic [15:0] sda_stuck_count_q;
    logic [15:0] stretch_count_q;
    logic [31:0] sample_age_q;
    logic [7:0]  nack_count_q;

    wire unexpected_start = sda_prev_q && !sda_sync_q && scl_sync_q &&
                            !master_active_i;

    assign bus_idle_o = scl_sync_q && sda_sync_q && !master_active_i;
    assign bus_healthy_o = bus_idle_o;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            us_div_count_q <= '0;
            us_tick        <= 1'b0;
        end else if (US_DIV <= 1) begin
            us_div_count_q <= '0;
            us_tick        <= 1'b1;
        end else if (us_div_count_q == US_DIV-1) begin
            us_div_count_q <= '0;
            us_tick        <= 1'b1;
        end else begin
            us_div_count_q <= us_div_count_q + 1'b1;
            us_tick        <= 1'b0;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scl_meta_q <= 1'b1;
            scl_sync_q <= 1'b1;
            sda_meta_q <= 1'b1;
            sda_sync_q <= 1'b1;
            sda_prev_q <= 1'b1;
        end else begin
            scl_meta_q <= scl_i;
            scl_sync_q <= scl_meta_q;
            sda_meta_q <= sda_i;
            sda_sync_q <= sda_meta_q;
            sda_prev_q <= sda_sync_q;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fault_o            <= '0;
            scl_stuck_count_q  <= '0;
            sda_stuck_count_q  <= '0;
            stretch_count_q    <= '0;
            sample_age_q       <= '0;
            nack_count_q       <= '0;
        end else if (clear_i || !enable_i) begin
            fault_o            <= '0;
            scl_stuck_count_q  <= '0;
            sda_stuck_count_q  <= '0;
            stretch_count_q    <= '0;
            sample_age_q       <= '0;
            nack_count_q       <= '0;
        end else begin
            if (unexpected_start)
                fault_o[FAULT_UNEXPECTED] <= 1'b1;

            if (sample_complete_i) begin
                sample_age_q <= '0;
                nack_count_q <= '0;
            end else begin
                if (sample_nack_i && nack_limit_i != 0) begin
                    if (nack_count_q < nack_limit_i)
                        nack_count_q <= nack_count_q + 1'b1;
                    if ((nack_count_q + 1'b1) >= nack_limit_i)
                        fault_o[FAULT_NACK_LIMIT] <= 1'b1;
                end

                if (us_tick && sample_timeout_us_i != 0) begin
                    if (sample_age_q < sample_timeout_us_i)
                        sample_age_q <= sample_age_q + 1'b1;
                    if ((sample_age_q + 1'b1) >= sample_timeout_us_i)
                        fault_o[FAULT_NO_SAMPLE] <= 1'b1;
                end
            end

            if (us_tick) begin
                if (!master_active_i && !scl_sync_q && stuck_limit_us_i != 0) begin
                    if (scl_stuck_count_q < stuck_limit_us_i)
                        scl_stuck_count_q <= scl_stuck_count_q + 1'b1;
                    if ((scl_stuck_count_q + 1'b1) >= stuck_limit_us_i)
                        fault_o[FAULT_SCL_STUCK] <= 1'b1;
                end else begin
                    scl_stuck_count_q <= '0;
                end

                if (!master_active_i && !sda_sync_q && stuck_limit_us_i != 0) begin
                    if (sda_stuck_count_q < stuck_limit_us_i)
                        sda_stuck_count_q <= sda_stuck_count_q + 1'b1;
                    if ((sda_stuck_count_q + 1'b1) >= stuck_limit_us_i)
                        fault_o[FAULT_SDA_STUCK] <= 1'b1;
                end else begin
                    sda_stuck_count_q <= '0;
                end

                if (master_active_i && scl_release_i && !scl_sync_q &&
                    stretch_limit_us_i != 0) begin
                    if (stretch_count_q < stretch_limit_us_i)
                        stretch_count_q <= stretch_count_q + 1'b1;
                    if ((stretch_count_q + 1'b1) >= stretch_limit_us_i)
                        fault_o[FAULT_STRETCH] <= 1'b1;
                end else begin
                    stretch_count_q <= '0;
                end
            end
        end
    end

endmodule
