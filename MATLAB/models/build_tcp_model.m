function build_tcp_model()
% BUILD_TCP_MODEL Programmatically create tcp_model.slx.
%
%   Scalar feedback loop: perturbation -> backoff -> convergence.
%   Demonstrates: Level 1 (1 segment), Level 2 (backoff), Level 3 (G=-0.5).

    model = 'tcp_model';

    % Close if already open, delete if exists
    % bdIsLoaded checks if a Simulink model is in memory; close_system unloads it.
    % new_system creates a blank model, open_system displays it in the editor.
    if bdIsLoaded(model), close_system(model, 0); end
    if exist([model '.slx'], 'file'), delete([model '.slx']); end
    new_system(model);
    open_system(model);

    p = tcp_params();

    %% Source blocks
    % add_block copies a block from Simulink's library into our model.
    % First arg: library path (e.g. 'simulink/Sources/Constant').
    % Second arg: destination path in our model. 'Position' sets XY coordinates.
    % Normal workload — constant
    add_block('simulink/Sources/Constant', [model '/w0'], ...
        'Value', num2str(p.w0), 'Position', [50 100 100 130]);

    % Perturbation — pulse at t=perturb_t
    add_block('simulink/Sources/Step', [model '/Perturbation'], ...
        'Time', num2str(p.perturb_t), ...
        'Before', '0', 'After', num2str(p.perturb_mag), ...
        'Position', [50 180 100 210]);

    % Capacity — constant
    add_block('simulink/Sources/Constant', [model '/C'], ...
        'Value', num2str(p.C), 'Position', [50 30 100 60]);

    %% Timeout counter (increments when h < 0, resets when h > threshold)
    % Model the discrete backoff: k = number of consecutive timeouts
    % We use a MATLAB Function block for clarity
    % MATLAB Function blocks let you embed custom MATLAB code inside a Simulink model.
    add_block('simulink/User-Defined Functions/MATLAB Function', ...
        [model '/Backoff_Logic'], ...
        'Position', [250 150 400 220]);

    % Set the MATLAB Function code
    % find(slroot,...) locates the Stateflow chart object behind the MATLAB Function
    % block so we can programmatically set its code via the .Script property.
    mf = find(slroot, '-isa', 'Stateflow.EMChart', 'Path', [model '/Backoff_Logic']);
    % sprintf formats a string (like C's sprintf). The [... \n ...] syntax
    % concatenates string fragments across lines. %g placeholders get filled
    % by the trailing arguments (p.RTO_base, p.max_retries).
    mf.Script = sprintf([...
        'function [r, rto, k_out] = Backoff_Logic(h, k_prev)\n' ...
        '%% Exponential backoff retransmission logic.\n' ...
        '%% h: current headroom (scalar)\n' ...
        '%% k_prev: previous timeout count\n' ...
        '%% r: retransmission rate (segments/RTT)\n' ...
        '%% rto: current RTO\n' ...
        '%% k_out: updated timeout count\n' ...
        'RTO_base = %g;\n' ...
        'max_retries = %g;\n' ...
        'if h < 0 && k_prev < max_retries\n' ...
        '    k_out = k_prev + 1;\n' ...
        'elseif h >= 0 && k_prev > 0\n' ...
        '    k_out = max(0, k_prev - 1);\n' ...
        'else\n' ...
        '    k_out = k_prev;\n' ...
        'end\n' ...
        'rto = RTO_base * 2^k_out;\n' ...
        'if k_out > 0\n' ...
        '    r = 1 / rto;\n' ...
        'else\n' ...
        '    r = 0;\n' ...
        'end\n'], ...
        p.RTO_base, p.max_retries);

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
