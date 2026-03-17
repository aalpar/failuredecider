function result = check_invariant(sys)
% CHECK_INVARIANT Evaluate recovery invariant levels 0-3 for a system.
%
%   result = check_invariant(sys) where sys is a struct with fields:
%     .name   - string identifier
%     .n      - number of resources (integer)
%     .C      - [n x 1] capacity vector
%     .w      - function handle w(t) -> [n x 1] workload bandwidth
%     .r      - function handle r(t, h) -> [n x 1] recovery bandwidth
%     .delta  - [n x 1] cost of single recovery action
%     .G      - [n x n] gain matrix, or function handle G(h) -> [n x n]
%
%   Returns struct with fields:
%     .level0      - logical: resource model valid
%     .level1      - logical: individual cost bounded
%     .level2      - logical: h(t) >= 0 at all simulated timesteps
%     .level3      - logical: spectral radius of G < 1
%     .rho         - spectral radius of G (at initial operating point)
%     .h_min       - minimum headroom observed during simulation
%     .h_timeseries - [T x n] headroom over time
%     .details     - struct with per-level diagnostic info

    result = struct();

    %% Level 0: Resource model exists and is dimensionally consistent
    % Cell array of required field names. Cell arrays use {} and hold items of different types/sizes.
    required = {'name', 'n', 'C', 'w', 'r', 'delta', 'G'};
    % setdiff returns elements in 'required' that are NOT in fieldnames(sys). fieldnames() returns all struct field names as a cell array.
    missing = setdiff(required, fieldnames(sys));
    if ~isempty(missing)
        result.level0 = false;
        result.details.level0_msg = sprintf('Missing fields: %s', strjoin(missing, ', '));
        result.level1 = false; result.level2 = false; result.level3 = false;
        result.rho = NaN; result.h_min = NaN; result.h_timeseries = [];
        return;
    end

    n = sys.n;
    % numel() returns total number of elements. For vectors, this is the length.
    dim_ok = (numel(sys.C) == n) && (numel(sys.delta) == n);
    % Check w and r return correct dimensions
    % try/catch prevents crashes if w() has wrong signature. MATLAB's try/catch is like other languages'.
    try
        w0 = sys.w(0);
        dim_ok = dim_ok && (numel(w0) == n);
    catch
        dim_ok = false;
    end

    % isa() checks type. 'function_handle' means sys.G is an anonymous function (@(...) ...) rather than a plain matrix.
    if isa(sys.G, 'function_handle')
        try
            G0 = sys.G(sys.C - sys.w(0));
            dim_ok = dim_ok && all(size(G0) == [n, n]);
        catch
            dim_ok = false;
        end
    else
        dim_ok = dim_ok && all(size(sys.G) == [n, n]);
    end

    result.level0 = dim_ok;
    result.details.level0_msg = conditional(dim_ok, 'OK', 'Dimension mismatch');

    %% Level 1: Individual cost bounded and known
    % all() returns true if every element is true. isfinite() checks for non-Inf, non-NaN values.
    result.level1 = all(isfinite(sys.delta)) && all(sys.delta > 0) && all(sys.delta < sys.C);
    result.details.level1_delta = sys.delta;

    %% Level 3: Feedback bound (rho(G) < 1) — compute before Level 2 since it's cheaper
    % Evaluate gain matrix at the initial operating point to get spectral radius
    if isa(sys.G, 'function_handle')
        h0 = sys.C(:) - sys.w(0);
        G_eval = sys.G(h0);
    else
        G_eval = sys.G;
    end
    % [V, D] = eig(G) returns eigenvectors as columns of V and eigenvalues on the diagonal of D.
    % The column V(:,k) is the eigenvector for eigenvalue D(k,k).
    [V, D] = eig(G_eval);
    eigenvalues = diag(D);
    % Spectral radius = largest absolute eigenvalue. If rho < 1, perturbations decay (stable). If rho >= 1, perturbations amplify (cascade).
    [result.rho, dom_idx] = max(abs(eigenvalues));
    result.level3 = result.rho < 1;
    result.details.level3_G = G_eval;
    result.details.level3_eigenvalues = eigenvalues;
    % Dominant eigenvector: the cascade shape — relative resource contribution to the dangerous mode.
    % Normalized to unit sum so entries read as proportions (e.g. [0.73, 0.27] = "73% disk, 27% memory").
    dom_evec = abs(V(:, dom_idx));
    result.details.level3_dominant_eigenvector = dom_evec / sum(dom_evec);

    %% Level 2: Aggregate bound — simulate and check h(t) >= 0
    % Simulate the system forward in time to check if headroom h(t) stays non-negative
    dt = 0.01;
    T = 100;
    t_vec = 0:dt:T;
    N = numel(t_vec);
    h_ts = zeros(N, n);

    % (:) forces column vector shape. This ensures dimensions match even if C or w are row vectors.
    h = sys.C(:) - sys.w(0);
    % Main simulation loop: at each timestep, compute workload, recovery, and resulting headroom
    for k = 1:N
        t = t_vec(k);
        w_t = sys.w(t);
        r_t = sys.r(t, h);
        h = sys.C(:) - w_t(:) - r_t(:);
        h_ts(k, :) = h(:)';
    end

    result.h_timeseries = h_ts;
    result.h_min = min(h_ts(:));
    result.level2 = result.h_min >= 0;
    result.details.level2_h_min = result.h_min;
end

% Local helper function. In MATLAB, functions defined after the main function in the same file are 'local functions' — only visible within this file.
function s = conditional(cond, a, b)
    if cond, s = a; else, s = b; end
end
