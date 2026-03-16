function pass = verify_tcp_gain()
    % Build a params struct inline to pass to compute_gain_matrix. Tests the article's claim that TCP's gain = -0.5.
    params = tcp_params();
    G = compute_gain_matrix(struct('type', 'tcp', 'RTO_base', params.RTO_base));
    pass = abs(G - (-0.5)) < 1e-10;
end
