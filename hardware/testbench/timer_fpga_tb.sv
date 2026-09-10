/*
  Self-checking testbench for the Timer-Core FPGA wrapper.

  Nothing is driven but the clock and the reset button: the wrapper's own
  control unit has to program the register file, poll the timer and toggle the
  LED. The testbench checks
    1. that the register file was programmed with the compile-time parameters,
    2. that the Counter really is read over AXI-Lite, watched on the bus,
    3. that the LED toggles once per (TOGGLE_VALUE + 1) * (PRESCALER + 1)
       cycles and that only the LED_COLOUR channels ever light.
*/
`timescale 1ns / 1ps

`ifndef DEBUG
`define DEBUG 0
`endif

module timer_fpga_tb ();

  // --------------------------------------------------------------------------
  // Parameters
  // --------------------------------------------------------------------------
  // Small enough to simulate, large enough that a match cannot be missed by
  // the poll loop. The board defaults are checked separately on dut_default.
  localparam integer Prescaler = 1;
  localparam integer ToggleValue = 24;
  localparam integer LedPeriod = (ToggleValue + 1) * (Prescaler + 1);  // 50 cycles

  // Board defaults: one LED toggle per second off the 25 MHz oscillator.
  localparam integer BoardClkHz = 25_000_000;
  localparam integer BoardToggleValue = BoardClkHz - 1;
  localparam integer BoardPrescaler = 0;

  // MMIO byte address of the Counter register, watched on the AXI-Lite bus.
  localparam logic [31:0] RegCounterAddr = 32'h10;

  // Board LED wiring, mirroring the wrapper defaults: blue only, common
  // cathode, so a channel is dark at 0 and lit at 1.
  localparam logic [2:0] LedColour = 3'b001;
  localparam bit LedActiveLow = 1'b0;
  localparam logic LedDark = LedActiveLow;

  // Cycles the control unit may need to notice a match: RdCnt -> RdCntD ->
  // RdSt -> RdStD -> ClrCmd -> ClrResp, plus AXI-Lite wait states.
  localparam integer DetectLatency = 12;

  localparam integer NToggles = 9;
  localparam integer VERBOSE = `DEBUG;
  localparam integer MaxRunTime = 4000;

  // --------------------------------------------------------------------------
  // Clock / reset
  // --------------------------------------------------------------------------
  logic clk = 0;
  logic arst = 1;
  always #5 clk = ~clk;

  // --------------------------------------------------------------------------
  // Scoreboard
  // --------------------------------------------------------------------------
  integer errors = 0;
  integer checks = 0;

  integer cycles = 0;
  integer toggles = 0;
  integer toggle_cycle[NToggles];
  logic   led_prev;
  // Held low until the design is known to be running, so the X-to-1 settle on
  // led_o at power up is not counted as an LED edge.
  logic   monitor_en = 1'b0;

  integer counter_reads = 0;
  integer counter_read_bad = 0;
  integer rgb_wrong_channel = 0;
  integer led_lit_cycles = 0;
  logic   pending_counter_read = 1'b0;

  // --------------------------------------------------------------------------
  // DUT
  // --------------------------------------------------------------------------
  logic led_r_o;
  logic led_g_o;
  logic led_b_o;
  // The selected channel stands in for the LED.
  wire  led_o = led_b_o;

  timer_fpga #(
      .CLK_FREQ_HZ (25_000_000),
      .PRESCALER   (Prescaler),
      .TOGGLE_VALUE(ToggleValue)
  ) dut (
      .clk_i      (clk),
      .arst_i (arst),
      .led_r_o(led_r_o),
      .led_g_o(led_g_o),
      .led_b_o(led_b_o)
  );

  // A second wrapper left on its defaults. Simulating a whole second is
  // impractical, so only its init sequence is checked: if the defaults stop
  // meaning "one toggle per second", Compare comes out wrong here.
  logic led_r_default_o;
  logic led_g_default_o;
  logic led_b_default_o;

  timer_fpga dut_default (
      .clk_i      (clk),
      .arst_i (arst),
      .led_r_o(led_r_default_o),
      .led_g_o(led_g_default_o),
      .led_b_o(led_b_default_o)
  );

  // --------------------------------------------------------------------------
  // Monitors
  // --------------------------------------------------------------------------
  always @(posedge clk) cycles <= cycles + 1;

  always @(posedge clk) begin
    if (arst || !monitor_en) begin
      toggles  <= 0;
      led_prev <= led_o;
    end else begin
      if (led_o !== led_prev) begin
        if (toggles < NToggles) toggle_cycle[toggles] <= cycles;
        toggles <= toggles + 1;
        if (VERBOSE) $display("[%0t] led_o -> %b (toggle %0d)", $time, led_o, toggles + 1);
      end
      led_prev <= led_o;
    end
  end

  // Watch the AXI-Lite port for Counter reads. The control unit does not latch
  // the value, so the bus transaction is the only evidence it reads the timer:
  // count read data beats answering an address phase aimed at Counter, and
  // range check what comes back.
  always @(posedge clk) begin
    if (arst) begin
      pending_counter_read <= 1'b0;
    end else if (dut.t_rvalid && pending_counter_read) begin
      counter_reads <= counter_reads + 1;
      if (dut.t_rdata > ToggleValue) counter_read_bad <= counter_read_bad + 1;
      pending_counter_read <= 1'b0;
    end else if (dut.t_arvalid && dut.t_arready) begin
      pending_counter_read <= (dut.t_araddr == RegCounterAddr);
    end
  end

  // Channels outside LED_COLOUR must stay dark all run, or the LED mixes into
  // another colour. Blue is the only selected channel here.
  always @(posedge clk) begin
    if (!arst && monitor_en) begin
      if ((led_r_o !== LedDark) || (led_g_o !== LedDark)) begin
        rgb_wrong_channel <= rgb_wrong_channel + 1;
      end
      if (led_b_o !== LedDark) led_lit_cycles <= led_lit_cycles + 1;
    end
  end

  // --------------------------------------------------------------------------
  // Scoreboard helpers
  // --------------------------------------------------------------------------
  task automatic check_val(input string name, input logic [31:0] got,
                           input logic [31:0] exp);
    begin
      checks = checks + 1;
      if (got !== exp) begin
        errors = errors + 1;
        $display("[%0t] FAIL %-30s got %0d expected %0d", $time, name, got, exp);
      end else if (VERBOSE) begin
        $display("[%0t] pass %-30s %0d", $time, name, got);
      end
    end
  endtask

  task automatic check_min(input string name, input integer got, input integer min);
    begin
      checks = checks + 1;
      if (got < min) begin
        errors = errors + 1;
        $display("[%0t] FAIL %-30s got %0d expected >= %0d", $time, name, got, min);
      end else if (VERBOSE) begin
        $display("[%0t] pass %-30s %0d", $time, name, got);
      end
    end
  endtask

  // --------------------------------------------------------------------------
  // Main stimulus
  // --------------------------------------------------------------------------
  integer measured;
  integer expected;

  initial begin
    $display("==================================================");
    $display(" timer_fpga testbench (TOGGLE_VALUE = %0d, PRESCALER = %0d)", ToggleValue,
             Prescaler);
    $display("==================================================");

    // The reset button is never pressed: this is the board scenario, where the
    // pin idles de-asserted and only the power-on reset starts the design.
    arst = 1'b0;
    repeat (4) @(posedge clk);
    @(negedge clk);

    // The LED must start off.
    check_val("LED off after power-on reset", {31'b0, led_o}, {31'b0, LedDark});

    // Give the power-on reset time to expire, then the control unit time to
    // walk its init sequence.
    repeat (60) @(posedge clk);
    $display("-- Init sequence --");
    check_val("Prescaler programmed", {16'b0, dut.timer_0.Prescaler}, Prescaler);
    check_val("Compare programmed", dut.timer_0.Compare, ToggleValue);
    check_val("Control programmed", {24'b0, dut.timer_0.Control}, 32'h3);

    // The default build must program a one second period.
    check_val("default Prescaler", {16'b0, dut_default.timer_0.Prescaler}, BoardPrescaler);
    check_val("default Compare", dut_default.timer_0.Compare, BoardToggleValue);
    checks = checks + 1;
    if (((BoardToggleValue + 1) * (BoardPrescaler + 1)) != BoardClkHz) begin
      errors = errors + 1;
      $display("[%0t] FAIL default toggle period is not one second", $time);
    end else begin
      $display(" default toggle period: %0d cycles = 1.000 s at %0d Hz", BoardClkHz,
               BoardClkHz);
    end

    // Wait for NToggles LED edges.
    $display("-- LED toggling --");
    monitor_en = 1'b1;
    while (toggles < NToggles) @(posedge clk);
    repeat (2) @(posedge clk);

    check_min("LED toggle count", toggles, NToggles);

    // Each toggle is one timer match, so the toggles must be one LED period
    // apart on average; the poll loop only adds a bounded detection latency.
    measured = toggle_cycle[NToggles-1] - toggle_cycle[0];
    expected = (NToggles - 1) * LedPeriod;
    checks   = checks + 1;
    if ((measured > expected + DetectLatency) || (measured < expected - DetectLatency)) begin
      errors = errors + 1;
      $display("[%0t] FAIL %-30s got %0d expected %0d +/- %0d", $time,
               "LED toggle span", measured, expected, DetectLatency);
    end else begin
      $display(" LED toggle span over %0d edges: %0d cycles (expected %0d)", NToggles - 1,
               measured, expected);
    end

    // Pressing the reset button must restart the whole wrapper: the LED goes
    // back to off and the control unit programs the register file again.
    $display("-- Reset button --");
    arst = 1'b1;
    repeat (4) @(posedge clk);
    check_val("LED held off during reset", {31'b0, led_o}, {31'b0, LedDark});
    check_val("Control cleared by reset", {24'b0, dut.timer_0.Control}, 32'h0);
    @(negedge clk);
    arst = 1'b0;
    // Re-init plus a full LED period before the next edge can appear.
    repeat (60 + 2 * LedPeriod) @(posedge clk);
    check_val("Compare reprogrammed", dut.timer_0.Compare, ToggleValue);
    check_val("Control reprogrammed", {24'b0, dut.timer_0.Control}, 32'h3);
    check_min("LED toggling again", toggles, 1);

    $display("-- Counter readback --");
    check_min("Counter reads on the bus", counter_reads, 8);
    check_val("Counter reads in range", counter_read_bad, 32'h0);

    $display("-- LED is blue or off --");
    check_val("red and green stay dark", rgb_wrong_channel, 32'h0);
    check_val("red channel dark", {31'b0, led_r_o}, {31'b0, LedDark});
    check_val("green channel dark", {31'b0, led_g_o}, {31'b0, LedDark});
    // The blue channel must actually have been lit for part of the run, or
    // "only blue ever lights" would pass on a permanently dark LED.
    check_min("blue channel lit cycles", led_lit_cycles, LedPeriod);

    repeat (4) @(posedge clk);
    $display("==================================================");
    $display(" Checks run : %0d", checks);
    $display(" Errors     : %0d", errors);
    if (errors == 0) $display(" RESULT     : PASS");
    else $display(" RESULT     : FAIL");
    $display("==================================================");
    $finish;
  end

  // Watchdog
  initial begin
    repeat (MaxRunTime) @(posedge clk);
    $display("[%0t] TIMEOUT: simulation did not finish in time", $time);
    $finish;
  end

  // Dump waves. Off by default; enable with `make sim-run VCD=1`.
`ifdef VCD
  initial begin
    $dumpfile("timer_fpga_tb.vcd");
    $dumpvars(0, timer_fpga_tb);
  end
`endif

endmodule
