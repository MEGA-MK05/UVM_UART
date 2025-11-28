`timescale 1 ps/ 1 ps
`include "uvm_macros.svh"
import uvm_pkg::*;

interface uart_intf;
  
  logic clk,rst;
  logic rx;
	logic [7:0] tx_data_in;
	logic start;
  logic tx;
	logic [7:0] rx_data_out;
	logic tx_active;
	logic done_tx; 

endinterface


class uart_trans extends uvm_sequence_item;
   
  
    `uvm_object_utils(uart_trans)
         
     bit rx;
	   rand bit [7:0] tx_data_in;
	   bit start;
	   bit tx;
	   bit [7:0] rx_data_out;
	   bit tx_active;
	   bit done_tx;
  
   
    function new (string name = "");
      super.new(name);
    endfunction
    
  endclass: uart_trans



typedef uvm_sequencer #(uart_trans) uart_sequencer;


  class uart_sequence extends uvm_sequence #(uart_trans);
  
    `uvm_object_utils(uart_sequence)
    int count;
    
    function new (string name = ""); 
      super.new(name);
    endfunction

    task body;
      if (starting_phase != null)
        starting_phase.raise_objection(this);
        void'(uvm_config_db #(int)::get(null,"","no_of_transactions",count));
      repeat(count)
      begin
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


  class uart_driver extends uvm_driver #(uart_trans);
  
    `uvm_component_utils(uart_driver)

    parameter clk_freq = 50000000; //MHz
    parameter baud_rate = 19200; //bits per second
    localparam clock_divide = (clk_freq/baud_rate);

    virtual uart_intf vif;
    reg [7:0] data;
    int no_transactions;
    
    
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    
    function void build_phase(uvm_phase phase);
      // Get interface reference from config database
      if( !uvm_config_db #(virtual uart_intf)::get(this, "", "uart_intf", vif) )
        `uvm_error("", "uvm_config_db::get failed")
    endfunction 
   
    task run_phase(uvm_phase phase);
      forever
      begin
        seq_item_port.get_next_item(req);

        
      `uvm_info("","---------------------------------------------",UVM_MEDIUM) 
      `uvm_info("", $sformatf("\t Transaction No. = %0d",no_transactions),UVM_MEDIUM) 
      //Test tx
      vif.start <= 1;
      vif.rx <= 1;
      @(posedge vif.clk);
      vif.tx_data_in <= req.tx_data_in;
      @(posedge vif.clk);
      wait(vif.done_tx == 1);
      vif.start <= 0;
      if(vif.done_tx == 1) begin
      `uvm_info("", $sformatf("\t start = %0b, \t tx_data_in = %0h,\t done_tx = %0b",vif.start,req.tx_data_in,vif.done_tx),UVM_MEDIUM)  
      `uvm_info("","[TRANSACTION]::TX PASS",UVM_MEDIUM)  
       end
      else begin
      `uvm_info("", $sformatf("\t start = %0b, \t tx_data_in = %0h,\t done_tx = %0b",vif.start,req.tx_data_in,vif.done_tx),UVM_MEDIUM)  
      `uvm_info("","[TRANSACTION]::TX PASS",UVM_MEDIUM)  
       end  
      repeat(100) @(posedge vif.clk);
      //Test rx
	    @(posedge vif.clk);
	    data = $random;
	    vif.rx <= 1'b0;
	    repeat(clock_divide) @(posedge vif.clk);
	    for(int i=0;i<8;i++) begin
	    vif.rx <= data[i];
	    repeat(clock_divide) @(posedge vif.clk);
	    end
	    vif.rx <= 1'b1;
	    repeat(clock_divide) @(posedge vif.clk);
	    repeat(100) @(posedge vif.clk); 
	   `uvm_info("", $sformatf("\t Expected data = %0h, \t Obtained data = %0h", data,vif.rx_data_out),UVM_MEDIUM)  
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
                
        seq_item_port.item_done();
        no_transactions++;
      end
    endtask

  endclass: uart_driver
    
      
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
	  trans = uart_trans::type_id::create("trans");
		if(!uvm_config_db #(virtual uart_intf)::get(this, "", "uart_intf", intf)) 
		   begin
		    `uvm_error("ERROR::", "UVM_CONFIG_DB FAILED in uart_mon")
		    end
		//ap_port = new("ap_port", this);
	endfunction

  
  task run_phase(uvm_phase phase);
    while(1) begin
      @(posedge intf.clk);
      trans = uart_trans::type_id::create("trans");
      trans.start = intf.start;
      trans.tx_active = intf.tx_active;
      trans.done_tx = intf.done_tx;
      trans.tx_data_in = intf.tx_data_in;
      trans.rx = intf.rx;
      trans.rx_data_out = intf.rx_data_out;
      trans.tx = intf.tx;
      ap_port.write(trans);
    end
  endtask
  
  
endclass
      
      
class uart_cov extends uvm_subscriber #(uart_trans);
  
  `uvm_component_utils(uart_cov)
  uart_trans trans;
	

  covergroup cov_inst;
  RX:coverpoint trans.rx {option.auto_bin_max = 1;}
  TX_DIN:coverpoint trans.tx_data_in {option.auto_bin_max = 8;}
  START:coverpoint trans.start {option.auto_bin_max = 1;}
  TX:coverpoint trans.tx {option.auto_bin_max = 1;}
  RX_DOUT:coverpoint trans.rx_data_out {option.auto_bin_max = 8;}
  TX_ACT:coverpoint trans.tx_active {option.auto_bin_max = 1;}
  DONE:coverpoint trans.done_tx {option.auto_bin_max = 1;}
  
  RXxRX_DOUT: cross RX,RX_DOUT;
  TXxTX_DINxTX_ACTxDONE: cross TX,TX_DIN,TX_ACT,DONE;
  STARTxTX_DIN: cross START,TX_DIN;
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

      
      
class uart_agent extends uvm_agent;
	
 `uvm_component_utils(uart_agent)
	  
	  uart_sequencer seqr;
    uart_driver    driv;
    uart_mon mon;
    uart_cov cov;
    
    function new(string name = "", uvm_component parent);
      super.new(name, parent);
    endfunction
 
    function void build_phase(uvm_phase phase);
      seqr = uart_sequencer::type_id::create("seqr", this);
      driv = uart_driver::type_id::create("driv", this);
      mon = uart_mon::type_id::create("mon", this);
      cov = uart_cov::type_id::create("cov", this);
    endfunction
    
    function void connect_phase(uvm_phase phase);
      driv.seq_item_port.connect( seqr.seq_item_export);
      mon.ap_port.connect(cov.analysis_export);
    endfunction
    

endclass


  
  class uart_env extends uvm_env;

  `uvm_component_utils(uart_env)
    
   uart_agent agent;
    
    function new(string name = "", uvm_component parent);
      super.new(name, parent);
    endfunction
 
    function void build_phase(uvm_phase phase);
    agent = uart_agent::type_id::create("agent",this);  
    endfunction
    
    
  endclass: uart_env
  

  
  class uart_test extends uvm_test;
  
    `uvm_component_utils(uart_test)
    
    uart_env env;
    
    function new(string name = "", uvm_component parent);
      super.new(name, parent);
    endfunction
    
    function void build_phase(uvm_phase phase);
      env = uart_env::type_id::create("env", this);
    endfunction
    
    	function void end_of_elaboration_phase(uvm_phase phase);
			//`uvm_info(uvm_get_fullname(), this.sprint(), UVM_NONE)
			`uvm_info("", this.sprint(), UVM_NONE)
		endfunction
    
    task run_phase(uvm_phase phase);
      uart_sequence seqr;
      seqr = uart_sequence::type_id::create("seqr");
      if( !seqr.randomize() ) 
        `uvm_error("", "Randomize failed")
      seqr.starting_phase = phase;
      seqr.start( env.agent.seqr );
    endtask
     
  endclass: uart_test


module tb_uart_top;
  
  
  bit clk;
  bit rst;
  
  uart_intf intf();
  
  uart    dut(
              .clk(intf.clk),
              .rst(intf.rst),
              .rx(intf.rx),
              .tx_data_in(intf.tx_data_in),
              .start(intf.start),
              .rx_data_out(intf.rx_data_out),
              .tx(intf.tx),
              .tx_active(intf.tx_active),
              .done_tx(intf.done_tx)
              );

  // Clock generator
  initial
  begin
    intf.clk = 0;
    forever #5 intf.clk = ~intf.clk;
  end
  
  initial
  begin
    intf.rst = 1;
    #1000;
    intf.rst = 0;
  end



  initial
  begin
    uvm_config_db #(virtual uart_intf)::set(null, "*", "uart_intf", intf);
    void'(uvm_config_db #(int)::set(null,"*","no_of_transactions",10));
    
    uvm_top.finish_on_completion = 1;
    
    run_test("uart_test");
  end

endmodule: tb_uart_top



  

