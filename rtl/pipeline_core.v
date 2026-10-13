// =============================================================================
// pipeline_core.v  --  5-stage in-order pipelined core (pure Verilog-2001)
//
//   IF -> ID -> EX -> MEM -> WB
//
// Custom 16-bit ISA (NOT RV32I; a deliberately small RISC-V-style subset):
//
//   [15:12] opcode | [11:9] rd | [8:6] rs1 | [5:3] rs2 | [2:0] imm
//
//   ADD/SUB/AND/OR rd,rs1,rs2      rd <- rs1 op rs2
//   ADDI           rd,rs1,imm      rd <- rs1 + sext(imm)          (imm: -4..3)
//   LW             rd,imm(rs1)     rd <- dmem[(rs1 + sext(imm))[5:0]]
//   SW             rs2,imm(rs1)    dmem[(rs1 + sext(imm))[5:0]] <- rs2
//   BEQ/BNE        rs1,rs2,imm     if (cond) pc <- pc + 1 + zext(imm)   (forward only)
//   NOP (4'hF) and any undefined opcode: no architectural effect
//
//   Fields an instruction does not use are IGNORED (the testbench fills them
//   with random garbage on purpose).  r0 is hard-wired to zero.
//
// Hazard handling
//   * Load-use hazard   : 1-cycle stall (hold PC + IF/ID, bubble into ID/EX)
//   * RAW, distance 1   : forward EX/MEM  -> EX   (non-load producers)
//   * RAW, distance 2   : forward MEM/WB  -> EX   (also carries load data)
//   * RAW, distance 3   : register-file write-through bypass in ID
//   * Branches resolve in EX; a taken branch redirects the PC and squashes the
//     two younger instructions (the one in ID and the one being fetched).
//
// Mutants for checker validation (compile with -DBUG_xxx, see run_flow.py):
//   BUG_NO_STALL  BUG_NO_FWD_WB  BUG_NO_BYPASS  BUG_FLUSH_ONE  BUG_FWD_R0
//   BUG_STORE_NOFWD
// =============================================================================
`timescale 1ns/1ps
`include "core_defs.vh"

module pipeline_core (
    input  wire        clk,
    input  wire        rst_n,

    // instruction fetch (asynchronous-read instruction memory lives in the TB)
    output wire [7:0]  imem_addr,
    input  wire [15:0] imem_data,

    // architectural retirement interface (WB stage) -- used by the scoreboard
    output wire        retire_valid,
    output wire [7:0]  retire_pc,
    output wire        retire_we,
    output wire [2:0]  retire_rd,
    output wire [15:0] retire_data,
    output wire        retire_st,
    output wire [5:0]  retire_saddr,
    output wire [15:0] retire_sdata,

    // observation points used only by the functional-coverage monitor
    output wire        dbg_ex_valid,
    output wire [3:0]  dbg_ex_op,
    output wire        dbg_fwd_a_ex,
    output wire        dbg_fwd_b_ex,
    output wire        dbg_fwd_a_wb,
    output wire        dbg_fwd_b_wb,
    output wire        dbg_fwd_wb_load,
    output wire        dbg_stall,
    output wire        dbg_id_valid,
    output wire [3:0]  dbg_id_op,
    output wire        dbg_flush,
    output wire        dbg_br_taken,
    output wire        dbg_bypass_a,
    output wire        dbg_bypass_b,
    output wire        dbg_mem_valid,
    output wire        dbg_mem_ld,
    output wire        dbg_mem_st,
    output wire [5:0]  dbg_mem_addr,
    output wire        dbg_illegal_lw_fwd   // invariant: must never be 1
);

    // ------------------------------------------------------------------ helpers
    function is_writer;           // instruction writes a destination register
        input [3:0] op;
        begin is_writer = (op <= `OP_LW); end
    endfunction

    function uses_rs1;
        input [3:0] op;
        begin uses_rs1 = (op <= `OP_BNE); end
    endfunction

    function uses_rs2;
        input [3:0] op;
        begin uses_rs2 = (op <= `OP_OR) || (op == `OP_SW) ||
                         (op == `OP_BEQ) || (op == `OP_BNE); end
    endfunction

    function [3:0] norm_op;       // undefined opcodes behave as NOP
        input [3:0] op;
        begin norm_op = (op <= `OP_BNE) ? op : `OP_NOP; end
    endfunction

    // ------------------------------------------------------------------ state
    reg [7:0]  pc;
    reg [15:0] regfile [0:7];
    reg [15:0] dmem    [0:63];
    integer    i;

    // IF/ID
    reg        ifid_valid;
    reg [15:0] ifid_instr;
    reg [7:0]  ifid_pc;
    // ID/EX
    reg        idex_valid;
    reg [3:0]  idex_op;
    reg [2:0]  idex_rd, idex_rs1, idex_rs2, idex_imm;
    reg [15:0] idex_a, idex_b;
    reg [7:0]  idex_pc;
    // EX/MEM
    reg        exmem_valid;
    reg [3:0]  exmem_op;
    reg [2:0]  exmem_rd;
    reg [15:0] exmem_alu, exmem_sdata;
    reg [7:0]  exmem_pc;
    // MEM/WB
    reg        memwb_valid;
    reg [3:0]  memwb_op;
    reg [2:0]  memwb_rd;
    reg [15:0] memwb_data;
    reg [7:0]  memwb_pc;
    reg        memwb_st;
    reg [5:0]  memwb_saddr;
    reg [15:0] memwb_sdata;

    // ------------------------------------------------------------------ ID decode
    wire [3:0] id_op    = norm_op(ifid_instr[15:12]);
    wire [2:0] id_rs1   = ifid_instr[8:6];
    wire [2:0] id_rs2   = ifid_instr[5:3];
    wire [2:0] id_imm   = ifid_instr[2:0];
    wire [2:0] id_rd    = is_writer(id_op) ? ifid_instr[11:9] : 3'd0;
    wire       id_use1  = ifid_valid && uses_rs1(id_op);
    wire       id_use2  = ifid_valid && uses_rs2(id_op);

    // ------------------------------------------------------------------ WB-stage write enable (also used for bypass)
    wire wb_we = memwb_valid && is_writer(memwb_op) && (memwb_rd != 3'd0);

    // register read with write-through bypass (producer is 3 instructions ahead)
`ifdef BUG_NO_BYPASS
    wire byp_a = 1'b0;
    wire byp_b = 1'b0;
`else
    wire byp_a = wb_we && id_use1 && (memwb_rd == id_rs1);
    wire byp_b = wb_we && id_use2 && (memwb_rd == id_rs2);
`endif
    wire [15:0] rf_a = (id_rs1 == 3'd0) ? 16'h0000 : (byp_a ? memwb_data : regfile[id_rs1]);
    wire [15:0] rf_b = (id_rs2 == 3'd0) ? 16'h0000 : (byp_b ? memwb_data : regfile[id_rs2]);

    // ------------------------------------------------------------------ load-use hazard
    wire load_use = idex_valid && (idex_op == `OP_LW) && (idex_rd != 3'd0) &&
                    ((id_use1 && (id_rs1 == idex_rd)) ||
                     (id_use2 && (id_rs2 == idex_rd)));
`ifdef BUG_NO_STALL
    wire stall = 1'b0;
`else
    wire stall = load_use;
`endif

    // ------------------------------------------------------------------ forwarding (into EX)
    wire ex_use1 = idex_valid && uses_rs1(idex_op);
    wire ex_use2 = idex_valid && uses_rs2(idex_op);

    // EX/MEM producer: must write a register, must NOT be a load (data not ready)
`ifdef BUG_FWD_R0
    wire exmem_rd_ok = 1'b1;
`else
    wire exmem_rd_ok = (exmem_rd != 3'd0);
`endif
    wire exmem_fwd_ok = exmem_valid && is_writer(exmem_op) && (exmem_op != `OP_LW) && exmem_rd_ok;

    wire fwd_a_ex = ex_use1 && exmem_fwd_ok && (exmem_rd == idex_rs1);
    wire fwd_b_ex = ex_use2 && exmem_fwd_ok && (exmem_rd == idex_rs2);
`ifdef BUG_NO_FWD_WB
    wire fwd_a_wb = 1'b0;
    wire fwd_b_wb = 1'b0;
`else
    wire fwd_a_wb = ex_use1 && wb_we && (memwb_rd == idex_rs1) && !fwd_a_ex;
    wire fwd_b_wb = ex_use2 && wb_we && (memwb_rd == idex_rs2) && !fwd_b_ex;
`endif

    // A load sitting in EX/MEM whose result the EX instruction needs would be a
    // missed stall -- must be impossible.
    wire illegal_lw_fwd = idex_valid && exmem_valid && (exmem_op == `OP_LW) && (exmem_rd != 3'd0) &&
                          ((ex_use1 && exmem_rd == idex_rs1) || (ex_use2 && exmem_rd == idex_rs2));

    wire [15:0] alu_a = fwd_a_ex ? exmem_alu : (fwd_a_wb ? memwb_data : idex_a);
    wire [15:0] alu_b = fwd_b_ex ? exmem_alu : (fwd_b_wb ? memwb_data : idex_b);

    // ------------------------------------------------------------------ EX: ALU + branch resolve
    wire [15:0] imm_s = {{13{idex_imm[2]}}, idex_imm};
    reg  [15:0] alu_result;
    reg         br_cond;

    always @(*) begin
        alu_result = 16'h0000;
        br_cond    = 1'b0;
        case (idex_op)
            `OP_ADD : alu_result = alu_a + alu_b;
            `OP_SUB : alu_result = alu_a - alu_b;
            `OP_AND : alu_result = alu_a & alu_b;
            `OP_OR  : alu_result = alu_a | alu_b;
            `OP_ADDI: alu_result = alu_a + imm_s;
            `OP_LW  : alu_result = alu_a + imm_s;      // address
            `OP_SW  : alu_result = alu_a + imm_s;      // address
            `OP_BEQ : br_cond    = (alu_a == alu_b);
            `OP_BNE : br_cond    = (alu_a != alu_b);
            default : ;
        endcase
    end

    wire       is_branch = idex_valid && ((idex_op == `OP_BEQ) || (idex_op == `OP_BNE));
    wire       flush     = is_branch && br_cond;
    wire [7:0] br_target = idex_pc + 8'd1 + {5'd0, idex_imm};

`ifdef BUG_FLUSH_ONE
    wire kill_idex = 1'b0;          // wrong-path instruction in ID is not squashed
`else
    wire kill_idex = flush;
`endif
`ifdef BUG_STORE_NOFWD
    wire [15:0] store_data = idex_b;
`else
    wire [15:0] store_data = alu_b;
`endif

    // ------------------------------------------------------------------ pipeline registers
    always @(posedge clk) begin
        if (!rst_n) begin
            pc          <= 8'd0;
            ifid_valid  <= 1'b0;  ifid_instr <= 16'h0;  ifid_pc <= 8'd0;
            idex_valid  <= 1'b0;  idex_op    <= `OP_NOP;
            idex_rd <= 3'd0; idex_rs1 <= 3'd0; idex_rs2 <= 3'd0; idex_imm <= 3'd0;
            idex_a  <= 16'h0; idex_b <= 16'h0; idex_pc <= 8'd0;
            exmem_valid <= 1'b0;  exmem_op   <= `OP_NOP; exmem_rd <= 3'd0;
            exmem_alu   <= 16'h0; exmem_sdata<= 16'h0;   exmem_pc <= 8'd0;
            memwb_valid <= 1'b0;  memwb_op   <= `OP_NOP; memwb_rd <= 3'd0;
            memwb_data  <= 16'h0; memwb_pc   <= 8'd0;
            memwb_st    <= 1'b0;  memwb_saddr<= 6'd0;    memwb_sdata <= 16'h0;
            for (i = 0; i < 8;  i = i + 1) regfile[i] <= 16'h0;
            for (i = 0; i < 64; i = i + 1) dmem[i]    <= 16'h0;
        end else begin
            // ---------------- IF
            if (flush) begin
                pc         <= br_target;
                ifid_valid <= 1'b0;
            end else if (!stall) begin
                pc         <= pc + 8'd1;
                ifid_instr <= imem_data;
                ifid_pc    <= pc;
                ifid_valid <= 1'b1;
            end   // stall: PC and IF/ID hold

            // ---------------- ID
            if (kill_idex || stall) begin
                idex_valid <= 1'b0;
                idex_op    <= `OP_NOP;
            end else begin
                idex_valid <= ifid_valid;
                idex_op    <= id_op;
                idex_rd    <= id_rd;
                idex_rs1   <= id_rs1;
                idex_rs2   <= id_rs2;
                idex_imm   <= id_imm;
                idex_a     <= rf_a;
                idex_b     <= rf_b;
                idex_pc    <= ifid_pc;
            end

            // ---------------- EX
            exmem_valid <= idex_valid;
            exmem_op    <= idex_op;
            exmem_rd    <= idex_rd;
            exmem_alu   <= alu_result;
            exmem_sdata <= store_data;
            exmem_pc    <= idex_pc;

            // ---------------- MEM
            memwb_valid <= exmem_valid;
            memwb_op    <= exmem_op;
            memwb_rd    <= exmem_rd;
            memwb_pc    <= exmem_pc;
            memwb_data  <= (exmem_op == `OP_LW) ? dmem[exmem_alu[5:0]] : exmem_alu;
            memwb_st    <= exmem_valid && (exmem_op == `OP_SW);
            memwb_saddr <= exmem_alu[5:0];
            memwb_sdata <= exmem_sdata;
            if (exmem_valid && (exmem_op == `OP_SW))
                dmem[exmem_alu[5:0]] <= exmem_sdata;

            // ---------------- WB
            if (wb_we)
                regfile[memwb_rd] <= memwb_data;
        end
    end

    // ------------------------------------------------------------------ outputs
    assign imem_addr    = pc;

    assign retire_valid = memwb_valid && (memwb_op != `OP_NOP);
    assign retire_pc    = memwb_pc;
    assign retire_we    = wb_we;
    assign retire_rd    = memwb_rd;
    assign retire_data  = memwb_data;
    assign retire_st    = memwb_st;
    assign retire_saddr = memwb_saddr;
    assign retire_sdata = memwb_sdata;

    assign dbg_ex_valid    = idex_valid;
    assign dbg_ex_op       = idex_op;
    assign dbg_fwd_a_ex    = fwd_a_ex;
    assign dbg_fwd_b_ex    = fwd_b_ex;
    assign dbg_fwd_a_wb    = fwd_a_wb;
    assign dbg_fwd_b_wb    = fwd_b_wb;
    assign dbg_fwd_wb_load = (memwb_op == `OP_LW);
    assign dbg_stall       = stall;
    assign dbg_id_valid    = ifid_valid;
    assign dbg_id_op       = id_op;
    assign dbg_flush       = flush;
    assign dbg_br_taken    = flush;
    assign dbg_bypass_a    = byp_a && !stall && !flush;
    assign dbg_bypass_b    = byp_b && !stall && !flush;
    assign dbg_mem_valid   = exmem_valid;
    assign dbg_mem_ld      = exmem_valid && (exmem_op == `OP_LW);
    assign dbg_mem_st      = exmem_valid && (exmem_op == `OP_SW);
    assign dbg_mem_addr    = exmem_alu[5:0];
    assign dbg_illegal_lw_fwd = illegal_lw_fwd;

endmodule
