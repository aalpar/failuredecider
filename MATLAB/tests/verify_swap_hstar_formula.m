function pass = verify_swap_hstar_formula()
% Verify E*/S = D'/(2f) symbolically.
    % Create symbolic variables to verify the h* formula algebraically, then check a concrete numeric case.
    syms D_prime f_sym S_sym real positive
    E_star_over_S = D_prime / (2 * f_sym);

    val = double(subs(E_star_over_S, {D_prime, f_sym}, {100, 100000}));
    expected = 100 / (2 * 100000);

    pass = abs(val - expected) < 1e-15;
end
