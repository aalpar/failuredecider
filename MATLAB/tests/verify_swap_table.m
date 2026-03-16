function pass = verify_swap_table()
% Verify article table values for swap h*.
    % Verify the article's table of h* values: E* = D'*S/(2f), converted to MB via *4/1024 (4KB pages).
    S = 16e6;

    f = 100000; D_prime = 100;
    E_star = D_prime * S / (2 * f);
    E_star_MB = E_star * 4 / 1024;
    pass = abs(E_star_MB - 31.25) < 1;

    f = 10000; D_prime = 100;
    E_star = D_prime * S / (2 * f);
    E_star_MB = E_star * 4 / 1024;
    pass = pass && abs(E_star_MB - 312.5) < 10;

    f = 1000000; D_prime = 100;
    E_star = D_prime * S / (2 * f);
    E_star_MB = E_star * 4 / 1024;
    pass = pass && abs(E_star_MB - 3.125) < 0.5;
end
