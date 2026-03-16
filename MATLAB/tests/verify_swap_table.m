function pass = verify_swap_table()
% Verify article table values for swap h*.
    % Verify the article's table of h* values: E* = D'*S/(2f), converted to MB via *4/1000 (4KB pages, SI MB).
    S = 16e6;

    f = 100000; D_prime = 100;
    E_star = D_prime * S / (2 * f);
    E_star_MB = E_star * 4 / 1000;
    pass = abs(E_star_MB - 32) < 1;

    f = 10000; D_prime = 100;
    E_star = D_prime * S / (2 * f);
    E_star_MB = E_star * 4 / 1000;
    pass = pass && abs(E_star_MB - 320) < 10;

    f = 1000000; D_prime = 100;
    E_star = D_prime * S / (2 * f);
    E_star_MB = E_star * 4 / 1000;
    pass = pass && abs(E_star_MB - 3.2) < 0.5;
end
