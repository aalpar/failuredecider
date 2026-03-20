function build_swap_model()
% BUILD_SWAP_MODEL Programmatically create swap_model.slx.
%
%   2x2 cross-resource feedback: memory <-> disk.
%   Demonstrates: Level 1 (one page, 2 IOPS), Level 2 (conditional),
%   Level 3 (cascade when alpha*beta >= 1).
%
%   Parameters are stored in the model workspace and referenced by name
%   in the MATLAB Function block. To change parameters after building:
%   Model Explorer > Model Workspace > edit values > re-run simulation.

    model = 'swap_model';

    if bdIsLoaded(model), close_system(model, 0); end
    if exist([model '.slx'], 'file'), delete([model '.slx']); end
    new_system(model);
    open_system(model);

    p = swap_params('database');

    %% Parameters — set in model workspace for Simulink access
    % get_param(model, 'ModelWorkspace') gets the model's workspace — a container
    % for variables that Simulink blocks can reference. assignin puts a variable in.
    hws = get_param(model, 'ModelWorkspace');
    hws.assignin('S', p.S);
    hws.assignin('f', p.f);
    hws.assignin('D_spare', p.D_spare_hdd);
    hws.assignin('D_total', p.D_total_hdd);
    hws.assignin('D_normal', p.D_normal_hdd);
    hws.assignin('epsilon', p.epsilon);
    hws.assignin('buf_per_blocked', p.buf_per_blocked);

    %% Working set ramp — increases over time to cross h*
    % Ramp block outputs a linearly increasing signal. Block parameters
    % reference workspace variables so changing S automatically adjusts the ramp.
    add_block('simulink/Sources/Ramp', [model '/W_ramp'], ...
        'Slope', 'S * 0.001', ...
        'Start', '0', ...
        'InitialOutput', 'S * 0.999', ...
        'Position', [50 50 100 80]);

    %% Core dynamics — MATLAB Function block
    add_block('simulink/User-Defined Functions/MATLAB Function', ...
        [model '/Swap_Dynamics'], ...
        'Position', [200 40 400 160]);

    mf = find(slroot, '-isa', 'Stateflow.EMChart', 'Path', [model '/Swap_Dynamics']);

    % MATLAB Function code references parameters by name. Values come from
    % Parameter-scoped data objects (registered below), which resolve against
    % the model workspace. No values are baked in — edit them in Model Explorer.
    code = {
        'function [h_mem, h_disk, swap_iops, rho_G, E_val] = Swap_Dynamics(W)'
        '% Cross-resource swap feedback dynamics.'
        '% Parameters (S, f, D_spare, epsilon, buf_per_blocked) are editable'
        '% in Model Explorer > Model Workspace.'
        ''
        '% Excess working set'
        'E_val = max(0, W - S);'
        ''
        '% Page fault rate and swap IOPS'
        'if W > 0'
        '    fault_prob = E_val / W;'
        'else'
        '    fault_prob = 0;'
        'end'
        'swap_iops = 2 * f * fault_prob;  % 2 IOPS per fault (in + out)'
        ''
        '% Headroom'
        'h_mem = S - (W - E_val);  % pages of memory headroom'
        'h_disk = D_spare - swap_iops;'
        ''
        '% Gain matrix'
        'alpha = 2 * f / max(W, 1);       % d(swap_IOPS)/d(-h_mem)'
        'beta = buf_per_blocked * 0.001;   % d(mem_demand)/d(-h_disk)'
        'G = [epsilon, alpha; beta, epsilon];  % rows: disk, memory'
        'rho_G = max(abs(eig(G)));  % spectral radius: > 1 means cascade'
    };
    mf.Script = strjoin(code, newline);

    % Register parameters so the MATLAB Function block resolves them
    % from the model workspace instead of requiring hardcoded values.
    params = {'S', 'f', 'D_spare', 'epsilon', 'buf_per_blocked'};
    for i = 1:numel(params)
        d = Stateflow.Data(mf);
        d.Name = params{i};
        d.Scope = 'Parameter';
    end

    %% Scopes
    add_block('simulink/Sinks/Scope', [model '/headroom_scope'], ...
        'Position', [500 30 530 60], 'NumInputPorts', '2');
    add_block('simulink/Sinks/Scope', [model '/rho_scope'], ...
        'Position', [500 100 530 130], 'NumInputPorts', '1');
    add_block('simulink/Sinks/Scope', [model '/iops_scope'], ...
        'Position', [500 170 530 200], 'NumInputPorts', '1');

    %% To Workspace
    add_block('simulink/Sinks/To Workspace', [model '/h_mem_out'], ...
        'VariableName', 'h_mem_swap', 'Position', [500 240 550 270]);
    add_block('simulink/Sinks/To Workspace', [model '/h_disk_out'], ...
        'VariableName', 'h_disk_swap', 'Position', [500 290 550 320]);
    add_block('simulink/Sinks/To Workspace', [model '/rho_out'], ...
        'VariableName', 'rho_swap', 'Position', [500 340 550 370]);

    %% Wiring
    add_line(model, 'W_ramp/1', 'Swap_Dynamics/1');
    add_line(model, 'Swap_Dynamics/1', 'headroom_scope/1');
    add_line(model, 'Swap_Dynamics/2', 'headroom_scope/2');
    add_line(model, 'Swap_Dynamics/4', 'rho_scope/1');
    add_line(model, 'Swap_Dynamics/3', 'iops_scope/1');
    add_line(model, 'Swap_Dynamics/1', 'h_mem_out/1');
    add_line(model, 'Swap_Dynamics/2', 'h_disk_out/1');
    add_line(model, 'Swap_Dynamics/4', 'rho_out/1');

    %% Simulation settings
    set_param(model, 'StopTime', num2str(p.sim_time));
    set_param(model, 'SolverType', 'Fixed-step');
    set_param(model, 'FixedStep', '0.01');

    save_system(model, fullfile('models', [model '.slx']));
    fprintf('Created models/%s.slx\n', model);
end
