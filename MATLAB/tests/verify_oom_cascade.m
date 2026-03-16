function pass = verify_oom_cascade()
% G >= 1: restarted process allocates as much or more than killed freed.
    % G=1.2: restarted process uses 120% of what was freed. Each kill makes things worse — rho >= 1.
    p = oom_params(1.2);
    G = compute_gain_matrix(struct('type', 'oom', ...
        'alloc_on_restart', p.alloc_on_restart, 'mem_freed', p.mem_freed));
    rho = max(abs(eig(G)));
    pass = rho >= 1;
end
