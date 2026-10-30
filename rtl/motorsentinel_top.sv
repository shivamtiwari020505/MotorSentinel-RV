`timescale 1ns/1ps

// MotorSentinel-RV fabric top level: ADXL345 pins in, motor enable out.
//
// SCL and SDA are open-drain. Connect each *_drive_low_o to the output-enable
// of a pad that drives 0 (for example a PolarFire BIBUF with D tied low) and
// feed the pad input back to *_i; the pull-ups are on the sensor board. The
// protocol guard inside the core observes the same pad inputs as the reader,
// so a stuck line, a NACK storm or another master on the bus is detected
// independently of the acquisition logic.
module motorsentinel_top #(
    parameter integer CLK_HZ    = 50_000_000,
    parameter integer I2C_HZ    = 400_000,
    parameter integer SAMPLE_HZ = 800
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
    output logic        scl_drive_low_o,
    output logic        sda_drive_low_o,
    input  logic        adxl_int1_i,

    output logic        motor_enable_o,
    output logic        fault_led_o,
    output logic        irq_o
);

    logic               enable;
    logic               use_drdy;
    logic               master_active;
    logic               scl_release;
    logic               sample_nack;
    logic               sample_valid;
    logic               sample_ready;
    logic signed [15:0] sample_x;
    logic signed [15:0] sample_y;
    logic signed [15:0] sample_z;
    logic               configured;
    logic               id_error;
    logic [7:0]         device_id;
    logic [15:0]        nack_count;
    logic [31:0]        sample_count;

    motorsentinel_adxl345_reader #(
        .CLK_HZ   (CLK_HZ),
        .I2C_HZ   (I2C_HZ),
        .SAMPLE_HZ(SAMPLE_HZ)
    ) u_reader (
        .clk             (PCLK),
        .rst_n           (PRESETn),
        .enable_i        (enable),
        .use_drdy_i      (use_drdy),
        .scl_i           (scl_i),
        .sda_i           (sda_i),
        .drdy_i          (adxl_int1_i),
        .scl_drive_low_o (scl_drive_low_o),
        .sda_drive_low_o (sda_drive_low_o),
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

    motorsentinel_core_apb #(
        .CLK_HZ(CLK_HZ)
    ) u_core (
        .PCLK                (PCLK),
        .PRESETn             (PRESETn),
        .PSEL                (PSEL),
        .PENABLE             (PENABLE),
        .PWRITE              (PWRITE),
        .PADDR               (PADDR),
        .PWDATA              (PWDATA),
        .PRDATA              (PRDATA),
        .PREADY              (PREADY),
        .PSLVERR             (PSLVERR),
        .scl_i               (scl_i),
        .sda_i               (sda_i),
        .i2c_master_active_i (master_active),
        .i2c_scl_release_i   (scl_release),
        .sample_nack_i       (sample_nack),
        .sample_valid_i      (sample_valid),
        .sample_ready_o      (sample_ready),
        .sample_x_i          (sample_x),
        .sample_y_i          (sample_y),
        .sample_z_i          (sample_z),
        .motor_enable_o      (motor_enable_o),
        .fault_led_o         (fault_led_o),
        .irq_o               (irq_o),
        .enable_o            (enable),
        .acq_use_drdy_o      (use_drdy),
        .acq_status_i        ({nack_count, 4'd0, master_active, use_drdy,
                               id_error, configured, device_id}),
        .acq_samples_i       (sample_count)
    );

endmodule
