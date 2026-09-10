/*
  Timer-Core FPGA wrapper (iCESugar-Pro, Lattice ECP5 LFE5U-25F)

  Wraps one timer instance together with a control unit that owns the AXI-Lite
  port. The control unit:
    1. Programs the MMIO register file after reset: prescaler, compare value,
       counter clear, then enable.
    2. Polls the timer forever, reading Counter and then Status every round.
    3. Toggles the LED when Status reports that the counter met TOGGLE_VALUE,
       and clears the Match flag again over the same AXI-Lite port.

  TOGGLE_VALUE is programmed into the timer's Compare register, so the LED
  toggles every (TOGGLE_VALUE + 1) * (PRESCALER + 1) clock cycles: once per
  second by default.
*/
`include "timescale.vs"

module timer_fpga #(
    parameter integer CLK_FREQ_HZ = 25_000_000,
    // Counter tick divider. 0 keeps TOGGLE_VALUE a plain cycle count; raise it
    // to reach periods a COUNTER_WIDTH compare value cannot express on its own.
    parameter integer PRESCALER = 0,
    // The count the timer must meet to toggle the LED. One second at 25 MHz.
    parameter integer TOGGLE_VALUE = CLK_FREQ_HZ - 1,
    // RGB channel mask, {red, green, blue}: 3'b001 blinks blue, 3'b111 white.
    parameter logic [2:0] LED_COLOUR = 3'b001,
    // The iCESugar-Pro RGB LED is common cathode, so a high output lights it.
    parameter bit LED_ACTIVE_LOW = 1'b0
) (
    input  logic clk_i,   // 25 MHz board oscillator
    input  logic arst_i,  // Active-high reset button; idles low, see the LPF
    // RGB LED channels. Channels outside LED_COLOUR are held dark.
    output logic led_r_o,
    output logic led_g_o,
    output logic led_b_o
);
  // ============================================================================
  // Local parameters
  // ============================================================================
  localparam integer AddrWidth = 32;
  localparam integer DataWidth = 32;
  localparam integer CounterWidth = 32;
  localparam integer PrescalerWidth = 16;

  // MMIO byte addresses (register index << 2)
  localparam logic [AddrWidth-1:0] RegControl = 'h00;
  localparam logic [AddrWidth-1:0] RegStatus = 'h04;
  localparam logic [AddrWidth-1:0] RegPrescaler = 'h08;
  localparam logic [AddrWidth-1:0] RegCompare = 'h0C;
  localparam logic [AddrWidth-1:0] RegCounter = 'h10;

  // Status register bit map: [0] Running, [1] Match
  localparam integer StatusMatch = 1;

  // Control register values written by the init sequence
  localparam logic [DataWidth-1:0] CtrlClearCounter = 'h04;  // Clear (self clearing)
  localparam logic [DataWidth-1:0] CtrlRun = 'h03;  // Enable | Continuous
  localparam logic [DataWidth-1:0] CtrlAckMatch = 'h13;  // Run | ClearMatch

  // Register values, sized for the timer's data path
  localparam logic [CounterWidth-1:0] CompareValue = CounterWidth'(TOGGLE_VALUE);
  localparam logic [PrescalerWidth-1:0] PrescalerValue = PrescalerWidth'(PRESCALER);

  // Init sequence: prescaler, compare value, counter clear, enable.
  localparam integer NInit = 4;
  localparam integer InitIdxWidth = $clog2(NInit);

  // The power-on reset lasts while this counter fills: 2**(PorWidth-1) cycles.
  localparam integer PorWidth = 5;
  localparam integer PorMsb = PorWidth - 1;

  // ============================================================================
  // Signal Declarations
  // ============================================================================
  `include "FSM_ctrl_signals.vs"  // VS_NO_GENERATE
  logic                      sync_reset;

  // AXI-Lite manager side of the control unit
  logic                      t_awvalid;
  logic                      t_awready;
  logic [    AddrWidth-1:0]  t_awaddr;
  logic                      t_wvalid;
  logic                      t_wready;
  logic [    DataWidth-1:0]  t_wdata;
  logic                      t_bvalid;
  logic                      t_arvalid;
  logic                      t_arready;
  logic [    AddrWidth-1:0]  t_araddr;
  logic                      t_rvalid;
  logic [    DataWidth-1:0]  t_rdata;

  // Init sequence ROM
  wire  [    AddrWidth-1:0]  init_addr      [NInit];
  wire  [    DataWidth-1:0]  init_data      [NInit];
  logic [ InitIdxWidth-1:0]  init_idx_q;
  logic [ InitIdxWidth-1:0]  init_idx_n;
  logic                      init_more;

  // LED
  logic                      led_q;
  logic                      led_n;
  logic [              2:0]  led_active;

  logic                      writing;
  logic                      reading;

  // Reset. sync_reset is the only reset the rest of the wrapper sees; the two
  // signals below are the requests OR'ed together to form it.
  logic                      ext_sync_reset;  // arst_i, moved into the clk_i domain
  logic                      por_reset;  // Power-on reset window still open
  logic                      por_done;  // Power-on reset window closed
  // The initialiser is the power-on reset: programming the board loads it into
  // the register. It also keeps simulation deterministic before the first edge.
  logic [     PorWidth-1:0]  por_cnt_q = '0;
  logic [     PorWidth-1:0]  por_cnt_n;

  // ============================================================================
  // Logic
  // ============================================================================

  // ----------------------------------------------------------------------------
  // Reset
  //
  // The design must start without help from the board pin, which reads low
  // when idle or unconnected. Programming the board is itself a reset, so this
  // counter starts from its reset value and saturates, and its top bit says
  // when the startup window has closed. arst_i is only ever OR'ed on top, so
  // the button can extend the reset but never prevent the design from running.
  //
  // por_cnt_q is the one register here that cannot take sync_reset, because
  // sync_reset is derived from it. por_reset serves as its enable instead, so
  // the counter runs exactly while the reset is asserted.
  // ----------------------------------------------------------------------------
  assign por_done  = por_cnt_q[PorMsb];
  assign por_reset = ~por_done;
  assign por_cnt_n = por_cnt_q + 1'b1;

  `include "reg_timer_fpga_por.vs"  /*
    por_cnt_q, PorWidth, 0, , por_reset, _n
    */

  // arst_i crosses into the clk_i domain here: asserted asynchronously so a
  // button press is never missed, de-asserted through two flops so every
  // register leaves reset on the same edge.
  `include "synchronize_reset_timer_fpga.vs"  // arst_i (active-high), ext_sync_reset (active-high)
  assign sync_reset = ext_sync_reset | por_reset;

  assign init_addr[0] = RegPrescaler;
  assign init_data[0] = {{(DataWidth - PrescalerWidth) {1'b0}}, PrescalerValue};
  assign init_addr[1] = RegCompare;
  assign init_data[1] = CompareValue;
  assign init_addr[2] = RegControl;
  assign init_data[2] = CtrlClearCounter;
  assign init_addr[3] = RegControl;
  assign init_data[3] = CtrlRun;

  assign init_more = (init_idx_q < InitIdxWidth'(NInit - 1));

  // ----------------------------------------------------------------------------
  // Control unit
  //
  // WrCmd/WrResp walk the init sequence, then the RdCnt/RdCntD/RdSt/RdStD ring
  // polls Counter and Status. A Match seen in Status detours through
  // ClrCmd/ClrResp, which acknowledges the flag and toggles the LED. The *D
  // states wait for read data, which arrives the cycle after the address is
  // accepted.
  // ----------------------------------------------------------------------------
  `include "FSM_ctrl.vs"  /* reset = sync_reset (active-high), clock = clk_i
    WrCmd   -> WrResp : t_awready & t_wready
    WrResp  -> WrCmd  : t_bvalid & init_more
            -> RdCnt  : t_bvalid
    RdCnt   -> RdCntD : t_arready
    RdCntD  -> RdSt   : t_rvalid
    RdSt    -> RdStD  : t_arready
    RdStD   -> ClrCmd : t_rvalid & t_rdata[StatusMatch]
            -> RdCnt  : t_rvalid
    ClrCmd  -> ClrResp: t_awready & t_wready
    ClrResp -> RdCnt  : t_bvalid
    */

  assign writing = (ctrl_state == ctrl_WrCmd) | (ctrl_state == ctrl_ClrCmd);
  assign reading = (ctrl_state == ctrl_RdCnt) | (ctrl_state == ctrl_RdSt);

  assign t_awvalid = writing;
  assign t_wvalid = writing;
  assign t_awaddr = (ctrl_state == ctrl_ClrCmd) ? RegControl : init_addr[init_idx_q];
  assign t_wdata = (ctrl_state == ctrl_ClrCmd) ? CtrlAckMatch : init_data[init_idx_q];
  assign t_arvalid = reading;
  assign t_araddr = (ctrl_state == ctrl_RdSt) ? RegStatus : RegCounter;

  // Advance the init sequence once each write is acknowledged.
  always_comb begin
    init_idx_n = init_idx_q;
    if ((ctrl_state == ctrl_WrResp) & ctrl_WrResp_WrCmd) begin
      init_idx_n = init_idx_q + 1'b1;
    end
  end

  // The Counter read is deliberately not latched anywhere: driving the LED
  // from the match alone is what keeps it to one colour or dark.
  assign led_n = led_q ^ ((ctrl_state == ctrl_RdStD) & ctrl_RdStD_ClrCmd);

  `include "reg_timer_fpga_control.vs"  /*
    init_idx_q    , InitIdxWidth, 0, sync_reset, , _n
    led_q         ,            1, 0, sync_reset, , _n
    */

  // ----------------------------------------------------------------------------
  // Board outputs
  //
  // One signal gates every channel, so the selected ones switch together and
  // the rest stay dark: the LED is LED_COLOUR or nothing, never a mix.
  // ----------------------------------------------------------------------------
  assign led_active = LED_COLOUR & {3{led_q}};
  assign {led_r_o, led_g_o, led_b_o} = LED_ACTIVE_LOW ? ~led_active : led_active;

  // ============================================================================
  // Internal Modules
  // ============================================================================

  timer #(
      .AXIL_ADDR_WIDTH(AddrWidth),
      .AXIL_DATA_WIDTH(DataWidth),
      .AXIL_ID_W_WIDTH(1),
      .AXIL_ID_R_WIDTH(1),
      .COUNTER_WIDTH(CounterWidth),
      .PRESCALER_WIDTH(PrescalerWidth),
      .ADDR_WIDTH(AddrWidth),
      .DATA_WIDTH(DataWidth)
  ) timer_0 (
      .AXIL_awvalid_i(t_awvalid),
      .AXIL_awready_o(t_awready),
      .AXIL_awid_i   (1'b0),
      .AXIL_awaddr_i (t_awaddr),
      .AXIL_wvalid_i (t_wvalid),
      .AXIL_wready_o (t_wready),
      .AXIL_wdata_i  (t_wdata),
      .AXIL_wstrb_i  ({(DataWidth / 8) {1'b1}}),
      .AXIL_bvalid_o (t_bvalid),
      .AXIL_bready_i (1'b1),
      .AXIL_bid_o    (),
      .AXIL_arvalid_i(t_arvalid),
      .AXIL_arready_o(t_arready),
      .AXIL_arid_i   (1'b0),
      .AXIL_araddr_i (t_araddr),
      .AXIL_rvalid_o (t_rvalid),
      .AXIL_rready_i (1'b1),
      .AXIL_rid_o    (),
      .AXIL_rdata_o  (t_rdata),
      .clk_i         (clk_i),
      .arstn_i       (~sync_reset),
      .match_o       (),
      .irq_o         ()
  );

endmodule
