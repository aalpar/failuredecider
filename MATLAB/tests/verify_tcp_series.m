function pass = verify_tcp_series()
% Article claim: (I - G)^-1 = 2/3 for TCP.
    % inv() computes matrix inverse. For scalars, inv(x) = 1/x. Tests that (I-G)^{-1} = 2/3.
    G = -0.5;
    series_sum = inv(1 - G);  % = 1/1.5 = 2/3
    pass = abs(series_sum - 2/3) < 1e-10;
end
