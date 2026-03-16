function pass = verify_cassandra_level3()
% Verify: read repair feedback loop has rho(G) > 1 under load.
    % Tests that the read-repair feedback loop produces rho(G) > 1 under realistic timeout conditions.
    p = cassandra_params();
    p.timeout_fraction = 0.3;
    p.type = 'cassandra';
    G = compute_gain_matrix(p);
    rho = max(abs(eig(G)));
    pass = rho > 1;
end
