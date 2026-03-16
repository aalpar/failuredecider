function pass = verify_tcp_rho()
    % For a scalar, eig() returns the value itself. max(abs()) gives spectral radius.
    G = -0.5;
    rho = max(abs(eig(G)));
    pass = abs(rho - 0.5) < 1e-10 && rho < 1;
end
