function results = verify_all()
% VERIFY_ALL Run all verification checks against article claims.
% Returns a struct array with test name, pass/fail, and message.

    % Initialize an empty struct array with defined field names. {} creates empty cells — the array starts with zero entries.
    results = struct('name', {}, 'pass', {}, 'msg', {});

    fprintf('\n=== Recovery Invariant Model — Verification ===\n\n');

    % Each call appends one entry to the results struct array. Struct arrays let you do results(1).name, results(2).name, etc.
    % Analysis layer
    results = run_check(results, 'check_invariant exists', ...
        @() exist('check_invariant', 'file') == 2);

    results = run_check(results, 'compute_gain_matrix exists', ...
        @() exist('compute_gain_matrix', 'file') == 2);

    % TCP claims
    results = run_check(results, 'TCP: G = -0.5', ...
        @() verify_tcp_gain());

    results = run_check(results, 'TCP: rho(G) = 0.5 < 1', ...
        @() verify_tcp_rho());

    results = run_check(results, 'TCP: unconditionally stable (no h*)', ...
        @() verify_tcp_no_hstar());

    results = run_check(results, 'TCP: (I-G)^-1 = 2/3', ...
        @() verify_tcp_series());

    % Swap claims
    results = run_check(results, 'Swap: E*/S = Dprime/(2f) for W~=S', ...
        @() verify_swap_hstar_formula());

    results = run_check(results, 'Swap: cascade when alpha*beta >= 1', ...
        @() verify_swap_cascade_condition());

    results = run_check(results, 'Swap: article table values match', ...
        @() verify_swap_table());

    % Perron-Frobenius
    results = run_check(results, 'PF: rho non-decreasing in entries for G>=0', ...
        @() verify_perron_frobenius());

    % Cassandra claims
    results = run_check(results, 'Cassandra: Level 2 violated (burst)', ...
        @() verify_cassandra_level2());

    results = run_check(results, 'Cassandra: Level 3 violated (feedback)', ...
        @() verify_cassandra_level3());

    % OOM claims
    results = run_check(results, 'OOM: stable when G < 1', ...
        @() verify_oom_stable());

    results = run_check(results, 'OOM: cascade when G >= 1', ...
        @() verify_oom_cascade());

    % Summary
    % [results.pass] extracts the 'pass' field from every struct in the array into a regular array. sum() counts trues.
    n_pass = sum([results.pass]);
    n_total = numel(results);
    fprintf('\n=== %d / %d checks passed ===\n', n_pass, n_total);
end

% Test runner helper. fn is a function handle — fn() calls it. try/catch handles any errors gracefully.
function results = run_check(results, name, fn)
    try
        % Call the test function. fn is a function handle passed as @() verify_tcp_gain() — the @() wraps it for deferred execution.
        pass = fn();
        if pass
            fprintf('  PASS  %s\n', name);
        else
            fprintf('  FAIL  %s\n', name);
        end
        results(end+1) = struct('name', name, 'pass', pass, 'msg', '');
    catch e
        fprintf('  ERROR %s: %s\n', name, e.message);
        results(end+1) = struct('name', name, 'pass', false, 'msg', e.message);
    end
end
