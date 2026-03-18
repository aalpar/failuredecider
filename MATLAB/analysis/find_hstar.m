function [h_star, details] = find_hstar(sys_type, params)
% FIND_HSTAR Find critical headroom h* where rho(G) = 1.
%
%   [h_star, details] = find_hstar(sys_type, params)
%
%   For 'tcp':       returns Inf (no h* — unconditionally stable)
%   For 'swap':      returns E* in pages (closed-form: D'W/2f)
%   For 'cassandra': returns h* in IOPS (closed-form: D_t * b / tau)
%   For 'oom':       returns critical G = 1 boundary (alloc = freed)

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
            % Closed-form h* from M/M/1 latency model.
            %
            % Timeouts begin when disk utilization u > u* = 1 - b/tau.
            % At that point, the read repair feedback gain jumps from 0
            % to g = c_r * r_r * tau / (b * D_t), which is >> 1 for
            % typical parameters (phase transition, not smooth crossing).
            %
            % h* is the headroom (IOPS) at which u = u*:
            %   h* = D_t * b / tau
            %
            % The safe replay rate (IOPS available for replay before
            % crossing u*):
            %   R* = D_t * (1 - b/tau) - D_normal
            %
            % See derive_cassandra_hstar.m for full symbolic derivation.

            b   = params.base_latency;
            tau = params.read_timeout;
            D_t = params.D_total;
            D_n = params.D_normal;
            c_r = params.repair_cost;
            r_r = params.read_rate;

            % Critical utilization and headroom
            u_star = 1 - b / tau;
            h_star = D_t * b / tau;

            % Safe replay rate
            R_star = D_t * u_star - D_n;

            % Gain above threshold (for reporting)
            gain_above = c_r * r_r * tau / (b * D_t);

            details.u_star = u_star;
            details.h_star_IOPS = h_star;
            details.R_star = R_star;
            details.gain_above_threshold = gain_above;
            details.msg = sprintf(['h* = %.1f IOPS (u* = %.4f). ' ...
                'Safe replay rate R* = %.0f ops/sec. ' ...
                'Gain above threshold: %.0f (phase transition).'], ...
                h_star, u_star, R_star, gain_above);

            % Numerical verification: sweep replay rates and confirm the
            % closed-form boundary matches. Kept for validation, not for
            % computing h*.
            throttles = linspace(1, D_t, 1000);
            rho_vals = zeros(size(throttles));
            for i = 1:numel(throttles)
                p_sweep = params;
                p_sweep.replay_rate = throttles(i);
                G = compute_gain_matrix(p_sweep);
                % G is now scalar for cassandra; max(abs(eig(G))) = abs(G)
                if isscalar(G)
                    rho_vals(i) = abs(G);
                else
                    rho_vals(i) = max(abs(eig(G)));
                end
            end
            details.sweep.throttles = throttles;
            details.sweep.rho_vals = rho_vals;

            % Verify closed form matches sweep
            idx = find(rho_vals >= 1, 1, 'first');
            if ~isempty(idx)
                details.sweep.cascade_at = throttles(idx);
                details.sweep.matches_closed_form = abs(throttles(idx) - R_star) < (D_t / 1000);
            end

        otherwise
            error('find_hstar:unknownType', 'Unknown type: %s', sys_type);
    end
end
