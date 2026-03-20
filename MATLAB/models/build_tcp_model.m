function build_tcp_model()
% BUILD_TCP_MODEL Programmatically create tcp_model.slx.
%
%   Scalar feedback loop: perturbation -> backoff -> convergence.
%   Demonstrates: Level 1 (1 segment), Level 2 (backoff), Level 3 (G=-0.5).
%
%   Parameters are stored in the model workspace and referenced by name.
%   To change parameters after building:
%   Model Explorer > Model Workspace > edit values > re-run simulation.

    model = 'tcp_model';

    % Close if already open, delete if exists
    % bdIsLoaded checks if a Simulink model is in memory; close_system unloads it.
    % new_system creates a blank model, open_system displays it in the editor.
    if bdIsLoaded(model), close_system(model, 0); end
    if exist([model '.slx'], 'file'), delete([model '.slx']); end
    new_system(model);
    open_system(model);

    p = tcp_params();

    %% Parameters — set in model workspace for Simulink access
    hws = get_param(model, 'ModelWorkspace');
    hws.assignin('C', p.C);
    hws.assignin('w0', p.w0);
    hws.assignin('RTO_base', p.RTO_base);
    hws.assignin('max_retries', p.max_retries);
    hws.assignin('perturb_mag', p.perturb_mag);
    hws.assignin('perturb_t', p.perturb_t);

    %% Source blocks
    % Block parameters reference workspace variables by name so users can
    % change them in Model Explorer without rebuilding the model.
    % Normal workload — constant
    add_block('simulink/Sources/Constant', [model '/w0'], ...
        'Value', 'w0', 'Position', [50 100 100 130]);

    % Perturbation — pulse at t=perturb_t
    add_block('simulink/Sources/Step', [model '/Perturbation'], ...
        'Time', 'perturb_t', ...
        'Before', '0', 'After', 'perturb_mag', ...
        'Position', [50 180 100 210]);

    % Capacity — constant
    add_block('simulink/Sources/Constant', [model '/C'], ...
        'Value', 'C', 'Position', [50 30 100 60]);

    %% Timeout counter (increments when h < 0, resets when h > threshold)
    % MATLAB Function blocks let you embed custom MATLAB code inside a Simulink model.
    add_block('simulink/User-Defined Functions/MATLAB Function', ...
        [model '/Backoff_Logic'], ...
        'Position', [250 150 400 220]);

    % find(slroot,...) locates the Stateflow chart object behind the MATLAB Function
    % block so we can programmatically set its code via the .Script property.
    mf = find(slroot, '-isa', 'Stateflow.EMChart', 'Path', [model '/Backoff_Logic']);

    % MATLAB Function code references RTO_base and max_retries by name.
    % Values come from Parameter-scoped data resolved against model workspace.
    code = {
        'function [r, rto, k_out] = Backoff_Logic(h, k_prev)'
        '% Exponential backoff retransmission logic.'
        '% h: current headroom (scalar)'
        '% k_prev: previous timeout count'
        '% r: retransmission rate (segments/RTT)'
        '% rto: current RTO'
        '% k_out: updated timeout count'
        '% Parameters (RTO_base, max_retries) are editable in Model Explorer.'
        ''
        'if h < 0 && k_prev < max_retries'
        '    k_out = k_prev + 1;'
        'elseif h >= 0 && k_prev > 0'
        '    k_out = max(0, k_prev - 1);'
        'else'
        '    k_out = k_prev;'
        'end'
        'rto = RTO_base * 2^k_out;'
        'if k_out > 0'
        '    r = 1 / rto;'
        'else'
        '    r = 0;'
        'end'
    };
    mf.Script = strjoin(code, newline);

    % Register parameters so the block resolves them from model workspace
    params = {'RTO_base', 'max_retries'};
    for i = 1:numel(params)
        d = Stateflow.Data(mf);
        d.Name = params{i};
        d.Scope = 'Parameter';
    end

    %% Memory block to hold k across timesteps
    % Unit Delay holds a value for one timestep — this carries k (timeout count)
    % across simulation steps, acting as discrete memory.
    add_block('simulink/Discrete/Unit Delay', [model '/k_delay'], ...
        'InitialCondition', '0', ...
        'SampleTime', '0.1', ...
        'Position', [450 250 500 280]);

    %% Sum block: h = C - w - perturbation - r
    % Sum block adds/subtracts its inputs. 'Inputs', '+---' means: first input
    % positive, next three negative. This computes h = C - w - perturbation - r.
    add_block('simulink/Math Operations/Sum', [model '/Headroom'], ...
        'Inputs', '+---', 'Position', [180 80 210 160]);

    %% Scopes
    add_block('simulink/Sinks/Scope', [model '/h_scope'], ...
        'Position', [550 80 580 110], 'NumInputPorts', '1');
    add_block('simulink/Sinks/Scope', [model '/r_scope'], ...
        'Position', [550 150 580 180], 'NumInputPorts', '1');
    add_block('simulink/Sinks/Scope', [model '/rto_scope'], ...
        'Position', [550 220 580 250], 'NumInputPorts', '1');

    %% To Workspace blocks (for analysis)
    % To Workspace blocks save simulation data to MATLAB workspace variables
    % for post-simulation analysis and plotting.
    add_block('simulink/Sinks/To Workspace', [model '/h_out'], ...
        'VariableName', 'h_tcp', 'Position', [550 40 600 70]);
    add_block('simulink/Sinks/To Workspace', [model '/r_out'], ...
        'VariableName', 'r_tcp', 'Position', [620 150 670 180]);

    %% Wiring
    % add_line draws a wire between blocks.
    % Format: add_line(model, 'SourceBlock/OutputPort', 'DestBlock/InputPort')
    % C, w0, perturbation, r -> Headroom sum
    add_line(model, 'C/1', 'Headroom/1');
    add_line(model, 'w0/1', 'Headroom/2');
    add_line(model, 'Perturbation/1', 'Headroom/3');

    % Headroom -> Backoff_Logic input 1
    add_line(model, 'Headroom/1', 'Backoff_Logic/1');

    % k_delay -> Backoff_Logic input 2
    add_line(model, 'k_delay/1', 'Backoff_Logic/2');

    % Backoff_Logic output 1 (r) -> Headroom input 4
    add_line(model, 'Backoff_Logic/1', 'Headroom/4');

    % Backoff_Logic output 3 (k_out) -> k_delay
    add_line(model, 'Backoff_Logic/3', 'k_delay/1');

    % Outputs to scopes and workspace
    add_line(model, 'Headroom/1', 'h_scope/1');
    add_line(model, 'Headroom/1', 'h_out/1');
    add_line(model, 'Backoff_Logic/1', 'r_scope/1');
    add_line(model, 'Backoff_Logic/1', 'r_out/1');
    add_line(model, 'Backoff_Logic/2', 'rto_scope/1');

    %% Simulation settings
    % set_param configures model-level settings. Fixed-step solver advances time
    % in equal increments (here 0.1s) — required for discrete blocks like Unit Delay.
    set_param(model, 'StopTime', num2str(p.sim_time));
    set_param(model, 'SolverType', 'Fixed-step');
    set_param(model, 'FixedStep', '0.1');

    %% Save
    % save_system writes the model to a .slx file (Simulink's file format).
    % fullfile builds a platform-independent file path from folder and filename.
    save_system(model, fullfile('models', [model '.slx']));
    fprintf('Created models/%s.slx\n', model);
end
