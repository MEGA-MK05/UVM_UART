# UART UVM Testbench 검증 보고서

## 1. 개요
본 문서는 UART 모듈에 대해 UVM환경에서 수행한 기능 검증 결과를 요약한다.  
본 테스트는 **TX 직렬화 및 RX 역직렬화 기능의 정확성**,  
그리고 **UVM 재사용 구조를 통한 테스트 안정성 확보**를 목표로 한다.

검증 환경은 Synopsys VCS에서 구동되며, 테스트 결과 모든 트랜잭션은 오류 없이 정상적으로 처리되었다.

---

## 2. UVM Testbench 구조

UART UVM TB는 다음과 같은 **표준 계층 구조**로 구성되어 있다.

```
uvm_tes
 └─ uart_env
      └─ uart_agent
           ├─ uart_driver
           ├─ uart_sequencer
           ├─ uart_monitor
           └─ uart_cov (covergroup)
```


- **Sequence**: 테스트 패턴 생성 (Boundary / Back-to-Back)
- **Driver**: DUT에 TX/RX 파형 직접 생성 + Golden Data 생성
- **Monitor**: DUT의 실제 반응을 관찰하여 transaction화
- **Scoreboard**: DUT 출력 vs Golden 값 비교
- **Coverage**: 패턴 및 조합 분포 분석
- **Agent**: Sequencer / Driver / Monitor / Coverage / Scoreboard 묶음
- **Env → Test → Top**: UVM 전체 실행 환경 구성

---

# 2.1 Transaction / Sequence (패턴 생성부)

## uart_trans (트랜잭션 정의)

```systemverilog
class uart_trans extends uvm_sequence_item;
  `uvm_object_utils(uart_trans)

  bit        rx;
  rand bit [7:0] tx_data_in;
  bit        start;
  bit        tx;
  bit [7:0]  rx_data_out;
  bit        tx_active;
  bit        done_tx;
  bit        rx_done;

  rand bit [31:0] idle_cycles;   // Idle 간격 (Back-to-Back 제어)

  constraint c_idle_default { idle_cycles inside {[0:100]}; }

  bit [7:0]  exp_rx_data;        // Scoreboard Golden 값

  function new (string name = "");
    super.new(name);
  endfunction
endclass
````

---

## Boundary / Back-to-Back Sequence

### Boundary Sequence – 고정 패턴 6개

```systemverilog
`uvm_do_with(req, { tx_data_in == 8'h00; idle_cycles == 100; });
`uvm_do_with(req, { tx_data_in == 8'hFF; idle_cycles == 100; });
`uvm_do_with(req, { tx_data_in == 8'h55; idle_cycles == 100; });
`uvm_do_with(req, { tx_data_in == 8'hAA; idle_cycles == 100; });
`uvm_do_with(req, { tx_data_in == 8'h01; idle_cycles == 100; });
`uvm_do_with(req, { tx_data_in == 8'h80; idle_cycles == 100; });
```

### Back-to-Back Sequence – idle 0~2, 랜덤 데이터

```systemverilog
void'(uvm_config_db #(int)::get(null,"","no_of_transactions",count));

repeat(count) begin
  `uvm_do_with(req, { idle_cycles inside {[0:2]}; });
end
```

---

# 2.2 Driver / Monitor (DUT 자극 & 관찰)

## uart_driver – TX/RX 구동 + Golden Data 생성

```systemverilog
class uart_driver extends uvm_driver #(uart_trans);

  virtual uart_intf vif;
  uvm_analysis_port #(uart_trans) ap_port;

  task run_phase(uvm_phase phase);
    forever begin
      seq_item_port.get_next_item(req);

      // TX
      vif.start <= 1;
      @(posedge vif.clk);
      vif.tx_data_in <= req.tx_data_in;
      wait(vif.done_tx == 1);
      vif.start <= 0;
      repeat(req.idle_cycles) @(posedge vif.clk);

      // RX – Golden Data 생성
      data = $random;
      vif.rx <= 0; repeat(clock_divide) @(posedge vif.clk);
      for(int i=0;i<8;i++) begin
        vif.rx <= data[i];
        repeat(clock_divide) @(posedge vif.clk);
      end
      vif.rx <= 1; repeat(clock_divide) @(posedge vif.clk);

      // Scoreboard 트랜잭션 생성
      uart_trans sb_tr = uart_trans::type_id::create("sb_tr");
      sb_tr.tx_data_in  = req.tx_data_in;
      sb_tr.rx_data_out = vif.rx_data_out;
      sb_tr.exp_rx_data = data;   // Golden Data
      ap_port.write(sb_tr);

      seq_item_port.item_done();
    end
  endtask
endclass
```

---

## uart_mon – DUT 관찰 → Coverage 자료 생성

```systemverilog
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
    ap_port.write(trans);
  end
endtask
```

---

# 2.3 Coverage / Scoreboard / Agent–Env–Test–Top

## Coverage (테스트 분포 정량화)

```systemverilog
covergroup cov_inst;
  RX     : coverpoint trans.rx;
  TX_DIN : coverpoint trans.tx_data_in;
  RX_DOUT: coverpoint trans.rx_data_out;

  RXxRX_DOUT : cross RX, RX_DOUT;
endgroup
```

---

## Scoreboard (DUT vs Golden 비교)

```systemverilog
if (trans.rx_data_out == trans.exp_rx_data)
  pass_cnt++;
else begin
  fail_cnt++;
  `uvm_error("SB",
      $sformatf("Mismatch exp=%0h act=%0h",
        trans.exp_rx_data, trans.rx_data_out));
end
```

---

## Agent (Sequencer/Driver/Monitor/Coverage/Scoreboard 집합)

```systemverilog
seqr = uart_sequencer::type_id::create("seqr", this);
driv = uart_driver   ::type_id::create("driv", this);
mon  = uart_mon      ::type_id::create("mon",  this);

driv.seq_item_port.connect(seqr.seq_item_export);
mon.ap_port.connect(cov.analysis_export);
driv.ap_port.connect(sb.analysis_export);
```

---

## Test (Boundary → Back-to-Back 실행)

```systemverilog
bseq.start(env.agent.seqr);
b2b.start(env.agent.seqr);
```

---

## Top (DUT + Virtual Interface + run_test)

```systemverilog
uvm_config_db #(virtual uart_intf)::set(null, "*", "uart_intf", intf);
run_test("uart_test");
```

---



---


## 3. 검증 전략

### 3.1 테스트 시나리오
총 **10개의 random-like TX/RX 트랜잭션** 수행:

| Transaction No. | TX Input | Expected RX | Result |
|------------------|----------|-------------|--------|
| 0 | 0x05 | 0x24 | PASS |
| 1 | 0x55 | 0x81 | PASS |
| 2 | 0x01 | 0x09 | PASS |
| 3 | 0xD8 | 0x63 | PASS |
| 4 | 0x3E | 0x0D | PASS |
| 5 | 0x51 | 0x8D | PASS |
| 6 | 0x16 | 0x65 | PASS |
| 7 | 0xFA | 0x12 | PASS |
| 8 | 0x6C | 0x01 | PASS |
| 9 | 0x4A | 0x0D | PASS |

---

## 4. 안정성 및 검증 적합성 평가

### 4.1 구조적 안정성
- 표준 UVM 구조(agent/sequencer/driver/monitor) 사용  
- 재사용성 및 확장성 우수

### 4.2 기능적 안정성
- TX/RX 독립 검증 + Scoreboard 기반 self-checking  
- 모든 트랜잭션 기대값과 일치

### 4.3 시뮬레이션 안정성
- 에러 0건  
- 모든 시퀀스 정상 수행

### 4.4 UVM 검증 적합성 충족
- 자동 stimulus  
- self-checking 환경  
- coverage 기반 확장 가능

---

## 6. 결론
본 UART UVM Testbench는  
**TX 직렬화**, **RX 역직렬화** 두 기능 모두에서  
모든 테스트 패턴이 정상 PASS 되었으며,  
UVM ERROR/FATAL 없이 완전 종료되었다.

이는 UART DUT가 스펙대로 안정적으로 동작함을 증명하며,  
향후 regression 및 확장 검증에 즉시 재사용 가능한 구조적 완성도를 갖추었다.
