# Don't Let Your System Decide It's Dead

**Paper:** [https://zenodo.org/records/19069195](https://zenodo.org/records/19069195)

Distributed systems fail in two ways: the failure itself, and the system's automatic response to the failure. The second is often worse. This paper identifies a recovery invariant — based on spectral radius of a gain matrix — that separates safe automatic recovery from cascading failure, and a compensation boundary that determines who should make which decisions.

## Case studies

- TCP retransmission timeout (reference design — satisfies all invariant levels)
- Cassandra hinted handoff
- UNIX swap and OOM killer
- CRDT tombstone garbage collection

## Companion code

MATLAB/Simulink models that formalize and verify the paper's claims. Run `run_all.m` to build all models, check invariants, and print a summary.

## License

Paper: [CC-BY 3.0](https://creativecommons.org/licenses/by/3.0/)