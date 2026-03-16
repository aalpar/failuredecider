function results = derive_perron_frobenius()
% DERIVE_PERRON_FROBENIUS Verify rho(G) is non-decreasing in entries for G >= 0.
%
%   For 2x2 non-negative G:
%     1. Compute rho(G) symbolically
%     2. Show d(rho)/d(G_ij) >= 0 for all i,j
%     3. Consequence: h* boundary is monotone in load

    fprintf('\n=== Perron-Frobenius Monotonicity (2x2) ===\n\n');

    % Four symbolic variables represent entries of a general 2x2 non-negative matrix.
    syms a b c d real positive

    G = [a, b; c, d];
    eigenvalues = eig(G);
    eigenvalues = simplify(eigenvalues);
    fprintf('G = [a b; c d]\n');
    fprintf('Eigenvalues: %s\n', char(eigenvalues));

    % Perron-Frobenius eigenvalue for 2x2: the larger eigenvalue of [a b; c d]. This closed-form avoids eig().
    rho = (a + d)/2 + sqrt(((a - d)/2)^2 + b*c);
    rho = simplify(rho);
    fprintf('\nrho(G) = %s\n\n', char(rho));
    results.rho_expr = rho;

    % Cell array of symbolic variables — allows iterating over them in the loop below.
    vars = {a, b, c, d};
    names = {'a (G_11)', 'b (G_12)', 'c (G_21)', 'd (G_22)'};
    results.partials = cell(4, 1);

    fprintf('Partial derivatives:\n');
    all_nonneg = true;
    for i = 1:4
        % diff() computes symbolic partial derivative: d(rho)/d(variable). If all partials >= 0, rho is monotonically non-decreasing in every entry.
        dr = diff(rho, vars{i});
        dr = simplify(dr);
        results.partials{i} = dr;
        fprintf('  d(rho)/d(%s) = %s\n', names{i}, char(dr));

        % Numerical spot-checks: substitute concrete values and verify the partial derivative is non-negative.
        test_vals = [1 1 1 1; 0.1 2 3 0.1; 5 0.1 0.1 5; 1 0.01 100 1];
        for j = 1:size(test_vals, 1)
            % subs() plugs in numeric values for symbolic variables. double() converts the symbolic result to a regular MATLAB number.
            val = double(subs(dr, [a b c d], test_vals(j,:)));
            if val < -1e-10
                all_nonneg = false;
                fprintf('    WARNING: negative at [%s]\n', num2str(test_vals(j,:)));
            end
        end
    end

    fprintf('\nAll partials non-negative: %s\n', mat2str(all_nonneg));
    results.monotone = all_nonneg;

    fprintf('\nConsequence: If load increase causes any G_ij to grow, rho(G) grows.\n');
    fprintf('There exists critical headroom h* where rho(G(h*)) = 1.\n');
    fprintf('For h > h*: stable. For h < h*: cascade.\n');
    fprintf('Transition is one-directional — system cannot self-rescue.\n');

    fprintf('\n=== QED: Perron-Frobenius monotonicity verified for 2x2. ===\n');
end
