function pass = verify_oom_stable()
% G < 1: restarted process allocates less than killed process freed.
    % G=0.8: restarted process only uses 80% of what was freed. System recovers — rho < 1.
    p = oom_params(0.8);
    G = compute_gain_matrix(struct('type', 'oom', ...
        'alloc_on_restart', p.alloc_on_restart, 'mem_freed', p.mem_freed));
    rho = max(abs(eig(G)));
    pass = rho < 1;
end
