// =============================================================================
// tb_core.v -- self-checking, coverage-driven testbench (pure Verilog-2001)
//
// What it does, per test:
//   1. Generates a random 32-instruction program (constrained by a "knob"
//      vector: 9 opcode weights, P(dependent operand), P(re-use memory address)).
//      Unused instruction fields are filled with random garbage on purpose.
//   2. Runs the program on a behavioural ISA reference model -> expected
//      retirement trace + expected final regfile / data memory.
//   3. Runs the DUT and compares EVERY retired instruction (pc, rd, data,
//      store address/data) against the reference model, in order, then compares
//      final architectural state.  Any mismatch is an error.
//   4. Samples functional coverage (69 cross-coverage slots, 65 of them legal).
//
// Plusargs
//   +MODE=BASELINE | EXPLORE | GUIDED   (default BASELINE)
//       BASELINE : uniform opcodes, P(dep)=0, P(mem)=0   (pure random)
//       EXPLORE  : every test draws random knobs (training-data generation)
//       GUIDED   : every test draws one of the knob vectors in +KNOBS=<file>
//   +SEED=n  +TESTS=n  +TESTS_CSV=<file>  +BINS_CSV=<file>  +KNOBS=<file>
//
// Knob file format (plain integers, whitespace separated):
//   K  then K rows of 11 ints:  w0 .. w8  p_dep  p_mem
// =============================================================================
`timescale 1ns/1ps
`include "core_defs.vh"

module tb_core;

    parameter NINSTR = 32;      // instructions per generated program
    parameter NSLOT  = 69;      // coverage slots (see header of slot map below)
    parameter MAXK   = 64;      // max knob vectors in a GUIDED knob file

    // ---------------------------------------------------------------- clock/reset
    reg clk;
    reg rst_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---------------------------------------------------------------- DUT
    reg  [15:0] imem [0:255];
    wire [7:0]  imem_addr;
    wire [15:0] imem_data;
    assign imem_data = imem[imem_addr];

    wire        retire_valid, retire_we, retire_st;
    wire [7:0]  retire_pc;
    wire [2:0]  retire_rd;
    wire [15:0] retire_data, retire_sdata;
    wire [5:0]  retire_saddr;

    wire        dbg_ex_valid, dbg_fwd_a_ex, dbg_fwd_b_ex, dbg_fwd_a_wb, dbg_fwd_b_wb;
    wire        dbg_fwd_wb_load, dbg_stall, dbg_id_valid, dbg_flush, dbg_br_taken;
    wire        dbg_bypass_a, dbg_bypass_b, dbg_mem_valid, dbg_mem_ld, dbg_mem_st;
    wire        dbg_illegal_lw_fwd;
    wire [3:0]  dbg_ex_op, dbg_id_op;
    wire [5:0]  dbg_mem_addr;

    pipeline_core dut (
        .clk(clk), .rst_n(rst_n),
        .imem_addr(imem_addr), .imem_data(imem_data),
        .retire_valid(retire_valid), .retire_pc(retire_pc), .retire_we(retire_we),
        .retire_rd(retire_rd), .retire_data(retire_data), .retire_st(retire_st),
        .retire_saddr(retire_saddr), .retire_sdata(retire_sdata),
        .dbg_ex_valid(dbg_ex_valid), .dbg_ex_op(dbg_ex_op),
        .dbg_fwd_a_ex(dbg_fwd_a_ex), .dbg_fwd_b_ex(dbg_fwd_b_ex),
        .dbg_fwd_a_wb(dbg_fwd_a_wb), .dbg_fwd_b_wb(dbg_fwd_b_wb),
        .dbg_fwd_wb_load(dbg_fwd_wb_load), .dbg_stall(dbg_stall),
        .dbg_id_valid(dbg_id_valid), .dbg_id_op(dbg_id_op),
        .dbg_flush(dbg_flush), .dbg_br_taken(dbg_br_taken),
        .dbg_bypass_a(dbg_bypass_a), .dbg_bypass_b(dbg_bypass_b),
        .dbg_mem_valid(dbg_mem_valid), .dbg_mem_ld(dbg_mem_ld),
        .dbg_mem_st(dbg_mem_st), .dbg_mem_addr(dbg_mem_addr),
        .dbg_illegal_lw_fwd(dbg_illegal_lw_fwd)
    );

    // ---------------------------------------------------------------- config / state
    reg [8*16-1:0]  mode_str;
    reg [8*200-1:0] knob_file, tests_csv, bins_csv;
    integer mode_id;            // 0 BASELINE, 1 GUIDED, 2 EXPLORE
    integer num_tests, seed_val, rseed;
    integer fd_t, fd_b, fd_k;

    integer kw [0:8];           // opcode weights of the current test
    integer kp_dep, kp_mem;     // dependency / memory-reuse probabilities (%)
    integer pool [0:MAXK*11-1];
    integer pool_n;

    // reference-model data
    reg [15:0] init_reg [0:7];
    reg [15:0] init_mem [0:63];
    reg [15:0] ref_reg  [0:7];
    reg [15:0] ref_mem  [0:63];
    reg [7:0]  ref_pc    [0:255];
    reg        ref_we    [0:255];
    reg [2:0]  ref_rd    [0:255];
    reg [15:0] ref_data  [0:255];
    reg        ref_st    [0:255];
    reg [5:0]  ref_saddr [0:255];
    reg [15:0] ref_sdata [0:255];
    integer    ref_n;

    // checking / coverage state
    reg     checking, sampling;
    integer ret_idx;
    integer errors, test_errors;
    integer cov_test  [0:NSLOT-1];
    integer cov_tests_hit [0:NSLOT-1];   // number of tests that hit the slot
    reg     slot_exists [0:NSLOT-1];
    reg        pm_valid, pm_ld, pm_st;
    reg [5:0]  pm_addr;

    integer t, k, j, tot, done, test_cycles, total_cycles, distinct;

    // ---------------------------------------------------------------- utilities
    function integer rnd;               // uniform 0..n-1
        input integer n;
        begin
            rnd = {$random(rseed)} % n;
        end
    endfunction

    task err;
        input [8*40-1:0] msg;
        begin
            errors      = errors + 1;
            test_errors = test_errors + 1;
            if (errors <= 10)
                $display("ERROR @%0t test=%0d ret_idx=%0d : %0s", $time, t, ret_idx, msg);
        end
    endtask

    task hit;
        input integer idx;
        begin
            cov_test[idx] = cov_test[idx] + 1;
        end
    endtask

    // ---------------------------------------------------------------- coverage slot map
    //   0..35  : consumer opcode(0..8) x forward path{A_exmem,B_exmem,A_memwb,B_memwb}  idx = op*4+path
    //                (B paths do not exist for ADDI/LW -> 4 illegal slots)
    //   36,37  : memwb forward that carries LOAD data (A, B)
    //   38..46 : load-use stall, indexed by consumer opcode
    //   47..50 : branch outcome  {BEQ taken, BEQ not-taken, BNE taken, BNE not-taken}
    //   51..54 : same four, but with at least one forwarded operand
    //   55,56  : register-file write-through bypass (A, B)
    //   57..65 : taken-branch flush, indexed by opcode of the squashed ID instruction
    //   66..68 : back-to-back same-address memory ops in MEM {SW->LW, SW->SW, LW->SW}
    task init_slots;
        integer s;
        begin
            for (s = 0; s < NSLOT; s = s + 1) begin
                slot_exists[s]    = 1'b1;
                cov_tests_hit[s]  = 0;
                cov_test[s]       = 0;
            end
            for (s = 0; s < 36; s = s + 1) begin
                // path 1 and 3 are operand-B paths; ADDI (op 4) and LW (op 5) have no operand B
                if (((s % 4) == 1 || (s % 4) == 3) && ((s / 4) == 4 || (s / 4) == 5))
                    slot_exists[s] = 1'b0;
            end
        end
    endtask

    // ---------------------------------------------------------------- knob selection
    task choose_knobs;
        integer s;
        begin
            if (mode_id == 2) begin                    // EXPLORE
                for (s = 0; s < 9; s = s + 1) kw[s] = rnd(61);
                kp_dep = rnd(86);
                kp_mem = rnd(86);
            end else if (mode_id == 1) begin           // GUIDED
                j = rnd(pool_n);
                for (s = 0; s < 9; s = s + 1) kw[s] = pool[j*11 + s];
                kp_dep = pool[j*11 + 9];
                kp_mem = pool[j*11 + 10];
            end else begin                             // BASELINE (pure random)
                for (s = 0; s < 9; s = s + 1) kw[s] = 10;
                kp_dep = 0;
                kp_mem = 0;
            end
            tot = 0;
            for (s = 0; s < 9; s = s + 1) tot = tot + kw[s];
            if (tot == 0) begin kw[0] = 1; tot = 1; end
        end
    endtask

    // ---------------------------------------------------------------- program generation
    task gen_program;
        integer i, s, r, acc, op, rd, rs1, rs2, imm, wr;
        integer rec0, rec1, rec2, pick, lb, li;
        begin
            for (i = 0; i < 256; i = i + 1) imem[i] = {`OP_NOP, 12'h000};
            rec0 = 1; rec1 = 2; rec2 = 3;          // recently written registers
            lb = 1;   li = 0;                      // last memory base / offset
            for (i = 0; i < NINSTR; i = i + 1) begin
                // weighted opcode pick
                r = rnd(tot); acc = 0; op = 0;
                for (s = 0; s < 9; s = s + 1) begin
                    if (r >= acc && r < acc + kw[s]) op = s;
                    acc = acc + kw[s];
                end
                rd  = rnd(8);
                rs1 = rnd(8);
                rs2 = rnd(8);
                imm = rnd(8);
                // dependency bias: reuse a recently written register as a source
                if (rnd(100) < kp_dep) begin
                    pick = rnd(3);
                    rs1  = (pick == 0) ? rec0 : ((pick == 1) ? rec1 : rec2);
                end
                if (rnd(100) < kp_dep) begin
                    pick = rnd(3);
                    rs2  = (pick == 0) ? rec0 : ((pick == 1) ? rec1 : rec2);
                end
                // memory-address bias: same base register and offset as previous mem op
                if ((op == `OP_LW || op == `OP_SW) && rnd(100) < kp_mem) begin
                    rs1 = lb;
                    imm = li;
                end
                if (op == `OP_LW || op == `OP_SW) begin
                    lb = rs1;
                    li = imm;
                end
                imem[i] = {op[3:0], rd[2:0], rs1[2:0], rs2[2:0], imm[2:0]};
                wr = (op <= `OP_LW);
                if (wr && rd != 0) begin
                    rec2 = rec1; rec1 = rec0; rec0 = rd;
                end
            end
        end
    endtask

    // ---------------------------------------------------------------- ISA reference model
    task run_ref;
        integer s, pc_r, n, op, rd, rs1, rs2, imm, npc, wr, st;
        reg [15:0] inst, a, b, res, sd, ea;
        reg [5:0]  sa;
        reg [15:0] simm;
        begin
            for (s = 0; s < 8;  s = s + 1) ref_reg[s] = init_reg[s];
            ref_reg[0] = 16'h0000;
            for (s = 0; s < 64; s = s + 1) ref_mem[s] = init_mem[s];
            pc_r = 0; n = 0;
            while (pc_r < NINSTR) begin
                inst = imem[pc_r];
                op  = inst[15:12];
                rd  = inst[11:9];
                rs1 = inst[8:6];
                rs2 = inst[5:3];
                imm = inst[2:0];
                simm = {{13{inst[2]}}, inst[2:0]};
                a = ref_reg[rs1];
                b = ref_reg[rs2];
                npc = pc_r + 1;
                wr = 0; st = 0; res = 16'h0; sd = 16'h0; sa = 6'd0;
                case (op)
                    `OP_ADD : begin res = a + b;    wr = 1; end
                    `OP_SUB : begin res = a - b;    wr = 1; end
                    `OP_AND : begin res = a & b;    wr = 1; end
                    `OP_OR  : begin res = a | b;    wr = 1; end
                    `OP_ADDI: begin res = a + simm; wr = 1; end
                    `OP_LW  : begin ea = a + simm; sa = ea[5:0]; res = ref_mem[sa]; wr = 1; end
                    `OP_SW  : begin ea = a + simm; sa = ea[5:0]; sd = b; st = 1; ref_mem[sa] = b; end
                    `OP_BEQ : if (a == b) npc = pc_r + 1 + imm;
                    `OP_BNE : if (a != b) npc = pc_r + 1 + imm;
                    default : ;
                endcase
                if (op <= `OP_BNE) begin
                    ref_pc[n]    = pc_r;
                    ref_we[n]    = (wr != 0) && (rd != 0);
                    ref_rd[n]    = (wr != 0) ? rd : 3'd0;
                    ref_data[n]  = res;
                    ref_st[n]    = (st != 0);
                    ref_saddr[n] = sa;
                    ref_sdata[n] = sd;
                    n = n + 1;
                    if (wr != 0 && rd != 0) ref_reg[rd] = res;
                end
                pc_r = npc;
            end
            ref_n = n;
        end
    endtask

    // ---------------------------------------------------------------- scoreboard (in-order retire compare)
    always @(negedge clk) begin
        if (checking) begin
            if (dbg_illegal_lw_fwd === 1'b1) err("invariant: load result needed from EX/MEM");
            if (retire_valid === 1'b1) begin
                if (ret_idx >= ref_n) begin
                    err("extra retire (wrong-path instr?)");
                end else begin
                    if (retire_pc !== ref_pc[ret_idx]) err("retire pc mismatch");
                    if (retire_we !== ref_we[ret_idx]) err("reg-write enable mismatch");
                    else if (retire_we) begin
                        if (retire_rd   !== ref_rd[ret_idx])   err("rd mismatch");
                        if (retire_data !== ref_data[ret_idx]) err("write data mismatch");
                    end
                    if (retire_st !== ref_st[ret_idx]) err("store flag mismatch");
                    else if (retire_st) begin
                        if (retire_saddr !== ref_saddr[ret_idx]) err("store addr mismatch");
                        if (retire_sdata !== ref_sdata[ret_idx]) err("store data mismatch");
                    end
                end
                ret_idx = ret_idx + 1;
            end else if (retire_valid !== 1'b0) begin
                err("retire_valid is X");
            end
        end
    end

    // ---------------------------------------------------------------- functional coverage monitor
    always @(negedge clk) begin
        if (sampling) begin
            if (dbg_ex_valid) begin
                if (dbg_fwd_a_ex) hit(dbg_ex_op*4 + 0);
                if (dbg_fwd_b_ex) hit(dbg_ex_op*4 + 1);
                if (dbg_fwd_a_wb) hit(dbg_ex_op*4 + 2);
                if (dbg_fwd_b_wb) hit(dbg_ex_op*4 + 3);
                if (dbg_fwd_a_wb && dbg_fwd_wb_load) hit(36);
                if (dbg_fwd_b_wb && dbg_fwd_wb_load) hit(37);
                if (dbg_ex_op == `OP_BEQ) begin
                    if (dbg_br_taken) hit(47); else hit(48);
                    if (dbg_fwd_a_ex || dbg_fwd_b_ex || dbg_fwd_a_wb || dbg_fwd_b_wb)
                        if (dbg_br_taken) hit(51); else hit(52);
                end
                if (dbg_ex_op == `OP_BNE) begin
                    if (dbg_br_taken) hit(49); else hit(50);
                    if (dbg_fwd_a_ex || dbg_fwd_b_ex || dbg_fwd_a_wb || dbg_fwd_b_wb)
                        if (dbg_br_taken) hit(53); else hit(54);
                end
            end
            if (dbg_stall && dbg_id_valid && dbg_id_op <= 4'd8) hit(38 + dbg_id_op);
            if (dbg_bypass_a) hit(55);
            if (dbg_bypass_b) hit(56);
            if (dbg_flush && dbg_id_valid && dbg_id_op <= 4'd8) hit(57 + dbg_id_op);
            if (dbg_mem_valid && pm_valid && (dbg_mem_addr == pm_addr)) begin
                if (pm_st && dbg_mem_ld) hit(66);
                if (pm_st && dbg_mem_st) hit(67);
                if (pm_ld && dbg_mem_st) hit(68);
            end
            pm_valid = dbg_mem_valid && (dbg_mem_ld || dbg_mem_st);
            pm_ld    = dbg_mem_ld;
            pm_st    = dbg_mem_st;
            pm_addr  = dbg_mem_addr;
        end
    end

    // ---------------------------------------------------------------- main
    initial begin
        // ---- plusargs
        if (!$value$plusargs("MODE=%s", mode_str)) mode_str = "BASELINE";
        if (!$value$plusargs("SEED=%d",  seed_val))  seed_val  = 1;
        if (!$value$plusargs("TESTS=%d", num_tests)) num_tests = 500;
        if (!$value$plusargs("TESTS_CSV=%s", tests_csv)) tests_csv = "results/tests.csv";
        if (!$value$plusargs("BINS_CSV=%s",  bins_csv))  bins_csv  = "results/bins.csv";
        if (!$value$plusargs("KNOBS=%s",     knob_file)) knob_file = "results/knobs.txt";

        mode_id = 0;
        if (mode_str == "GUIDED")  mode_id = 1;
        if (mode_str == "EXPLORE") mode_id = 2;

        rseed       = seed_val;
        errors      = 0;
        total_cycles= 0;
        checking    = 1'b0;
        sampling    = 1'b0;
        ret_idx     = 0;
        ref_n       = 0;
        pm_valid    = 1'b0; pm_ld = 1'b0; pm_st = 1'b0; pm_addr = 6'd0;
        init_slots;

        // ---- knob pool for GUIDED mode
        pool_n = 1;
        if (mode_id == 1) begin
            fd_k = $fopen(knob_file, "r");
            if (fd_k == 0) begin
                $display("FATAL: cannot open knob file");
                $finish;
            end
            k = $fscanf(fd_k, "%d", pool_n);
            if (pool_n < 1 || pool_n > MAXK) begin
                $display("FATAL: bad knob count %0d", pool_n);
                $finish;
            end
            for (j = 0; j < pool_n*11; j = j + 1) k = $fscanf(fd_k, "%d", pool[j]);
            $fclose(fd_k);
        end

        // ---- output files
        fd_t = $fopen(tests_csv, "w");
        fd_b = $fopen(bins_csv,  "w");
        $fwrite(fd_t, "test,cycles,cum_cycles,cum_bins,w0,w1,w2,w3,w4,w5,w6,w7,w8,p_dep,p_mem");
        for (j = 0; j < NSLOT; j = j + 1) $fwrite(fd_t, ",b%0d", j);
        $fwrite(fd_t, "\n");

        rst_n = 1'b0;

        // ---- test loop
        for (t = 0; t < num_tests; t = t + 1) begin
            choose_knobs;
            gen_program;
            init_reg[0] = 16'h0000;
            for (j = 1; j < 8;  j = j + 1) init_reg[j] = $random(rseed);
            for (j = 0; j < 64; j = j + 1) init_mem[j] = $random(rseed);
            run_ref;

            // reset, then back-door load the architectural start state
            checking = 1'b0; sampling = 1'b0;
            rst_n = 1'b0;
            repeat (2) @(posedge clk);
            #1;
            for (j = 0; j < 8;  j = j + 1) dut.regfile[j] = init_reg[j];
            for (j = 0; j < 64; j = j + 1) dut.dmem[j]    = init_mem[j];
            for (j = 0; j < NSLOT; j = j + 1) cov_test[j] = 0;
            pm_valid = 1'b0;
            ret_idx = 0; test_errors = 0; test_cycles = 0; done = 0;
            rst_n = 1'b1;
            checking = 1'b1; sampling = 1'b1;

            while (!done) begin
                @(posedge clk);
                test_cycles = test_cycles + 1;
                if (ret_idx >= ref_n) done = 1;
                else if (test_cycles > 40*NINSTR) begin
                    err("TIMEOUT: program did not retire");
                    done = 1;
                end
            end
            sampling = 1'b0;
            repeat (8) @(posedge clk);          // drain: catches extra / late retires
            checking = 1'b0;

            // final architectural state
            for (j = 1; j < 8; j = j + 1)
                if (dut.regfile[j] !== ref_reg[j]) err("final regfile mismatch");
            for (j = 0; j < 64; j = j + 1)
                if (dut.dmem[j] !== ref_mem[j]) err("final dmem mismatch");

            // ---- per-test logging
            total_cycles = total_cycles + test_cycles;
            for (j = 0; j < NSLOT; j = j + 1)
                if (cov_test[j] > 0 && slot_exists[j]) cov_tests_hit[j] = cov_tests_hit[j] + 1;
            distinct = 0;
            for (j = 0; j < NSLOT; j = j + 1)
                if (slot_exists[j] && cov_tests_hit[j] > 0) distinct = distinct + 1;

            $fwrite(fd_t, "%0d,%0d,%0d,%0d", t, test_cycles, total_cycles, distinct);
            for (j = 0; j < 9; j = j + 1) $fwrite(fd_t, ",%0d", kw[j]);
            $fwrite(fd_t, ",%0d,%0d", kp_dep, kp_mem);
            for (j = 0; j < NSLOT; j = j + 1) $fwrite(fd_t, ",%0d", cov_test[j]);
            $fwrite(fd_t, "\n");
        end

        $fwrite(fd_b, "slot,exists,tests_hit\n");
        for (j = 0; j < NSLOT; j = j + 1)
            $fwrite(fd_b, "%0d,%0d,%0d\n", j, slot_exists[j], cov_tests_hit[j]);
        $fclose(fd_t);
        $fclose(fd_b);

        $display("RESULT mode=%0s seed=%0d tests=%0d cycles=%0d bins_hit=%0d/65 errors=%0d",
                 mode_str, seed_val, num_tests, total_cycles, distinct, errors);
        $finish;
    end

endmodule
