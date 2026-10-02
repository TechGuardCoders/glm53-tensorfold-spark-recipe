# 2026-10-01: this recipe vs MiaAI v1.3.1, same rig

Write-up: [docs/VS-MIA.md](../../docs/VS-MIA.md).

| Folder | Engine | When |
| --- | --- | --- |
| [`ours-tf034`](ours-tf034) | this recipe (TensorFold 0.3.4, prod.env delta, DFlash2) | before the switch, 10-01 afternoon |
| [`mia-v1.3.1`](mia-v1.3.1) | MiaAI-Lab recipe v1.3.1 at its defaults (image `v0.6.0-ae8d1c789b47`, DFlash2) | 10-01 evening; `evals/` is the full E1-E7 set |
| [`ours-after-rollback`](ours-after-rollback) | this recipe again, the same sessions test as Mia's | 10-01 23:15, after switching back |

This recipe's full E1-E7 set is in [`../2026-10-01`](../2026-10-01). `agent-method*.txt` come from
[`agent_method.py`](agent_method.py) (non-streaming, 256-token cap, median of 3); the rest come from jayleaton's
unmodified `bench/glmbench.py` and `bench/multiturn.py`. `-T0` / `-T1` mean the client sent that temperature, and
no suffix means the server default.
