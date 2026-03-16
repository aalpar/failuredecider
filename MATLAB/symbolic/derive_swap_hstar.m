function results = derive_swap_hstar()
% DERIVE_SWAP_HSTAR Symbolic derivation of swap thrashing stability boundary.
%
%   Derives:
%     1. Eigenvalues of G = [eps, beta; alpha, eps]
%     2. Spectral radius rho(G) = eps + sqrt(alpha*beta)
%     3. Cascade condition: alpha*beta >= (1-eps)^2
%     4. Critical excess: E* = D'*W/(2f)
%     5. Swap margin ratio: E*/S = D'/(2f) when W ~ S
%     6. Numerical verification against article table

    fprintf('\n=== Swap h* — Symbolic Derivation ===\n\n');

    % 'positive' assumption tells the symbolic engine these variables are > 0, enabling simplifications that require it.
    syms alpha_ beta_ eps_ positive
    syms f_sym W_sym D_prime S_sym E_sym real positive

    %% 1. Eigenvalues
    % Symbolic matrix — eig() will compute eigenvalues as symbolic expressions, not numbers.
    G = [eps_, beta_; alpha_, eps_];
    % eig() on a symbolic matrix returns eigenvalues as symbolic expressions (exact, not floating-point).
    eigenvalues = eig(G);
    eigenvalues = simplify(eigenvalues);
    fprintf('1. G = [eps, beta; alpha, eps]\n');
    fprintf('   Eigenvalues: %s, %s\n', char(eigenvalues(1)), char(eigenvalues(2)));
    results.eigenvalues = eigenvalues;

    %% 2. Spectral radius (for eps, alpha, beta >= 0)
    rho = eps_ + sqrt(alpha_ * beta_);
    fprintf('\n2. rho(G) = %s\n', char(rho));
    results.rho_expr = rho;

    %% 3. Cascade condition: solve rho = 1
    % Substitute ab = alpha_*beta_, solve for ab
    % Introduce a single variable for the product alpha*beta to solve the cascade condition more cleanly.
    syms ab positive
    rho_ab = eps_ + sqrt(ab);
    % solve() finds values of 'ab' that make the equation true. Returns symbolic expression: ab = (1-eps)^2.
    cascade_cond = solve(rho_ab == 1, ab);
    fprintf('\n3. Cascade when alpha*beta >= %s\n', char(cascade_cond));
    results.cascade_condition = cascade_cond;

    %% 4. Critical excess
    % solve() for E_sym: rearranges the disk saturation equation to get E* = D'*W/(2f).
    E_star = solve(2*f_sym * E_sym / W_sym == D_prime, E_sym);
    fprintf('\n4. Disk saturation at E* = %s\n', char(E_star));
    results.E_star = E_star;

    %% 5. Swap margin ratio (W ~ S)
    % subs() substitutes one symbolic variable for another. Here: replace W with S (since W ~ S), then divide by S to get the margin ratio.
    margin = simplify(subs(E_star, W_sym, S_sym) / S_sym);
    fprintf('\n5. E*/S = %s  (when W ~ S)\n', char(margin));
    results.margin_expr = margin;

    %% 6. Numerical verification against article table
    fprintf('\n6. Article table verification:\n');
    fprintf('   %-15s  %-12s  %-18s  %-18s\n', 'Workload', 'f (pg/s)', 'HDD (D''=100)', 'NVMe (D''=50000)');
    fprintf('   %-15s  %-12s  %-18s  %-18s\n', '--------', '--------', '------------', '------------');

    % 16 million pages * 4KB/page = 64GB physical memory. 16e6 is MATLAB's scientific notation for 16000000.
    S_val = 16e6;
    workloads = {'Light web', 10000; 'Database', 100000; 'Analytics', 1000000};
    D_primes = [100, 50000];

    % Pre-allocate an empty struct array. The {} syntax creates an empty cell — this defines the field names without any entries yet.
    results.table = struct('workload', {}, 'f', {}, 'hdd_MB', {}, 'nvme_MB', {}, ...
                           'hdd_pct', {}, 'nvme_pct', {});

    for i = 1:size(workloads, 1)
        wl_name = workloads{i, 1};
        f_val = workloads{i, 2};

        for j = 1:2
            D_val = D_primes(j);
            E_star_val = D_val * S_val / (2 * f_val);
            E_star_MB = E_star_val * 4 / 1024;
            E_star_pct = E_star_val / S_val * 100;

            if j == 1
                results.table(i).workload = wl_name;
                results.table(i).f = f_val;
                results.table(i).hdd_MB = E_star_MB;
                results.table(i).hdd_pct = E_star_pct;
            else
                results.table(i).nvme_MB = E_star_MB;
                results.table(i).nvme_pct = E_star_pct;
            end
        end

        hdd_str = sprintf('%.1f MB (%.3f%%)', results.table(i).hdd_MB, results.table(i).hdd_pct);
        if results.table(i).nvme_pct > 100
            nvme_str = 'no h*';
        else
            nvme_str = sprintf('%.1f MB (%.1f%%)', results.table(i).nvme_MB, results.table(i).nvme_pct);
        end
        fprintf('   %-15s  %-12d  %-18s  %-18s\n', wl_name, f_val, hdd_str, nvme_str);
    end

    fprintf('\n=== Derivation complete. ===\n');
end
