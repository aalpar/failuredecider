function pass = verify_cassandra_level3()
% Verify: read repair feedback gain >> 1 above critical utilization.
%   Tests the phase transition: gain = 0 below u*, gain >> 1 above u*.
%   Also verifies the closed-form h* matches the numerical sweep.
    p = cassandra_params();
    p.type = 'cassandra';

    % Below threshold: replay at default throttle (128 ops/sec).
    % D_normal + replay = 200 + 128 = 328 IOPS, u = 0.656 < u* = 0.99.
    p.replay_rate = p.replay_throttle;
    G_below = compute_gain_matrix(p);
    gain_below = abs(G_below);

    % Above threshold: replay at 300 ops/sec.
    % D_normal + replay = 200 + 300 = 500 IOPS, u = 1.0 > u* = 0.99.
    p.replay_rate = 300;
    G_above = compute_gain_matrix(p);
    gain_above = abs(G_above);

    % Verify phase transition: gain jumps from 0 to >> 1
    below_is_stable = gain_below == 0;
    above_is_cascade = gain_above > 1;

    % Verify closed-form h* = D_t * b / tau
    [h_star, details] = find_hstar('cassandra', p);
    h_star_expected = p.D_total * p.base_latency / p.read_timeout;
    hstar_matches = abs(h_star - h_star_expected) < 0.01;

    % Verify safe replay rate R* = D_t * (1 - b/tau) - D_normal
    R_star_expected = p.D_total * (1 - p.base_latency / p.read_timeout) - p.D_normal;
    rstar_matches = abs(details.R_star - R_star_expected) < 0.01;

    pass = below_is_stable && above_is_cascade && hstar_matches && rstar_matches;
end
