function run_all()
% RUN_ALL Reproduce all formal claims from the article.
%
%   Builds Simulink models, runs simulations, checks invariant levels,
%   runs symbolic derivations, and prints the summary table.

    fprintf('============================================================\n');
    fprintf(' Recovery Invariant Executable Model\n');
    fprintf(' Source: dont-let-your-system-decide-its-dead.md\n');
    fprintf('============================================================\n\n');

    % addpath() adds directories to MATLAB's search path so functions in those folders can be called by name.
    addpath('models', 'analysis', 'symbolic', 'tests');

    %% 1. Build Simulink models
    fprintf('--- Building Simulink models ---\n');
    build_tcp_model();
    build_swap_model();
    build_cassandra_model();
    build_oom_model();
    fprintf('\n');

    %% 2. Check invariant on each system
    fprintf('--- Invariant checks ---\n\n');

    % TCP
    tcp_sys = make_tcp_sys();
    tcp_result = check_invariant(tcp_sys);
    print_result('TCP', tcp_result);

    % Swap (HDD, Database workload)
    swap_sys = make_swap_sys('database', 'hdd');
    swap_result = check_invariant(swap_sys);
    print_result('Swap (HDD, DB)', swap_result);

    % Cassandra
    cass_sys = make_cassandra_sys();
    cass_result = check_invariant(cass_sys);
    print_result('Cassandra', cass_result);

    % OOM (G=1.2)
    oom_sys = make_oom_sys(1.2);
    oom_result = check_invariant(oom_sys);
    print_result('OOM (G=1.2)', oom_result);

    %% 3. Symbolic derivations
    fprintf('\n--- Symbolic derivations ---\n');
    derive_tcp_stability();
    derive_swap_hstar();
    derive_perron_frobenius();

    %% 4. Parameter sweep: swap h* table
    fprintf('\n--- Swap h* table (article verification) ---\n');
    fprintf('%-15s  %-12s  %-18s  %-18s\n', 'Workload', 'f (pg/s)', 'HDD (D''=100)', 'NVMe (D''=50000)');
    fprintf('%-15s  %-12s  %-18s  %-18s\n', '--------', '--------', '------------', '------------');

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
        fprintf('%-15s  %-12d  %-18s  %-18s\n', p_hdd.workload_name, p_hdd.f, hdd_str, nvme_str);
    end

    %% 5. Summary table
    fprintf('\n--- Summary (Article Table) ---\n\n');
    fprintf('%-16s | %-18s | %-14s | %-13s | %-12s\n', ...
        'System', 'L0 Resource Model', 'L1 Individual', 'L2 Aggregate', 'L3 Feedback');
    fprintf('%-16s-|%-19s-|%-15s-|%-14s-|%-13s\n', ...
        '----------------', '------------------', '--------------', '-------------', '------------');

    print_table_row('TCP', tcp_result, 'segs on link', '1 segment');
    print_table_row('Swap (HDD,DB)', swap_result, 'pages + IOPS', '1 page, 2 IO');
    print_table_row('Cassandra', cass_result, '~ partial', '1 write');
    print_table_row('OOM (G=1.2)', oom_result, 'alloc unknown', '1 kill');

    %% 6. Run full verification suite
    fprintf('\n--- Full verification ---\n');
    verify_all();

    fprintf('\n============================================================\n');
    fprintf(' Done.\n');
    fprintf('============================================================\n');
end

%% Helper: construct system structs for check_invariant

% Local function: builds a 'sys' struct that check_invariant() expects. Each system needs: name, n (resource count), C (capacity), w (workload function), r (recovery function), delta (single action cost), G (gain matrix).
function sys = make_tcp_sys()
    p = tcp_params();
    sys.name  = 'TCP';
    sys.n     = 1;
    sys.C     = p.C;
    % @(t) p.w0 is an anonymous function: takes t as input, always returns p.w0. Anonymous functions are MATLAB's lambdas.
    sys.w     = @(t) p.w0;
    sys.delta = 1;  % one segment
    sys.G     = -0.5;

    % Recovery with backoff
    % Closure: captures 'p' from the enclosing scope. When check_invariant calls sys.r(t, h), it passes t and h, and p comes from here.
    sys.r = @(t, h) tcp_recovery(t, h, p);
end

% Local function implementing TCP exponential backoff recovery logic.
function r = tcp_recovery(~, h, p)
    % 'persistent' variables keep their value between function calls (like C's static). First call: k is empty, so we initialize to 0.
    persistent k
    if isempty(k), k = 0; end
    if h < 0 && k < p.max_retries
        k = k + 1;
    elseif h > 10
        k = max(0, k - 1);
    end
    if k > 0
        r = 1 / (p.RTO_base * 2^k);
    else
        r = 0;
    end
end

% Builds a 2-resource system struct for swap analysis (memory + disk).
function sys = make_swap_sys(workload, disk_type)
    p = swap_params(workload);
    sys.name = sprintf('Swap (%s, %s)', upper(disk_type), workload);
    sys.n    = 2;  % memory, disk

    % strcmp() compares strings in MATLAB. The == operator doesn't work for string comparison in older MATLAB.
    if strcmp(disk_type, 'hdd')
        D_spare = p.D_spare_hdd;
        D_total = p.D_total_hdd;
    else
        D_spare = p.D_spare_nvme;
        D_total = p.D_total_nvme;
    end

    sys.C     = [p.S; D_total];
    sys.w     = @(t) [p.W - max(0, p.W - p.S); p.D_normal_hdd];
    sys.delta = [1; 2];  % one page freed, 2 IOPS consumed
    % struct('field1', val1, 'field2', val2, ...) creates a struct inline — useful for passing named parameters.
    sys.G     = compute_gain_matrix(struct('type', 'swap', ...
        'f', p.f, 'W', p.W, 'epsilon', p.epsilon, ...
        'buf_per_blocked', p.buf_per_blocked, ...
        'block_rate_per_iops', p.block_rate_per_iops));

    % [0; min(...)] creates a 2x1 column vector. Semicolons separate rows in MATLAB arrays.
    sys.r = @(t, h) [0; min(D_spare, 2 * p.f * max(0, p.W - p.S) / p.W)];
end

function sys = make_cassandra_sys()
    p = cassandra_params();
    sys.name  = 'Cassandra';
    sys.n     = 2;  % disk, cpu
    sys.C     = [p.D_total; 1.0];  % IOPS, CPU fraction
    sys.w     = @(t) [p.D_normal; 0.3];
    sys.delta = [1; p.repair_cpu_cost];
    p.timeout_fraction = 0.3;  % worst-case during replay
    sys.G     = compute_gain_matrix(p);
    sys.r     = @(t, h) cassandra_recovery(t, h, p);
end

% Recovery is zero during outage, then ramps up after T_outage seconds.
function r = cassandra_recovery(t, ~, p)
    if t < p.T_outage
        r = [0; 0];
    else
        r = [p.replay_throttle; 0.05];
    end
end

function sys = make_oom_sys(gain)
    p = oom_params(gain);
    sys.name  = sprintf('OOM (G=%.1f)', gain);
    sys.n     = 1;
    sys.C     = p.S;
    sys.w     = @(t) p.n_procs * p.mem_per_proc;
    sys.delta = p.mem_freed;
    sys.G     = compute_gain_matrix(struct('type', 'oom', ...
        'alloc_on_restart', p.alloc_on_restart, 'mem_freed', p.mem_freed));
    sys.r     = @(t, h) 0;  % simplified — the Simulink model has full dynamics
end

%% Helper: print functions

% Helper to display invariant check results. fprintf works like C's printf.
function print_result(name, result)
    fprintf('  %s:\n', name);
    fprintf('    Level 0 (Resource model): %s\n', tf(result.level0));
    fprintf('    Level 1 (Individual):     %s\n', tf(result.level1));
    fprintf('    Level 2 (Aggregate):      %s  (h_min = %.2f)\n', tf(result.level2), result.h_min);
    fprintf('    Level 3 (Feedback):       %s  (rho = %.4f)\n', tf(result.level3), result.rho);
    fprintf('\n');
end

function print_table_row(name, result, l0_detail, l1_detail)
    l0_str = sprintf('%s %s', mark(result.level0), l0_detail);
    l1_str = sprintf('%s %s', mark(result.level1), l1_detail);
    if result.level2
        l2_str = sprintf('%s OK', mark(true));
    else
        l2_str = sprintf('%s h<0', mark(false));
    end
    l3_str = sprintf('%s rho=%.2f', mark(result.level3), result.rho);
    fprintf('%-16s | %-18s | %-14s | %-13s | %-12s\n', name, l0_str, l1_str, l2_str, l3_str);
end

% Ternary-like helper: MATLAB lacks a ternary operator (?:), so this one-liner substitutes.
function s = tf(b)
    if b, s = 'PASS'; else, s = 'FAIL'; end
end

% char() converts Unicode code points to characters. 10003 = checkmark, 10007 = X mark.
function s = mark(b)
    if b, s = char(10003); else, s = char(10007); end  % checkmark / x
end
