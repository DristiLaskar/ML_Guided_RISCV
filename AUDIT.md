# Audit of the original project (SystemVerilog version) vs. the resume

Everything below was reproduced by running the original code (Icarus Verilog 12, original `results/` regenerated with seed 1 -
the numbers in the old README reproduce exactly) and by reading the RTL/TB.

## 1. Resume claims vs. what the original code actually did

| Resume claim | Verdict | Evidence |
|---|---|---|
| "Designed and **verified** a 5-stage pipelined core ... hazard detection, forwarding, branch resolution" | **Overstated.** The core existed, but nothing was *verified*. | The old testbench had **no reference model and no checker**; it only counted events. It could not detect a wrong result. The RTL also had real bugs (section 2). |
| "constrained-random testbench" | **Overstated.** | Stimulus was plain `$urandom_range` per field - no constraints, no program structure. |
| "**126** cross-coverage bins (opcode x hazard-event)" | **Misleading.** | The 126 bins existed only in the offline Python script, not in the testbench (the TB's own metric was 18 flat bins). 126 = 63 (opcode x event) + **63 (opcode x rd "first use") bins that are not hazard events at all**. The "cross" also paired the opcode being *fetched* with hazard events caused by *different* instructions already in the pipeline. |
| "trained a Decision Tree on coverage traces to **bias stimulus**" | **Not true as built.** | The tree was fitted and printed, but the weights written to `weights.txt` came from a separate per-opcode ratio (`derive_opcode_weights`). The tree never influenced the stimulus. |
| ML result: `back2back_raw` is the dominant feature (importance 0.65) | **Artifact of a bug.** | The testbench logged the *cumulative counter* `cov_back2back_raw`, not a per-cycle flag (column values 0,0,0,...,3,4,5,5,5...). The feature is a monotone step function of time. The tree learned "later in the run", and the README presented it as "data-dependency chains are what make bins hard to hit". |
| "Reduced cycles to 100 % coverage by **19 %**" | **Wrong arithmetic + one seed.** | 864 -> 728 cycles is a 15.7 % reduction; 1.19x is a speed-up *ratio*, not 19 % fewer cycles. And only seed 1 was run. Re-running the old code on 8 seeds (weights trained on seed 1): random vs guided cycles-to-100 % = 864/728, 1325/728, 727/784, 1004/1301, 1385/1165, 686/1296, 754/2010, 1297/748 - guided was *slower* on 4 of 8 seeds. The 19 % was a lucky seed. |
| "**24 %** speed-up on hardest-to-hit bins" | **Wrong.** | 1.24x was the cycle count to reach the 95 % mark (320 -> 258), not the hardest bins. The 95 % -> 100 % stretch is 544 vs 470 cycles = 1.16x. |

## 2. Bugs in the original RTL / testbench (found by reading + simulation)

1. **No PC / no instruction memory.** The TB pushed one instruction per cycle into the core. A taken branch could not redirect anything.
2. **Instructions silently dropped on stalls.** The core held IF/ID during a load-use stall but the TB kept presenting a new instruction every cycle, so that instruction was lost.
3. **Incomplete branch flush.** `flush_o` was derived from the EX/MEM register (one stage late) and only killed the instruction entering ID/EX; the wrong-path instruction already in ID/EX still executed.
4. **False forwarding / false stalls.** `rd` was used for SW/BEQ/BNE as if it were a destination (the field held rs2 for those), so stores and branches could forward garbage and trigger stalls; unused `rs2` bits were treated as register operands for ADDI/LW.
5. **No register-file write-through bypass.** A consumer 3 instructions behind its producer read the stale register (forwarding only covered distances 1 and 2).
6. **Immediate not signed.** `logic signed [3:0] imm <= 3-bit` zero-extends, so immediates were 0..7 although documented as signed.
7. **Coverage attribution.** Hazard events were sampled in the same cycle as the opcode at the fetch stage - they belong to different instructions.
8. **`x` values hidden.** The Python scripts converted any `x` in the trace to 0 (`_safe_int`), which can mask real X-propagation instead of flagging it.
9. **SystemVerilog dependence** (`logic`, packages, `always_comb/ff`, enums, `string`, `$urandom`) - the requested change.

## 3. What the new version does instead

* Pure Verilog-2001 (compiles with `iverilog -g2001 -Wall`, zero warnings).
* Real PC + instruction memory; branch resolves in EX with a correct 2-instruction squash; load-use stall that holds PC/IF-ID;
  EX/MEM and MEM/WB forwarding; regfile write-through bypass; r0 hard-wired; unused instruction fields ignored.
* Testbench has a **golden ISA model + in-order scoreboard + final-state compare + invariant check**.
* Six injected bugs (`-DBUG_...`) are all caught - this is the evidence that the checker works.
* 65 legal coverage bins sampled **in the testbench**, each attributed to the correct instruction.
* ML: a decision tree trained on per-test stimulus knobs -> rare-bin hits; the tree's output *is* what drives the guided run.
  Evaluated on 30 held-out seeds with a significance test; training cost and weaknesses reported (see README).

## 4. Resume wording that is now defensible

```
ML-Guided Coverage Closure for a Pipelined RISC-V-Style Core            [GitHub]
- Designed a 5-stage pipelined core in Verilog-2001 (load-use stall, EX/MEM + MEM/WB forwarding,
  regfile write-through bypass, EX-stage branch resolve with 2-instruction flush).
- Built a self-checking constrained-random testbench: random program generator, golden ISA reference model,
  in-order retirement scoreboard and a 65-bin functional-coverage monitor (opcode x hazard cross);
  validated by injecting 6 pipeline bugs - all caught.
- Trained a decision tree (CV AUC 0.70) on 3,000 stimulus/coverage records to steer the generator toward rare bins;
  on 30 held-out seeds, 100% coverage took a median 3,134 vs 6,322 cycles (2.0x, p=0.002), and the rarest
  same-address memory bins were hit ~15x more often.
```
