function fig = sweep_stability(sys_type, param_name, param_range, base_params)
% SWEEP_STABILITY Vary a parameter, plot rho(G) vs. that parameter.
%
%   fig = sweep_stability('swap', 'W', linspace(S*0.99, S*1.01, 200), params)

    rho_vals = zeros(size(param_range));

    % Sweep the parameter: for each value, compute rho(G) to see where it crosses 1
    for i = 1:numel(param_range)
        % Struct copy: p gets a full copy of base_params (MATLAB structs are value types, not references)
        p = base_params;
        % Dynamic field access: p.(param_name) is equivalent to p.W when param_name='W'. Parentheses enable variable field names.
        p.(param_name) = param_range(i);

        switch sys_type
            case 'swap'
                p.type = 'swap';
                G = compute_gain_matrix(p);
            case 'cassandra'
                p.type = 'cassandra';
                p.timeout_fraction = estimate_timeout_fraction_sweep(p);
                G = compute_gain_matrix(p);
            case 'oom'
                p.type = 'oom';
                p.alloc_on_restart = p.(param_name);
                G = compute_gain_matrix(p);
            otherwise
                error('sweep_stability:unknownType', 'Unknown type: %s', sys_type);
        end
        rho_vals(i) = max(abs(eig(G)));
    end

    % Create a named figure window. figure() returns a handle for further customization.
    fig = figure('Name', sprintf('Stability sweep: %s vs %s', sys_type, param_name));
    hold on;

    % Set y-axis range. max(2, ...) ensures we always show the rho=1 threshold line.
    ylims = [0, max(2, max(rho_vals) * 1.1)];
    idx_unstable = rho_vals >= 1;
    if any(idx_unstable)
        x_unstable = param_range(idx_unstable);
        % fill() draws a colored polygon — here shading the unstable region (rho >= 1) in light red
        fill([x_unstable(1) x_unstable(end) x_unstable(end) x_unstable(1)], ...
             [ylims(1) ylims(1) ylims(2) ylims(2)], ...
             [1 0.9 0.9], 'EdgeColor', 'none', 'FaceAlpha', 0.3);
    end

    % plot() draws a 2D line. 'b-' = blue solid line. 'LineWidth' sets thickness.
    plot(param_range, rho_vals, 'b-', 'LineWidth', 2);

    % yline() draws a horizontal reference line. 'r--' = red dashed. This marks the cascade threshold.
    yline(1, 'r--', '\rho(G) = 1', 'LineWidth', 1.5, 'LabelHorizontalAlignment', 'left');

    xlabel(param_name, 'Interpreter', 'none');
    ylabel('\rho(G)');
    title(sprintf('%s: Spectral radius vs %s', sys_type, param_name), 'Interpreter', 'none');
    ylim(ylims);
    grid on;
    hold off;
end

function tf = estimate_timeout_fraction_sweep(params)
    total_iops = params.D_normal + params.replay_throttle;
    util = min(total_iops / params.D_total, 0.999);
    latency = params.base_latency / (1 - util);
    tf = min(1, max(0, (latency - params.read_timeout) / latency));
end
