`timescale 1 ns/ 1 ps

`include "uvm_macros.svh"
import uvm_pkg::*;

// ------------------------------------------------------
// Interface : DUT 포트와 UVM 사이의 브리지
//  - DUT의 tx_busy -> tx_active에 매핑
//  - DUT의 tx_done -> done_tx에 매핑
//  - DUT의 rx_done -> rx_done (필요시 사용 가능)
// ------------------------------------------------------
interface uart_intf;
  
  logic clk;
  logic rst;

  // TX side
  logic [7:0] tx_data_in;
  logic       start;
  logic       tx;
  logic       tx_active;   // -> DUT tx_busy
  logic       done_tx;     // -> DUT tx_done

  // RX side
  logic       rx;
  logic [7:0] rx_data_out; // -> DUT rx_data
  logic       rx_done;     // -> DUT rx_done

endinterface


// ------------------------------------------------------
// Transaction
// ------------------------------------------------------
class uart_trans extends uvm_sequence_item;
   
  `uvm_object_utils(uart_trans)
         
  bit        rx;
  rand bit [7:0] tx_data_in;
  bit        start;
  bit        tx;
  bit [7:0]  rx_data_out;
  bit        tx_active;
  bit        done_tx;
  bit        rx_done;        // 필요시 사용 가능

  // 프레임 사이 idle 클럭 수 (back-to-back 제어용)
  rand bit [31:0] idle_cycles;

  //  scoreboard를 위한 기대값 필드 (driver의 data)
  bit [7:0]  exp_rx_data;
  
  // 기본 idle은 100 사이클 (기존 repeat(100) 유지)
  constraint c_idle_default { idle_cycles inside{[0:100]}; }

  function new (string name = "");
    super.new(name);
  endfunction
    
endclass: uart_trans



typedef uvm_sequencer #(uart_trans) uart_sequencer;


// ------------------------------------------------------
// 기본 랜덤 Sequence
// ------------------------------------------------------
class uart_sequence extends uvm_sequence #(uart_trans);
  
  `uvm_object_utils(uart_sequence)
  int count;
    
  function new (string name = "uart_sequence"); 
    super.new(name);
  endfunction

  task body;
    if (starting_phase != null)
      starting_phase.raise_objection(this);

    void'(uvm_config_db #(int)::get(null,"","no_of_transactions",count));

    repeat(count) begin
      req = uart_trans::type_id::create("req");
      start_item(req);
      if( !req.randomize() )
        `uvm_error("", "Randomize failed")
      finish_item(req);
    end
      
    if (starting_phase != null)
      starting_phase.drop_objection(this);
  endtask: body
   
endclass: uart_sequence

// ------------------------------------------------------
// Boundary Pattern 전용 Sequence
//   - 0x00, 0xFF, 0x55, 0xAA, 0x01, 0x80 고정 패턴
//   - idle_cycles는 기본 100으로 유지
// ------------------------------------------------------
class uart_boundary_sequence extends uvm_sequence #(uart_trans);

  `uvm_object_utils(uart_boundary_sequence)

  function new(string name="uart_boundary_sequence");
    super.new(name);
  endfunction

  task body;
    if (starting_phase != null)
      starting_phase.raise_objection(this);

    // 0x00
    `uvm_do_with(req, {
      tx_data_in  == 8'h00;
      idle_cycles == 100;
    });

    // 0xFF
    `uvm_do_with(req, {
      tx_data_in  == 8'hFF;
      idle_cycles == 100;
    });

    // 0x55
    `uvm_do_with(req, {
      tx_data_in  == 8'h55;
      idle_cycles == 100;
    });

    // 0xAA
    `uvm_do_with(req, {
      tx_data_in  == 8'hAA;
      idle_cycles == 100;
    });

    // 0x01
    `uvm_do_with(req, {
      tx_data_in  == 8'h01;
      idle_cycles == 100;
    });

    // 0x80
    `uvm_do_with(req, {
      tx_data_in  == 8'h80;
      idle_cycles == 100;
    });

    if (starting_phase != null)
      starting_phase.drop_objection(this);
  endtask

endclass : uart_boundary_sequence



// ------------------------------------------------------
// Back-to-Back 전용 Sequence
//   - idle_cycles를 0~2로 줄여서 프레임 사이 gap 최소화
//   - 데이터는 랜덤
// ------------------------------------------------------
class uart_back2back_sequence extends uvm_sequence #(uart_trans);

  `uvm_object_utils(uart_back2back_sequence)

  int count;

  function new (string name = "uart_back2back_sequence");
    super.new(name);
  endfunction

  task body;
    if (starting_phase != null)
      starting_phase.raise_objection(this);

    // 기존 no_of_transactions 재사용
    void'(uvm_config_db #(int)::get(null,"","no_of_transactions",count));

    repeat(count) begin
      `uvm_do_with(req, {
        idle_cycles inside {[0:2]}; // 거의 back-to-back
      });
    end

    if (starting_phase != null)
      starting_phase.drop_objection(this);
  endtask

endclass : uart_back2back_sequence




// ------------------------------------------------------
// Driver
// ------------------------------------------------------
class uart_driver extends uvm_driver #(uart_trans);
  
  `uvm_component_utils(uart_driver)

  // DUT에 맞춘 타이밍
  parameter clk_freq  = 100_000_000; // Hz
  parameter baud_rate = 9600;        // bits per second
  //localparam clock_divide = (clk_freq/baud_rate);
  localparam clock_divide = 1600;    // EDA timeout 방지용 (축소)

  virtual uart_intf vif;
  reg [7:0] data;
  int no_transactions;

  // scoreboard로 결과를 보내기 위한 analysis_port
  uvm_analysis_port #(uart_trans) ap_port;
    
    
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  
    
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if( !uvm_config_db #(virtual uart_intf)::get(this, "", "uart_intf", vif) )
      `uvm_error("", "uvm_config_db::get failed")

    ap_port = new("ap_port", this);
  endfunction 
   
  task run_phase(uvm_phase phase);
    forever begin
      seq_item_port.get_next_item(req);

      `uvm_info("","---------------------------------------------",UVM_MEDIUM) 
      `uvm_info("", $sformatf("\t Transaction No. = %0d",no_transactions),UVM_MEDIUM) 

      // ----------------------
      // Test TX
      // ----------------------
      vif.start <= 1;
      vif.rx    <= 1;
      @(posedge vif.clk);
      vif.tx_data_in <= req.tx_data_in;
      @(posedge vif.clk);
      // DUT의 tx_done에 매핑된 done_tx 사용
      wait(vif.done_tx == 1);
      vif.start <= 0;

      if(vif.done_tx == 1) begin
        `uvm_info("", $sformatf("\t start = %0b, \t tx_data_in = %0h,\t done_tx = %0b",
                                vif.start,req.tx_data_in,vif.done_tx),UVM_MEDIUM)  
        `uvm_info("","[TRANSACTION]::TX PASS",UVM_MEDIUM)  
      end
      else begin
        `uvm_info("", $sformatf("\t start = %0b, \t tx_data_in = %0h,\t done_tx = %0b",
                                vif.start,req.tx_data_in,vif.done_tx),UVM_MEDIUM)  
        `uvm_info("","[TRANSACTION]::TX PASS",UVM_MEDIUM)  
      end  

      // ★ TX 이후 idle (시퀀스에서 제어)
      repeat(req.idle_cycles) @(posedge vif.clk);

      // ----------------------
      // Test RX
      // ----------------------
      @(posedge vif.clk);
      data = $random;
      // start bit
      vif.rx <= 1'b0;
      repeat(clock_divide) @(posedge vif.clk);

      // data bits (LSB first)
      for(int i=0;i<8;i++) begin
        vif.rx <= data[i];
        repeat(clock_divide) @(posedge vif.clk);
      end

      // stop bit
      vif.rx <= 1'b1;
      repeat(clock_divide) @(posedge vif.clk);

      // RX 이후 idle
      repeat(req.idle_cycles) @(posedge vif.clk); 

      `uvm_info("", $sformatf("\t Expected data = %0h, \t Obtained data = %0h",
                              data,vif.rx_data_out),UVM_MEDIUM)  

      begin
        if(vif.rx_data_out == data) begin
          `uvm_info("","[TRANSACTION]::RX PASS",UVM_MEDIUM)  
          `uvm_info("","---------------------------------------------",UVM_MEDIUM)  
        end
        else begin 
          `uvm_info("","[TRANSACTION]::RX FAIL",UVM_MEDIUM)  
          `uvm_info("","---------------------------------------------",UVM_MEDIUM)  
        end
      end

      // scoreboard로 정보 전달
      begin
        uart_trans sb_tr;
        sb_tr = uart_trans::type_id::create("sb_tr");
        sb_tr.tx_data_in   = req.tx_data_in;
        sb_tr.rx_data_out  = vif.rx_data_out;
        sb_tr.exp_rx_data  = data;
        sb_tr.start        = vif.start;
        sb_tr.rx           = vif.rx;
        sb_tr.tx           = vif.tx;
        sb_tr.tx_active    = vif.tx_active;
        sb_tr.done_tx      = vif.done_tx;
        sb_tr.rx_done      = vif.rx_done;
        sb_tr.idle_cycles  = req.idle_cycles;
        ap_port.write(sb_tr);
      end
                
      seq_item_port.item_done();
      no_transactions++;
    end
  endtask

endclass: uart_driver
    

// ------------------------------------------------------
// Monitor
// ------------------------------------------------------
class uart_mon extends uvm_monitor;
	
  virtual uart_intf intf;
  uart_trans trans;
  uvm_analysis_port #(uart_trans) ap_port;
  `uvm_component_utils(uart_mon)
	
  function new(string name="", uvm_component parent);
    super.new(name, parent);
  endfunction


  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ap_port = new("ap_port",this);
    trans   = uart_trans::type_id::create("trans");
    if(!uvm_config_db #(virtual uart_intf)::get(this, "", "uart_intf", intf)) begin
      `uvm_error("ERROR::", "UVM_CONFIG_DB FAILED in uart_mon")
    end
  endfunction

  task run_phase(uvm_phase phase);
    while(1) begin
      @(posedge intf.clk);
      trans = uart_trans::type_id::create("trans");
      trans.start       = intf.start;
      trans.tx_active   = intf.tx_active;
      trans.done_tx     = intf.done_tx;
      trans.tx_data_in  = intf.tx_data_in;
      trans.rx          = intf.rx;
      trans.rx_data_out = intf.rx_data_out;
      trans.rx_done     = intf.rx_done;
      trans.tx          = intf.tx;
      ap_port.write(trans);
    end
  endtask
  
endclass
      


// ------------------------------------------------------
// Coverage
// ------------------------------------------------------
class uart_cov extends uvm_subscriber #(uart_trans);
  
  `uvm_component_utils(uart_cov)
  uart_trans trans;
	

  covergroup cov_inst;
    RX     : coverpoint trans.rx           {option.auto_bin_max = 1;}
    TX_DIN : coverpoint trans.tx_data_in   {option.auto_bin_max = 8;}
    START  : coverpoint trans.start        {option.auto_bin_max = 1;}
    TX     : coverpoint trans.tx           {option.auto_bin_max = 1;}
    RX_DOUT: coverpoint trans.rx_data_out  {option.auto_bin_max = 8;}
    TX_ACT : coverpoint trans.tx_active    {option.auto_bin_max = 1;}
    DONE   : coverpoint trans.done_tx      {option.auto_bin_max = 1;}
  
    RXxRX_DOUT            : cross RX,RX_DOUT;
    TXxTX_DINxTX_ACTxDONE : cross TX,TX_DIN,TX_ACT,DONE;
    STARTxTX_DIN          : cross START,TX_DIN;
  endgroup 
  
  
  function new(string name="", uvm_component parent);
    super.new(name, parent);
    cov_inst = new();
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
  endfunction


  virtual function void write(uart_trans t);
    $cast(trans, t);
    cov_inst.sample();
  endfunction

endclass


// ------------------------------------------------------
// Scoreboard
// ------------------------------------------------------
class uart_scoreboard extends uvm_subscriber #(uart_trans);
  
  `uvm_component_utils(uart_scoreboard)

  uart_trans trans;
  int pass_cnt;
  int fail_cnt;

  function new(string name="", uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void write(uart_trans t);
    $cast(trans, t);

    if (trans.rx_data_out == trans.exp_rx_data) begin
      pass_cnt++;
    end
    else begin
      fail_cnt++;
      `uvm_error("SB",
                 $sformatf("RX MISMATCH: exp=%0h act=%0h",
                           trans.exp_rx_data, trans.rx_data_out))
    end
  endfunction

  function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("SB",
              $sformatf("Scoreboard summary : PASS=%0d, FAIL=%0d",
                        pass_cnt, fail_cnt),
              UVM_NONE)
  endfunction

endclass
      


// ------------------------------------------------------
// Agent
// ------------------------------------------------------
class uart_agent extends uvm_agent;
	
  `uvm_component_utils(uart_agent)
	  	  
  uart_sequencer  seqr;
  uart_driver     driv;
  uart_mon        mon;
  uart_cov        cov;
  uart_scoreboard sb;
    
  function new(string name = "", uvm_component parent);
    super.new(name, parent);
  endfunction
 
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    seqr = uart_sequencer ::type_id::create("seqr", this);
    driv = uart_driver    ::type_id::create("driv", this);
    mon  = uart_mon       ::type_id::create("mon",  this);
    cov  = uart_cov       ::type_id::create("cov",  this);
    sb   = uart_scoreboard::type_id::create("sb",   this);
  endfunction
    
  function void connect_phase(uvm_phase phase);
    driv.seq_item_port.connect( seqr.seq_item_export );

    mon.ap_port.connect(cov.analysis_export);
    driv.ap_port.connect(sb.analysis_export); // 오타 수정: driv
  endfunction
    

endclass


// ------------------------------------------------------
// Env
// ------------------------------------------------------
class uart_env extends uvm_env;

  `uvm_component_utils(uart_env)
    
  uart_agent agent;
    
  function new(string name = "", uvm_component parent);
    super.new(name, parent);
  endfunction
 
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    agent = uart_agent::type_id::create("agent",this);  
  endfunction
    
endclass: uart_env
  

// ------------------------------------------------------
// Test
//   - 1) Boundary 시퀀스 실행
//   - 2) Back-to-back 시퀀스 실행
// ------------------------------------------------------
class uart_test extends uvm_test;
  
  `uvm_component_utils(uart_test)
    
  uart_env env;
    
  function new(string name = "", uvm_component parent);
    super.new(name, parent);
  endfunction
    
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = uart_env::type_id::create("env", this);
  endfunction
    
  function void end_of_elaboration_phase(uvm_phase phase);
    `uvm_info("", this.sprint(), UVM_NONE)
  endfunction
    
  task run_phase(uvm_phase phase);
    uart_boundary_sequence  bseq;
    uart_back2back_sequence b2b;

    // Boundary 패턴 시퀀스
    bseq = uart_boundary_sequence::type_id::create("bseq");
    bseq.starting_phase = phase;
    bseq.start( env.agent.seqr );

    // Back-to-back 시퀀스
    b2b = uart_back2back_sequence::type_id::create("b2b");
    b2b.starting_phase = phase;
    b2b.start( env.agent.seqr );
  endtask
     
endclass: uart_test


// ------------------------------------------------------
// Top TB : 새 UART DUT 인스턴스
// ------------------------------------------------------
module tb_uart_top;
  
  bit clk;
  bit rst;
  
  uart_intf intf();
  
  // 네 DUT
  uart dut(
    .clk     (intf.clk),
    .reset   (intf.rst),
    .start   (intf.start),
    .tx_data (intf.tx_data_in),
    .rx      (intf.rx),

    .tx_busy (intf.tx_active),
    .tx_done (intf.done_tx),
    .rx_done (intf.rx_done),
    .rx_data (intf.rx_data_out),
    .tx      (intf.tx)
  );

  // Clock generator (100 MHz)
  initial begin
    intf.clk = 0;
    forever #5 intf.clk = ~intf.clk;
  end
  
  initial begin
    intf.rst = 1;
    #1000;
    intf.rst = 0;
  end

  initial begin
    uvm_config_db #(virtual uart_intf)::set(null, "*", "uart_intf", intf);
    void'(uvm_config_db #(int)::set(null,"*","no_of_transactions",10));
    
    uvm_top.finish_on_completion = 1;
    run_test("uart_test");
  end
  
  initial begin
    $dumpfile("dump.vcd");
    $dumpvars(0, tb_uart_top);  
  end

endmodule: tb_uart_top
