function pass = verify_perron_frobenius()
% Verify numerically: for 100 random non-negative 2x2 matrices,
% increasing any entry does not decrease rho.
    % rng(42) seeds the random number generator for reproducibility. rand(2) creates a 2x2 matrix of random values in [0,1).
    rng(42);
    pass = true;
    for trial = 1:100
        G = rand(2) * 2;
        rho_base = max(abs(eig(G)));
        for i = 1:2
            for j = 1:2
                G2 = G;
                G2(i,j) = G2(i,j) + 0.1;
                rho_new = max(abs(eig(G2)));
                if rho_new < rho_base - 1e-10
                    pass = false;
                    return;
                end
            end
        end
    end
end
