/*
  Timer-Core

  A memory mapped up-counter: an AXI-Lite subordinate and its MMIO register
  file form the control plane, a prescaler and a counter the data plane.

  The counter increments once every (Prescaler + 1) enabled clock cycles, so a
  match period is (Compare + 1) * (Prescaler + 1) cycles. On a match, match_o
  pulses for one cycle and the sticky Match flag is set. A continuous timer
  then wraps to zero and keeps running; a one-shot timer parks on Compare until
  the flag is cleared.
*/
`include "timescale.vs"

module timer #(
    `include "AXI_parameters.vs"  // VS_NO_GENERATE
    parameter integer COUNTER_WIDTH = 32,
    parameter integer PRESCALER_WIDTH = 16,
    parameter integer ADDR_WIDTH = 32,
    parameter integer DATA_WIDTH = 32
) (
    `include "AXI_ios.vs"  // VS_NO_GENERATE
    // timer IOs
    input  logic clk_i,
    input  logic arstn_i,
    output logic match_o,  // One cycle pulse, asserted when Counter reaches Compare
    output logic irq_o     // Level interrupt: Match flag qualified by Control[3]
);
  // ============================================================================
  // Local parameters
  // ============================================================================
  // Control register bit map. CtrlClear and CtrlClearMatch are write-one-shot:
  // control_auto strips them out of the value the register reloads with, so
  // they act for a single cycle and always read back as zero.
  localparam integer CtrlEnable = 0;  // Enable counting
  localparam integer CtrlContinuous = 1;  // 1: wrap on match, 0: one-shot
  localparam integer CtrlClear = 2;  // Clear Counter and prescaler
  localparam integer CtrlIrqEnable = 3;  // Route the Match flag to irq_o
  localparam integer CtrlClearMatch = 4;  // Clear the sticky Match flag

  localparam logic [7:0] CtrlSelfClearMask = (8'h1 << CtrlClear) | (8'h1 << CtrlClearMatch);

  // ============================================================================
  // Signal Declarations
  // ============================================================================
  `include "AXI_signals.vs"  // VS_NO_GENERATE
  `include "MMIO_timer_signals.vs"  // VS_NO_GENERATE
  logic                       sync_reset;

  // Control register decode
  logic                       timer_enable;
  logic                       timer_continuous;
  logic                       timer_clear;
  logic                       irq_enable;
  logic                       match_clear;
  logic [              7:0]   control_auto;

  // Data plane
  logic [  COUNTER_WIDTH-1:0] count_q;
  logic [  COUNTER_WIDTH-1:0] count_n;
  logic [PRESCALER_WIDTH-1:0] presc_q;
  logic [PRESCALER_WIDTH-1:0] presc_n;
  logic                       match_flag;
  logic                       match_flag_n;

  logic                       timer_run;  // Enabled and not parked on a one-shot match
  logic                       tick;  // Prescaler expiry: Counter advances this cycle
  logic                       count_at_top;  // Counter currently holds Compare
  logic [              7:0]   hw_status;

  // ============================================================================
  // Logic
  // ============================================================================

  `include "synchronize_reset_timer.vs"  // arstn_i (active-low), sync_reset (active-high)
  `include "AXI_logic.vs"  /*
      AXI-Lite Subordinate
    */

  assign hw_status = {6'b0, match_flag, timer_run};

  // AXI-Lite subordinate <-> MMIO register file glue. The generated state
  // machines expose the committed address on *addr_n and raise wstrb on the
  // cycle a write commits.
  genvar gwi;
  generate
    for (gwi = 0; gwi < DATA_WIDTH / 8; gwi = gwi + 1) begin : gen_wdata
      assign w_data[gwi*8+:8] = AXIL_wstrb[gwi] ? AXIL_wdata[gwi*8+:8] : 8'h00;
    end
  endgenerate
  assign AXIL_rdata = r_data;
  assign w_address  = AXIL_awaddr_n >> $clog2(AXIL_DATA_WIDTH / 8);
  assign w_enable   = |AXIL_wstrb;
  assign r_address  = AXIL_araddr_n >> $clog2(AXIL_DATA_WIDTH / 8);
  assign r_enable   = 1'b1;

  `include "MMIO_timer.vs"  /*
    Control  ,               8, 0, sync_reset, , , 0x0, R/W, control_auto
    Status   ,               8, 0, sync_reset, , , 0x1,   R, hw_status
    Prescaler, PRESCALER_WIDTH, 0, sync_reset, , , 0x2, R/W,
    Compare  ,   COUNTER_WIDTH, 0, sync_reset, , , 0x3, R/W,
    Counter  ,   COUNTER_WIDTH, 0, sync_reset, , , 0x4,   R, count_q
    */

  assign timer_enable     = Control[CtrlEnable];
  assign timer_continuous = Control[CtrlContinuous];
  assign timer_clear      = Control[CtrlClear];
  assign irq_enable       = Control[CtrlIrqEnable];
  assign match_clear      = Control[CtrlClearMatch];
  assign control_auto     = Control & ~CtrlSelfClearMask;

  // Clearing the counter clears the prescaler too, so the first tick after a
  // clear is a full prescaler period.
  assign timer_run    = timer_enable & (timer_continuous | ~match_flag);
  assign tick         = timer_run & (presc_q >= Prescaler);
  assign count_at_top = (count_q == Compare);

  always_comb begin
    presc_n = presc_q;
    if (timer_clear | tick) begin
      presc_n = {PRESCALER_WIDTH{1'b0}};
    end else if (timer_run) begin
      presc_n = presc_q + 1'b1;
    end
  end

  always_comb begin
    count_n = count_q;
    if (timer_clear) begin
      count_n = {COUNTER_WIDTH{1'b0}};
    end else if (tick) begin
      if (count_at_top) begin
        // One-shot parks on Compare; continuous restarts the period.
        count_n = timer_continuous ? {COUNTER_WIDTH{1'b0}} : count_q;
      end else begin
        count_n = count_q + 1'b1;
      end
    end
  end

  assign match_o      = tick & count_at_top;
  assign match_flag_n = (match_flag | match_o) & ~(match_clear | timer_clear);
  assign irq_o        = irq_enable & match_flag;

  `include "reg_timer_datapath.vs"  /*
    count_q   ,   COUNTER_WIDTH, 0, sync_reset, , _n
    presc_q   , PRESCALER_WIDTH, 0, sync_reset, , _n
    match_flag,               1, 0, sync_reset, , _n
    */

endmodule
