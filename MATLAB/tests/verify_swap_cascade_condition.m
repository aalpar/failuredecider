function pass = verify_swap_cascade_condition()
% Verify cascade when alpha*beta >= (1-eps)^2.
    % Set alpha*beta = (1-eps)^2 = 0.9025 to test the exact cascade boundary (rho should be ~1.0).
    eps_ = 0.05;
    alpha = 0.5; beta = 0.9025 / 0.5;
    G = [eps_, beta; alpha, eps_];
    rho = max(abs(eig(G)));
    pass = abs(rho - 1.0) < 0.01;
end
