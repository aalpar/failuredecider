function [h_star, details] = find_hstar(sys_type, params)
% FIND_HSTAR Find critical headroom h* where rho(G) = 1.
%
%   [h_star, details] = find_hstar(sys_type, params)
%
%   For 'tcp': returns Inf (no h* — unconditionally stable)
%   For 'swap': returns E* in pages (closed-form)
%   For 'oom': returns critical G = 1 boundary (alloc = freed)

    % struct() creates an empty struct. Fields are added dynamically via dot notation below.
    details = struct();

    switch sys_type
        case 'tcp'
            h_star = Inf;
            details.msg = 'No h* exists — TCP is unconditionally stable';
            details.rho_constant = 0.5;

        case 'swap'
            D_prime = params.D_spare;
            f = params.f;
            W = params.W;
            S = params.S;

            h_star = D_prime * W / (2 * f);
            details.h_star_pages = h_star;
            details.h_star_MB = h_star * 4 / 1000;
            details.h_star_pct = h_star / S * 100;
            details.msg = sprintf('E* = %.1f MB (%.4f%% of physical memory)', ...
                details.h_star_MB, details.h_star_pct);

            % syms creates symbolic variables for algebra (requires Symbolic Math Toolbox). 'real positive' constrains them for simplification.
            syms D_p f_s W_s real positive
            details.symbolic = D_p * W_s / (2 * f_s);

        case 'oom'
            h_star = params.mem_freed;
            details.msg = sprintf('Cascade when alloc_on_restart >= %d pages (%.1f MB)', ...
                h_star, h_star * 4 / 1000);

        case 'cassandra'
            % linspace(a, b, n) creates n evenly-spaced points between a and b. Used here to sweep replay rates.
            throttles = linspace(1, params.D_total, 1000);
            rho_vals = zeros(size(throttles));
            for i = 1:numel(throttles)
                p = params;
                p.timeout_fraction = estimate_timeout_fraction(p, throttles(i));
                G = compute_gain_matrix(p);
                rho_vals(i) = max(abs(eig(G)));
            end
            % find(..., 1, 'first') returns the index of the first element matching the condition. Empty if none match.
            idx = find(rho_vals >= 1, 1, 'first');
            if isempty(idx)
                h_star = Inf;
                details.msg = 'No h* found — stable at all replay rates';
            else
                h_star = throttles(idx);
                details.msg = sprintf('Cascade at replay_throttle >= %.0f ops/sec', h_star);
            end
            details.throttles = throttles;
            details.rho_vals = rho_vals;

        otherwise
            error('find_hstar:unknownType', 'Unknown type: %s', sys_type);
    end
end

% Local function: estimates what fraction of reads timeout given a replay rate. Uses M/M/1 queueing model: latency = base / (1 - utilization).
function tf = estimate_timeout_fraction(params, replay_rate)
    total_iops = params.D_normal + replay_rate;
    util = min(total_iops / params.D_total, 0.999);
    latency = params.base_latency / (1 - util);
    tf = min(1, max(0, (latency - params.read_timeout) / latency));
end
