`timescale 1ns/1ps

// ADXL345 I2C acquisition sequencer for the MotorSentinel-RV data plane.
//
// Drives open-drain SCL/SDA (a 1 on *_drive_low_o pulls the line low; the
// pad releases it otherwise) and turns the accelerometer into the signed
// X/Y/Z sample stream consumed by motorsentinel_core_apb.
//
// On enable the sequencer
//   1. reads DEVID (0x00) and requires 0xE5,
//   2. writes POWER_CTL=0x00 (standby), BW_RATE=0x0D (800 Hz),
//      DATA_FORMAT=0x0B (full resolution, +/-16 g, 256 LSB/g), INT_MAP=0x00,
//      INT_ENABLE=0x80 (DATA_READY on INT1) and POWER_CTL=0x08 (measure),
//   3. burst-reads DATAX0..DATAZ1 (0x32-0x37) on every DATA_READY, or on an
//      internal SAMPLE_HZ timer when use_drdy_i is low.
// A NACK aborts the transaction with a STOP, pulses sample_nack_o for the
// protocol guard and re-initializes the sensor after 100 us, so a NACK storm
// reaches the guard's NACK limit long before the missing-sample watchdog. A
// wrong DEVID is re-polled once per sample period.
//
// Fast-mode timing is derived from CLK_HZ: SCL low >= 1.4 us, high >= 0.7 us,
// START/STOP setup and hold >= 0.7 us and bus-free time >= 1.4 us. Clock
// stretching is honored: every SCL release waits for the line to read high.
module motorsentinel_adxl345_reader #(
    parameter integer     CLK_HZ         = 50_000_000,
    parameter integer     I2C_HZ         = 400_000,
    parameter integer     SAMPLE_HZ      = 800,
    parameter logic [6:0] DEVICE_ADDRESS = 7'h53
) (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               enable_i,
    input  logic               use_drdy_i,

    input  logic               scl_i,
    input  logic               sda_i,
    input  logic               drdy_i,
    output logic               scl_drive_low_o,
    output logic               sda_drive_low_o,

    // Protocol-guard status.
    output logic               master_active_o,
    output logic               scl_release_o,
    output logic               sample_nack_o,

    output logic               sample_valid_o,
    output logic signed [15:0] sample_x_o,
    output logic signed [15:0] sample_y_o,
    output logic signed [15:0] sample_z_o,

    output logic               configured_o,
    output logic               id_error_o,
    output logic [7:0]         device_id_o,
    output logic [15:0]        nack_count_o,
    output logic [31:0]        sample_count_o
);

    // ------------------------------------------------------------------
    // Timing
    // ------------------------------------------------------------------
    localparam integer PERIOD   = (CLK_HZ + I2C_HZ - 1) / I2C_HZ;
    localparam integer LOW_MIN  = (CLK_HZ / 1000 * 14 + 9999) / 10000;  // 1.4 us
    localparam integer HIGH_MIN = (CLK_HZ / 1000 * 7 + 9999) / 10000;   // 0.7 us
    localparam integer T_LOW    = LOW_MIN;
    localparam integer T_HIGH   = (PERIOD - T_LOW > HIGH_MIN) ? PERIOD - T_LOW : HIGH_MIN;
    localparam integer T_HOLD   = T_LOW / 2;   // SDA changes mid-way through SCL low
    localparam integer SAMPLE_TICKS = CLK_HZ / SAMPLE_HZ;
    localparam integer HOLDOFF_TICKS = CLK_HZ / 20_000;  // 50 us DATA_READY re-arm
    localparam integer NACK_RETRY_TICKS = CLK_HZ / 10_000;  // 100 us after a NACK

    localparam logic [7:0] ADDR_WRITE = {DEVICE_ADDRESS, 1'b0};
    localparam logic [7:0] ADDR_READ  = {DEVICE_ADDRESS, 1'b1};
    localparam logic [7:0] DEVID_VALUE = 8'he5;
    localparam integer CONFIG_WRITES = 6;

    // ------------------------------------------------------------------
    // Input synchronizers
    // ------------------------------------------------------------------
    logic [1:0] scl_sync_q;
    logic [1:0] sda_sync_q;
    logic [1:0] drdy_sync_q;
    wire scl_high = scl_sync_q[1];
    wire sda_high = sda_sync_q[1];
    wire drdy = drdy_sync_q[1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scl_sync_q  <= 2'b11;
            sda_sync_q  <= 2'b11;
            drdy_sync_q <= 2'b00;
        end else begin
            scl_sync_q  <= {scl_sync_q[0], scl_i};
            sda_sync_q  <= {sda_sync_q[0], sda_i};
            drdy_sync_q <= {drdy_sync_q[0], drdy_i};
        end
    end

    // ------------------------------------------------------------------
    // Bit engine: START, repeated START, 9-bit byte transfer, STOP
    // ------------------------------------------------------------------
    typedef enum logic [2:0] {
        OP_START,
        OP_RSTART,
        OP_WRITE,
        OP_READ,
        OP_STOP,
        OP_END
    } op_t;

    typedef enum logic [3:0] {
        E_IDLE,
        E_START_WAIT,
        E_START_HOLD,
        E_RS_LOW_A,
        E_RS_LOW_B,
        E_RS_RISE,
        E_RS_HIGH,
        E_BIT_LOW_A,
        E_BIT_LOW_B,
        E_BIT_RISE,
        E_BIT_HIGH,
        E_STOP_LOW_A,
        E_STOP_LOW_B,
        E_STOP_RISE,
        E_STOP_HIGH,
        E_STOP_BUF
    } engine_t;

    engine_t     engine_q;
    logic        op_start_q;
    op_t         op_q;
    logic [7:0]  op_data_q;
    logic        op_send_ack_q;
    logic        engine_done_q;
    logic [7:0]  shift_q;
    logic [3:0]  bit_index_q;
    logic        reading_q;
    logic        ack_received_q;
    logic [15:0] timer_q;
    // The bus is owned from our START until the end of our STOP's bus-free
    // time. Waiting for a busy or stuck bus is not ownership, so the protocol
    // guard still sees a line held low by anyone else.
    logic        bus_owned_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            engine_q        <= E_IDLE;
            bus_owned_q     <= 1'b0;
            engine_done_q   <= 1'b0;
            shift_q         <= '0;
            bit_index_q     <= '0;
            reading_q       <= 1'b0;
            ack_received_q  <= 1'b0;
            timer_q         <= '0;
            scl_drive_low_o <= 1'b0;
            sda_drive_low_o <= 1'b0;
        end else begin
            engine_done_q <= 1'b0;
            if (timer_q != 0)
                timer_q <= timer_q - 1'b1;

            case (engine_q)
                E_IDLE: begin
                    if (op_start_q) begin
                        case (op_q)
                            OP_START: begin
                                timer_q  <= 16'(T_LOW);
                                engine_q <= E_START_WAIT;
                            end
                            OP_RSTART: begin
                                timer_q  <= 16'(T_HOLD);
                                engine_q <= E_RS_LOW_A;
                            end
                            OP_WRITE, OP_READ: begin
                                shift_q     <= (op_q == OP_WRITE) ? op_data_q : 8'h00;
                                reading_q   <= (op_q == OP_READ);
                                bit_index_q <= '0;
                                timer_q     <= 16'(T_HOLD);
                                engine_q    <= E_BIT_LOW_A;
                            end
                            OP_STOP: begin
                                timer_q  <= 16'(T_HOLD);
                                engine_q <= E_STOP_LOW_A;
                            end
                            default: engine_done_q <= 1'b1;
                        endcase
                    end
                end

                // START: the bus must have been free (both lines high) for
                // the bus-free time first, then SDA falls while SCL is high.
                E_START_WAIT: begin
                    if (!(scl_high && sda_high)) begin
                        timer_q <= 16'(T_LOW);
                    end else if (timer_q == 0) begin
                        bus_owned_q     <= 1'b1;
                        sda_drive_low_o <= 1'b1;
                        timer_q  <= 16'(T_HIGH);
                        engine_q <= E_START_HOLD;
                    end
                end

                E_START_HOLD: begin
                    if (timer_q == 0) begin
                        scl_drive_low_o <= 1'b1;
                        engine_done_q   <= 1'b1;
                        engine_q        <= E_IDLE;
                    end
                end

                // Repeated START: release SDA during SCL low, raise SCL, then
                // drop SDA while SCL is high.
                E_RS_LOW_A: begin
                    if (timer_q == 0) begin
                        sda_drive_low_o <= 1'b0;
                        timer_q  <= 16'(T_LOW - T_HOLD);
                        engine_q <= E_RS_LOW_B;
                    end
                end

                E_RS_LOW_B: begin
                    if (timer_q == 0) begin
                        scl_drive_low_o <= 1'b0;
                        engine_q <= E_RS_RISE;
                    end
                end

                E_RS_RISE: begin
                    if (scl_high) begin
                        timer_q  <= 16'(T_HIGH);
                        engine_q <= E_RS_HIGH;
                    end
                end

                E_RS_HIGH: begin
                    if (timer_q == 0) begin
                        sda_drive_low_o <= 1'b1;
                        timer_q  <= 16'(T_HIGH);
                        engine_q <= E_START_HOLD;
                    end
                end

                // Bits 0-7 carry data MSB first; bit 8 is the acknowledge.
                E_BIT_LOW_A: begin
                    if (timer_q == 0) begin
                        if (bit_index_q < 4'd8)
                            sda_drive_low_o <= !reading_q && !shift_q[7];
                        else
                            sda_drive_low_o <= reading_q && op_send_ack_q;
                        timer_q  <= 16'(T_LOW - T_HOLD);
                        engine_q <= E_BIT_LOW_B;
                    end
                end

                E_BIT_LOW_B: begin
                    if (timer_q == 0) begin
                        scl_drive_low_o <= 1'b0;
                        engine_q <= E_BIT_RISE;
                    end
                end

                E_BIT_RISE: begin
                    if (scl_high) begin
                        timer_q  <= 16'(T_HIGH);
                        engine_q <= E_BIT_HIGH;
                    end
                end

                E_BIT_HIGH: begin
                    if (timer_q == 0) begin
                        scl_drive_low_o <= 1'b1;
                        if (bit_index_q < 4'd8) begin
                            shift_q <= {shift_q[6:0], sda_high};
                            bit_index_q <= bit_index_q + 1'b1;
                            timer_q  <= 16'(T_HOLD);
                            engine_q <= E_BIT_LOW_A;
                        end else begin
                            ack_received_q <= !sda_high;
                            engine_done_q  <= 1'b1;
                            engine_q       <= E_IDLE;
                        end
                    end
                end

                // STOP: SDA rises while SCL is high, then the bus-free time.
                E_STOP_LOW_A: begin
                    if (timer_q == 0) begin
                        sda_drive_low_o <= 1'b1;
                        timer_q  <= 16'(T_LOW - T_HOLD);
                        engine_q <= E_STOP_LOW_B;
                    end
                end

                E_STOP_LOW_B: begin
                    if (timer_q == 0) begin
                        scl_drive_low_o <= 1'b0;
                        engine_q <= E_STOP_RISE;
                    end
                end

                E_STOP_RISE: begin
                    if (scl_high) begin
                        timer_q  <= 16'(T_HIGH);
                        engine_q <= E_STOP_HIGH;
                    end
                end

                E_STOP_HIGH: begin
                    if (timer_q == 0) begin
                        sda_drive_low_o <= 1'b0;
                        timer_q  <= 16'(T_LOW);
                        engine_q <= E_STOP_BUF;
                    end
                end

                E_STOP_BUF: begin
                    if (timer_q == 0) begin
                        bus_owned_q   <= 1'b0;
                        engine_done_q <= 1'b1;
                        engine_q      <= E_IDLE;
                    end
                end

                default: engine_q <= E_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Transaction programs
    // ------------------------------------------------------------------
    typedef enum logic [1:0] {
        T_READ_REG,
        T_WRITE_REG,
        T_BURST
    } txn_t;

    txn_t        txn_q;
    logic        txn_active_q;
    logic        txn_issue_q;
    logic        txn_failed_q;
    logic        txn_done_q;
    logic [3:0]  step_q;
    logic [7:0]  txn_reg_q;
    logic [7:0]  txn_value_q;
    logic [7:0]  rx_bytes_q [0:5];

    op_t         step_op;
    logic [7:0]  step_data;
    logic        step_ack;
    logic [3:0]  stop_step;

    always_comb begin
        step_op   = OP_END;
        step_data = 8'h00;
        step_ack  = 1'b0;
        stop_step = 4'd0;
        case (txn_q)
            T_READ_REG: begin
                stop_step = 4'd6;
                case (step_q)
                    4'd0: step_op = OP_START;
                    4'd1: begin step_op = OP_WRITE; step_data = ADDR_WRITE; end
                    4'd2: begin step_op = OP_WRITE; step_data = txn_reg_q; end
                    4'd3: step_op = OP_RSTART;
                    4'd4: begin step_op = OP_WRITE; step_data = ADDR_READ; end
                    4'd5: step_op = OP_READ;                       // NACK last byte
                    4'd6: step_op = OP_STOP;
                    default: step_op = OP_END;
                endcase
            end
            T_WRITE_REG: begin
                stop_step = 4'd4;
                case (step_q)
                    4'd0: step_op = OP_START;
                    4'd1: begin step_op = OP_WRITE; step_data = ADDR_WRITE; end
                    4'd2: begin step_op = OP_WRITE; step_data = txn_reg_q; end
                    4'd3: begin step_op = OP_WRITE; step_data = txn_value_q; end
                    4'd4: step_op = OP_STOP;
                    default: step_op = OP_END;
                endcase
            end
            default: begin  // T_BURST: DATAX0..DATAZ1 in one multi-byte read
                stop_step = 4'd11;
                case (step_q)
                    4'd0: step_op = OP_START;
                    4'd1: begin step_op = OP_WRITE; step_data = ADDR_WRITE; end
                    4'd2: begin step_op = OP_WRITE; step_data = 8'h32; end
                    4'd3: step_op = OP_RSTART;
                    4'd4: begin step_op = OP_WRITE; step_data = ADDR_READ; end
                    4'd5, 4'd6, 4'd7, 4'd8, 4'd9: begin step_op = OP_READ; step_ack = 1'b1; end
                    4'd10: step_op = OP_READ;                      // NACK last byte
                    4'd11: step_op = OP_STOP;
                    default: step_op = OP_END;
                endcase
            end
        endcase
    end

    // Configuration writes, issued in order after a successful DEVID check.
    function automatic logic [15:0] config_write(input logic [2:0] index);
        case (index)
            3'd0:    config_write = {8'h2d, 8'h00};  // POWER_CTL: standby
            3'd1:    config_write = {8'h2c, 8'h0d};  // BW_RATE: 800 Hz
            3'd2:    config_write = {8'h31, 8'h0b};  // DATA_FORMAT: full res, +/-16 g
            3'd3:    config_write = {8'h2f, 8'h00};  // INT_MAP: all on INT1
            3'd4:    config_write = {8'h2e, 8'h80};  // INT_ENABLE: DATA_READY
            default: config_write = {8'h2d, 8'h08};  // POWER_CTL: measure
        endcase
    endfunction

    // ------------------------------------------------------------------
    // Sequencer
    // ------------------------------------------------------------------
    typedef enum logic [2:0] {
        H_OFF,
        H_ID,
        H_CONFIG,
        H_RUN,
        H_RETRY
    } high_t;

    high_t       high_q;
    logic        txn_go;
    txn_t        txn_go_type;
    logic [7:0]  txn_go_reg;
    logic [7:0]  txn_go_value;
    logic [2:0]  config_index_q;
    logic [15:0] config_entry;
    logic [31:0] wait_q;
    logic [15:0] holdoff_q;
    logic        trigger_pending_q;
    logic        burst_q;

    assign config_entry = config_write(config_index_q);
    assign master_active_o = bus_owned_q;
    assign scl_release_o = master_active_o && !scl_drive_low_o;

    // Transaction runner: steps through the program, one engine op at a time.
    integer b;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            txn_q          <= T_READ_REG;
            txn_active_q   <= 1'b0;
            txn_issue_q    <= 1'b0;
            txn_failed_q   <= 1'b0;
            txn_done_q     <= 1'b0;
            step_q         <= '0;
            txn_reg_q      <= '0;
            txn_value_q    <= '0;
            op_start_q     <= 1'b0;
            op_q           <= OP_END;
            op_data_q      <= '0;
            op_send_ack_q  <= 1'b0;
            sample_nack_o  <= 1'b0;
            for (b = 0; b < 6; b = b + 1)
                rx_bytes_q[b] <= '0;
        end else begin
            op_start_q    <= 1'b0;
            txn_done_q    <= 1'b0;
            sample_nack_o <= 1'b0;

            if (txn_go && !txn_active_q) begin
                txn_q        <= txn_go_type;
                txn_reg_q    <= txn_go_reg;
                txn_value_q  <= txn_go_value;
                txn_active_q <= 1'b1;
                txn_issue_q  <= 1'b1;
                txn_failed_q <= 1'b0;
                step_q       <= '0;
            end else if (txn_active_q && txn_issue_q) begin
                txn_issue_q <= 1'b0;
                if (step_op == OP_END) begin
                    txn_active_q <= 1'b0;
                    txn_done_q   <= 1'b1;
                end else begin
                    op_q          <= step_op;
                    op_data_q     <= step_data;
                    op_send_ack_q <= step_ack;
                    op_start_q    <= 1'b1;
                end
            end else if (txn_active_q && engine_done_q) begin
                txn_issue_q <= 1'b1;
                if (op_q == OP_WRITE && !ack_received_q) begin
                    txn_failed_q  <= 1'b1;
                    sample_nack_o <= 1'b1;
                    step_q        <= stop_step;
                end else begin
                    if (op_q == OP_READ)
                        rx_bytes_q[step_q - 4'd5] <= shift_q;
                    step_q <= (op_q == OP_STOP) ? 4'd15 : step_q + 1'b1;
                end
            end
        end
    end

    always_comb begin
        txn_go       = 1'b0;
        txn_go_type  = T_READ_REG;
        txn_go_reg   = 8'h00;
        txn_go_value = 8'h00;
        if (!txn_active_q && !txn_done_q) begin
            case (high_q)
                H_OFF: if (enable_i) begin
                    txn_go = 1'b1;                 // read DEVID
                end
                H_CONFIG: begin
                    txn_go       = 1'b1;
                    txn_go_type  = T_WRITE_REG;
                    txn_go_reg   = config_entry[15:8];
                    txn_go_value = config_entry[7:0];
                end
                H_RUN: if (enable_i && trigger_pending_q && !burst_q) begin
                    txn_go = 1'b1;
                    txn_go_type = T_BURST;
                end
                H_RETRY: if (enable_i && wait_q == 0) begin
                    txn_go = 1'b1;
                end
                default: ;
            endcase
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            high_q            <= H_OFF;
            config_index_q    <= '0;
            wait_q            <= '0;
            holdoff_q         <= '0;
            trigger_pending_q <= 1'b0;
            burst_q           <= 1'b0;
            configured_o      <= 1'b0;
            id_error_o        <= 1'b0;
            device_id_o       <= '0;
            nack_count_o      <= '0;
            sample_count_o    <= '0;
            sample_valid_o    <= 1'b0;
            sample_x_o        <= '0;
            sample_y_o        <= '0;
            sample_z_o        <= '0;
        end else begin
            sample_valid_o <= 1'b0;
            if (wait_q != 0)
                wait_q <= wait_q - 1'b1;
            if (holdoff_q != 0)
                holdoff_q <= holdoff_q - 1'b1;
            if (sample_nack_o && nack_count_o != 16'hffff)
                nack_count_o <= nack_count_o + 1'b1;

            case (high_q)
                H_OFF: begin
                    configured_o <= 1'b0;
                    if (txn_go)
                        high_q <= H_ID;
                end

                H_ID: begin
                    if (txn_done_q) begin
                        if (txn_failed_q) begin
                            wait_q <= 32'(NACK_RETRY_TICKS);
                            high_q <= H_RETRY;
                        end else begin
                            device_id_o <= rx_bytes_q[0];
                            id_error_o  <= (rx_bytes_q[0] != DEVID_VALUE);
                            if (rx_bytes_q[0] != DEVID_VALUE) begin
                                wait_q <= 32'(SAMPLE_TICKS);
                                high_q <= H_RETRY;
                            end else begin
                                config_index_q <= '0;
                                high_q <= H_CONFIG;
                            end
                        end
                    end
                end

                H_CONFIG: begin
                    if (txn_done_q) begin
                        if (txn_failed_q) begin
                            wait_q <= 32'(NACK_RETRY_TICKS);
                            high_q <= H_RETRY;
                        end else if (config_index_q == CONFIG_WRITES - 1) begin
                            configured_o      <= 1'b1;
                            trigger_pending_q <= 1'b0;
                            holdoff_q         <= '0;
                            wait_q            <= 32'(SAMPLE_TICKS);
                            high_q            <= H_RUN;
                        end else begin
                            config_index_q <= config_index_q + 1'b1;
                        end
                    end
                end

                H_RUN: begin
                    // Trigger: DATA_READY level after a short re-arm holdoff,
                    // or a free-running SAMPLE_HZ timer.
                    if (use_drdy_i) begin
                        if (drdy && holdoff_q == 0 && !burst_q)
                            trigger_pending_q <= 1'b1;
                    end else if (wait_q == 0) begin
                        trigger_pending_q <= 1'b1;
                        wait_q <= 32'(SAMPLE_TICKS - 1);
                    end

                    if (txn_go) begin
                        burst_q <= 1'b1;
                        trigger_pending_q <= 1'b0;
                    end

                    if (txn_done_q && burst_q) begin
                        burst_q   <= 1'b0;
                        holdoff_q <= 16'(HOLDOFF_TICKS);
                        if (txn_failed_q) begin
                            configured_o <= 1'b0;
                            wait_q <= 32'(NACK_RETRY_TICKS);
                            high_q <= H_RETRY;
                        end else if (enable_i) begin
                            sample_valid_o <= 1'b1;
                            sample_x_o <= {rx_bytes_q[1], rx_bytes_q[0]};
                            sample_y_o <= {rx_bytes_q[3], rx_bytes_q[2]};
                            sample_z_o <= {rx_bytes_q[5], rx_bytes_q[4]};
                            sample_count_o <= sample_count_o + 1'b1;
                        end
                    end else if (!enable_i && !txn_active_q && !burst_q) begin
                        high_q <= H_OFF;
                    end
                end

                H_RETRY: begin
                    configured_o <= 1'b0;
                    if (!enable_i)
                        high_q <= H_OFF;
                    else if (txn_go)
                        high_q <= H_ID;
                end

                default: high_q <= H_OFF;
            endcase

            if (!enable_i && (high_q == H_ID || high_q == H_CONFIG) && txn_done_q)
                high_q <= H_OFF;
        end
    end

endmodule
