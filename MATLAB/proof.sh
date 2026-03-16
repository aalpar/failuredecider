#!/usr/bin/env bash
set -euo pipefail

# proof.sh — Run all recovery invariant models and verify article claims.
#
# Usage:
#   ./proof.sh              Run full proof (build models + invariant checks + symbolic + verify)
#   ./proof.sh --verify     Run verification checks only (skip model builds and symbolic)
#   ./proof.sh --symbolic   Run symbolic derivations only
#   ./proof.sh --clean      Remove generated .slx files

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
MATLAB="/Applications/MATLAB_R2025b.app/bin/matlab"

if [[ ! -x "$MATLAB" ]]; then
    echo "error: MATLAB not found at $MATLAB" >&2
    echo "       Set MATLAB= to your matlab binary path" >&2
    exit 1
fi

write_runner() {
    # Write a temp .m file that cd's, adds paths, then runs the given code.
    local tmpscript
    tmpscript=$(mktemp "${TMPDIR:-/tmp}/proof_XXXXXX.m")
    cat > "$tmpscript" <<MATLAB_EOF
cd('$PROJECT_DIR');
addpath('models','analysis','symbolic','tests');
$1
MATLAB_EOF
    echo "$tmpscript"
}

run_matlab() {
    local desc="$1"
    local code="$2"
    local tmpout tmpscript
    tmpout=$(mktemp)
    tmpscript=$(write_runner "$code")

    printf "%-50s " "$desc"

    "$MATLAB" -batch "run('$tmpscript')" > "$tmpout" 2>&1

    local rc=$?
    rm -f "$tmpscript"
    if [[ $rc -eq 0 ]]; then
        echo "OK"
    else
        echo "FAIL"
        cat "$tmpout"
        rm -f "$tmpout"
        return 1
    fi
    rm -f "$tmpout"
    return 0
}

run_matlab_verbose() {
    local code="$1"
    local tmpscript
    tmpscript=$(write_runner "$code")

    "$MATLAB" -batch "run('$tmpscript')" 2>&1 \
        | grep -v '^WARNING: package sun.awt' \
        | grep -v '^\[Warning: File .* not found\]' \
        | grep -v '^\[Warning: The model name .* is shadowing' \
        | grep -v '^\[> In ' \
        | grep -v '^\[Warning: Solutions are only valid' \
        | grep -v '^$'

    rm -f "$tmpscript"
}

cmd_clean() {
    echo "Removing generated Simulink models..."
    rm -f "$PROJECT_DIR"/models/*.slx
    echo "Done."
}

cmd_verify() {
    echo "=== Verification (14 checks against article claims) ==="
    echo ""

    local tmpout tmpscript
    tmpout=$(mktemp)
    tmpscript=$(write_runner "
results = verify_all();
n_pass = sum([results.pass]);
n_total = numel(results);
if n_pass < n_total
    error('proof:failed', '%d / %d checks failed', n_total - n_pass, n_total);
end
")

    "$MATLAB" -batch "run('$tmpscript')" > "$tmpout" 2>&1

    local rc=$?
    rm -f "$tmpscript"

    # Print just the check lines and summary
    grep -E '^\s*(PASS|FAIL|ERROR|===)' "$tmpout"

    rm -f "$tmpout"

    if [[ $rc -ne 0 ]]; then
        echo ""
        echo "PROOF FAILED"
        return 1
    fi
    return 0
}

cmd_symbolic() {
    echo "=== Symbolic Derivations ==="
    echo ""
    run_matlab_verbose "
        derive_tcp_stability();
        derive_swap_hstar();
        derive_perron_frobenius();
    "
}

cmd_full() {
    local failed=0
    local start_time=$SECONDS

    echo "============================================================"
    echo " Recovery Invariant — Proof Run"
    echo " $(date '+%Y-%m-%d %H:%M:%S')"
    echo "============================================================"
    echo ""

    # Phase 1: Build Simulink models
    echo "--- Phase 1: Build Simulink models ---"
    echo ""
    run_matlab "  Building tcp_model.slx"        "build_tcp_model();"       || failed=1
    run_matlab "  Building swap_model.slx"       "build_swap_model();"      || failed=1
    run_matlab "  Building cassandra_model.slx"  "build_cassandra_model();" || failed=1
    run_matlab "  Building oom_model.slx"        "build_oom_model();"       || failed=1
    echo ""

    # Phase 2: Invariant checks
    echo "--- Phase 2: Invariant checks ---"
    echo ""
    run_matlab_verbose "
        tcp_sys = make_tcp_sys();
        r = check_invariant(tcp_sys);
        fprintf('  TCP:        L0=%s L1=%s L2=%s L3=%s  rho=%.4f\n', tf(r.level0), tf(r.level1), tf(r.level2), tf(r.level3), r.rho);

        swap_sys = make_swap_sys('database', 'hdd');
        r = check_invariant(swap_sys);
        fprintf('  Swap:       L0=%s L1=%s L2=%s L3=%s  rho=%.4f\n', tf(r.level0), tf(r.level1), tf(r.level2), tf(r.level3), r.rho);

        cass_sys = make_cassandra_sys();
        r = check_invariant(cass_sys);
        fprintf('  Cassandra:  L0=%s L1=%s L2=%s L3=%s  rho=%.4f\n', tf(r.level0), tf(r.level1), tf(r.level2), tf(r.level3), r.rho);

        oom_sys = make_oom_sys(1.2);
        r = check_invariant(oom_sys);
        fprintf('  OOM (1.2):  L0=%s L1=%s L2=%s L3=%s  rho=%.4f\n', tf(r.level0), tf(r.level1), tf(r.level2), tf(r.level3), r.rho);

        function s = tf(b), if b, s = 'PASS'; else, s = 'FAIL'; end, end

        function sys = make_tcp_sys()
            p = tcp_params();
            sys.name='TCP'; sys.n=1; sys.C=p.C; sys.w=@(t)p.w0;
            sys.delta=1; sys.G=-0.5; sys.r=@(t,h)0;
        end
        function sys = make_swap_sys(wl, dt)
            p = swap_params(wl);
            D_total=p.D_total_hdd; D_spare=p.D_spare_hdd;
            sys.name='Swap'; sys.n=2; sys.C=[p.S;D_total];
            sys.w=@(t)[p.W-max(0,p.W-p.S);p.D_normal_hdd];
            sys.delta=[1;2];
            sys.G=compute_gain_matrix(struct('type','swap','f',p.f,'W',p.W,...
                'epsilon',p.epsilon,'buf_per_blocked',p.buf_per_blocked,...
                'block_rate_per_iops',p.block_rate_per_iops));
            sys.r=@(t,h)[0;min(D_spare,2*p.f*max(0,p.W-p.S)/p.W)];
        end
        function sys = make_cassandra_sys()
            p = cassandra_params();
            sys.name='Cassandra'; sys.n=2; sys.C=[p.D_total;1.0];
            sys.w=@(t)[p.D_normal;0.3]; sys.delta=[1;p.repair_cpu_cost];
            p.timeout_fraction=0.3;
            sys.G=compute_gain_matrix(p);
            sys.r=@(t,h)[0;0];
        end
        function sys = make_oom_sys(g)
            p = oom_params(g);
            sys.name='OOM'; sys.n=1; sys.C=p.S;
            sys.w=@(t)p.n_procs*p.mem_per_proc;
            sys.delta=p.mem_freed;
            sys.G=compute_gain_matrix(struct('type','oom',...
                'alloc_on_restart',p.alloc_on_restart,'mem_freed',p.mem_freed));
            sys.r=@(t,h)0;
        end
    "
    echo ""

    # Phase 3: Symbolic derivations
    echo "--- Phase 3: Symbolic derivations ---"
    echo ""
    run_matlab "  TCP stability (G=-0.5, no h*)"     "derive_tcp_stability();"     || failed=1
    run_matlab "  Swap h* (E*/S = D'/(2f))"          "derive_swap_hstar();"        || failed=1
    run_matlab "  Perron-Frobenius monotonicity"      "derive_perron_frobenius();"  || failed=1
    echo ""

    # Phase 4: Swap parameter table
    echo "--- Phase 4: Swap h* table ---"
    echo ""
    run_matlab_verbose "
        fprintf('  %-20s  %-12s  %-18s  %-18s\n', 'Workload', 'f (pg/s)', 'HDD (D''=100)', 'NVMe (D''=50000)');
        fprintf('  %-20s  %-12s  %-18s  %-18s\n', '--------', '--------', '------------', '------------');
        workloads = {'web', 'database', 'analytics'};
        for i = 1:numel(workloads)
            p_hdd = swap_params(workloads{i}); p_hdd.D_spare = p_hdd.D_spare_hdd;
            p_nvme = swap_params(workloads{i}); p_nvme.D_spare = p_nvme.D_spare_nvme;
            [~, d_hdd] = find_hstar('swap', p_hdd);
            [~, d_nvme] = find_hstar('swap', p_nvme);
            hdd_str = sprintf('%.1f MB (%.3f%%)', d_hdd.h_star_MB, d_hdd.h_star_pct);
            if d_nvme.h_star_pct > 100
                nvme_str = 'no h*';
            else
                nvme_str = sprintf('%.1f MB (%.1f%%)', d_nvme.h_star_MB, d_nvme.h_star_pct);
            end
            fprintf('  %-20s  %-12d  %-18s  %-18s\n', p_hdd.workload_name, p_hdd.f, hdd_str, nvme_str);
        end
    "
    echo ""

    # Phase 5: Full verification
    echo "--- Phase 5: Verification (14 checks) ---"
    echo ""
    cmd_verify || failed=1
    echo ""

    local elapsed=$(( SECONDS - start_time ))
    echo "============================================================"
    if [[ $failed -eq 0 ]]; then
        echo " ALL ASSERTIONS VERIFIED  (${elapsed}s)"
    else
        echo " SOME ASSERTIONS FAILED   (${elapsed}s)"
    fi
    echo "============================================================"

    return $failed
}

# Parse arguments
case "${1:-}" in
    --clean)    cmd_clean ;;
    --verify)   cmd_verify ;;
    --symbolic) cmd_symbolic ;;
    --help|-h)
        echo "Usage: $0 [--verify|--symbolic|--clean|--help]"
        echo ""
        echo "  (no args)    Full proof run: build models, check invariants,"
        echo "               run symbolic derivations, verify all claims"
        echo "  --verify     Run 14 verification checks only"
        echo "  --symbolic   Run symbolic derivations only"
        echo "  --clean      Remove generated .slx files"
        ;;
    *)          cmd_full ;;
esac
