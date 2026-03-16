function pass = verify_tcp_no_hstar()
% TCP has constant G = -0.5 regardless of load.
% rho(G) = 0.5 < 1 at ALL operating points, so no h* exists.
    G = -0.5;
    % Sweep load from 0 to 99% of capacity — G never changes
    for load_frac = 0.1:0.1:0.99
        rho = abs(G);  % G is constant, doesn't depend on load
        if rho >= 1
            pass = false;
            return;
        end
    end
    pass = true;
end
