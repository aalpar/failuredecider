function pass = test_compute_gain_matrix()
% Test gain matrix computation for known systems.

    % TCP: scalar G = -0.5
    % struct() with field-value pairs creates a struct inline. Equivalent to: tcp.type = 'tcp'; tcp.RTO_base = 1;
    tcp = struct('type', 'tcp', 'RTO_base', 1);
    G_tcp = compute_gain_matrix(tcp);
    % assert() throws an error if the condition is false. The second arg is the error message. Good for tests.
    assert(isscalar(G_tcp) && abs(G_tcp - (-0.5)) < 1e-10, 'TCP gain wrong');

    % Swap: 2x2, check structure
    swap = struct('type', 'swap', 'f', 100000, 'W', 16e6, ...
                  'epsilon', 0.05, 'buf_per_blocked', 4, 'block_rate_per_iops', 0.001);
    G_swap = compute_gain_matrix(swap);
    assert(all(size(G_swap) == [2 2]), 'Swap gain matrix wrong size');
    assert(G_swap(2,1) > 0, 'alpha should be positive');  % memory -> disk

    % OOM: scalar G = alloc/freed
    oom = struct('type', 'oom', 'alloc_on_restart', 500000, 'mem_freed', 400000);
    G_oom = compute_gain_matrix(oom);
    assert(abs(G_oom - 1.25) < 1e-10, 'OOM gain wrong');

    pass = true;
end
