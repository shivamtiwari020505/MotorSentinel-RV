`timescale 1ns/1ps

// Behavioral ADXL345 I2C slave for verification.
//
// Implements the 7-bit address, register pointer with auto-increment,
// DEVID, writable configuration registers, DATAX0..DATAZ1 served from a
// sample list and DATA_READY on INT1. A data set is latched when DATAX0 is
// read and consumed when DATAZ1 is read, like the real part's multi-byte
// read coherence. The bench can inject faults through the public knobs and
// reads protocol_error to catch framing violations by the master.
module adxl345_i2c_model #(
    parameter logic [6:0] ADDRESS = 7'h53,
    parameter integer     MAX_SAMPLES = 4096
) (
    inout wire scl,
    inout wire sda,
    output reg drdy
);

    // Fault-injection and stimulus knobs.
    reg [7:0]  devid = 8'he5;
    reg        nack_address = 1'b0;
    reg        hold_sda_low = 1'b0;
    integer    stretch_ns = 0;
    integer    drdy_delay_ns = 20_000;
    reg [47:0] samples [0:MAX_SAMPLES-1];
    integer    sample_index = 0;

    // Observability.
    reg [7:0]  regs [0:63];
    reg        protocol_error = 1'b0;
    integer    starts = 0;
    integer    stops = 0;
    integer    nacked_addresses = 0;

    reg sda_low = 1'b0;
    reg scl_low = 1'b0;
    assign sda = (sda_low || hold_sda_low) ? 1'b0 : 1'bz;
    assign scl = scl_low ? 1'b0 : 1'bz;

    localparam integer ST_IDLE = 0;
    localparam integer ST_ADDR = 1;
    localparam integer ST_REG = 2;
    localparam integer ST_WRITE = 3;
    localparam integer ST_READ = 4;

    localparam integer PH_RX = 0;      // receiving data bits
    localparam integer PH_RX_ACK = 1;  // driving our ACK
    localparam integer PH_TX = 2;      // transmitting data bits
    localparam integer PH_TX_ACK = 3;  // master's ACK/NACK slot

    integer state = ST_IDLE;
    integer phase = PH_RX;
    integer bit_count = 0;
    reg [7:0] shift = 8'h00;
    reg [7:0] tx_byte = 8'h00;
    reg [5:0] pointer = 6'd0;
    reg       master_acked = 1'b0;
    reg       byte_open = 1'b0;
    reg [47:0] latched = 48'd0;
    integer i;

    initial begin
        drdy = 1'b0;
        for (i = 0; i < 64; i = i + 1)
            regs[i] = 8'h00;
        regs[8'h2c] = 8'h0a;  // BW_RATE reset value
    end

    function automatic [7:0] read_register(input [5:0] address);
        case (address)
            6'h00: read_register = devid;
            6'h32: read_register = latched[39:32];  // X0
            6'h33: read_register = latched[47:40];  // X1
            6'h34: read_register = latched[23:16];  // Y0
            6'h35: read_register = latched[31:24];  // Y1
            6'h36: read_register = latched[7:0];    // Z0
            6'h37: read_register = latched[15:8];   // Z1
            default: read_register = regs[address];
        endcase
    endfunction

    task automatic load_tx_byte;
        begin
            if (pointer == 6'h32) begin
                latched = samples[sample_index];
                drdy = 1'b0;
            end
            tx_byte = read_register(pointer);
            if (pointer == 6'h37) begin
                sample_index = sample_index + 1;
                drdy <= #(drdy_delay_ns) (regs[6'h2d][3] === 1'b1);
            end
            pointer = pointer + 1'b1;
        end
    endtask

    // START / repeated START.
    always @(negedge sda) begin
        if (scl === 1'b1) begin
            if (byte_open) begin
                protocol_error = 1'b1;
                $display("  model: START inside a byte (bit %0d) at %0t", bit_count, $time);
            end
            starts = starts + 1;
            state = ST_ADDR;
            phase = PH_RX;
            bit_count = 0;
            byte_open = 1'b0;
            shift = 8'h00;
            sda_low = 1'b0;
        end
    end

    // STOP.
    always @(posedge sda) begin
        if (scl === 1'b1) begin
            if (byte_open) begin
                protocol_error = 1'b1;
                $display("  model: STOP inside a byte (bit %0d) at %0t", bit_count, $time);
            end
            stops = stops + 1;
            state = ST_IDLE;
            phase = PH_RX;
            bit_count = 0;
            byte_open = 1'b0;
            sda_low = 1'b0;
        end
    end

    always @(posedge scl) begin
        if (state != ST_IDLE) begin
            if (phase == PH_RX && bit_count < 8) begin
                shift = {shift[6:0], sda === 1'b1};
                bit_count = bit_count + 1;
            end else if (phase == PH_TX_ACK) begin
                master_acked = (sda === 1'b0);
            end
        end
    end

    always @(negedge scl) begin
        if (state != ST_IDLE) begin
            if (phase == PH_RX && bit_count > 0 && bit_count < 8)
                byte_open = 1'b1;
            case (phase)
                PH_RX: begin
                    if (bit_count == 8) begin
                        case (state)
                            ST_ADDR: begin
                                if (shift[7:1] == ADDRESS && !nack_address) begin
                                    sda_low = 1'b1;
                                    phase = PH_RX_ACK;
                                    state = shift[0] ? ST_READ : ST_REG;
                                end else begin
                                    if (shift[7:1] == ADDRESS)
                                        nacked_addresses = nacked_addresses + 1;
                                    state = ST_IDLE;  // NACK: leave SDA released
                                    bit_count = 0;
                                    byte_open = 1'b0;
                                end
                            end
                            ST_REG: begin
                                pointer = shift[5:0];
                                sda_low = 1'b1;
                                phase = PH_RX_ACK;
                                state = ST_WRITE;
                            end
                            default: begin  // ST_WRITE
                                if (pointer != 6'h00 && !(pointer >= 6'h32 && pointer <= 6'h37))
                                    regs[pointer] = shift;
                                if (pointer == 6'h2d && shift[3])
                                    drdy <= #(drdy_delay_ns) 1'b1;
                                if (pointer == 6'h2d && !shift[3])
                                    drdy = 1'b0;
                                pointer = pointer + 1'b1;
                                sda_low = 1'b1;
                                phase = PH_RX_ACK;
                            end
                        endcase
                    end
                end

                PH_RX_ACK: begin
                    sda_low = 1'b0;
                    if (stretch_ns > 0) begin
                        scl_low = 1'b1;
                        scl_low <= #(stretch_ns) 1'b0;
                    end
                    if (state == ST_READ) begin
                        load_tx_byte();
                        phase = PH_TX;
                        bit_count = 0;
                        byte_open = 1'b0;
                        sda_low = !tx_byte[7];
                    end else begin
                        phase = PH_RX;
                        bit_count = 0;
                        byte_open = 1'b0;
                        shift = 8'h00;
                    end
                end

                PH_TX: begin
                    bit_count = bit_count + 1;
                    if (bit_count < 8) begin
                        sda_low = !tx_byte[7 - bit_count];
                    end else begin
                        sda_low = 1'b0;
                        phase = PH_TX_ACK;
                    end
                end

                default: begin  // PH_TX_ACK
                    if (master_acked) begin
                        load_tx_byte();
                        phase = PH_TX;
                        bit_count = 0;
                        byte_open = 1'b0;
                        sda_low = !tx_byte[7];
                    end else begin
                        state = ST_IDLE;
                        phase = PH_RX;
                        bit_count = 0;
                        byte_open = 1'b0;
                    end
                end
            endcase
        end
    end

endmodule
