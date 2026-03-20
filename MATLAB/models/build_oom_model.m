function build_oom_model()
% BUILD_OOM_MODEL Programmatically create oom_model.slx.
%
%   Scalar feedback: kill -> restart -> allocate -> pressure -> kill.
%   G = alloc_on_restart / mem_freed.
%
%   Parameters are stored in the model workspace and referenced by name.
%   To change parameters after building:
%   Model Explorer > Model Workspace > edit values > re-run simulation.

    model = 'oom_model';

    if bdIsLoaded(model), close_system(model, 0); end
    if exist([model '.slx'], 'file'), delete([model '.slx']); end
    new_system(model);
    open_system(model);

    p = oom_params();

    hws = get_param(model, 'ModelWorkspace');
    hws.assignin('S', p.S);
    hws.assignin('n_procs', p.n_procs);
    hws.assignin('mem_per_proc', p.mem_per_proc);
    hws.assignin('restart_delay', p.restart_delay);
    hws.assignin('alloc_rate', p.alloc_rate);
    hws.assignin('alloc_on_restart', p.alloc_on_restart);
    hws.assignin('mem_freed', p.mem_freed);

    %% Core dynamics — MATLAB Function block
    add_block('simulink/User-Defined Functions/MATLAB Function', ...
        [model '/OOM_Dynamics'], ...
        'Position', [200 50 420 170]);

    % Get the Stateflow chart object to set the MATLAB Function block's code
    mf = find(slroot, '-isa', 'Stateflow.EMChart', 'Path', [model '/OOM_Dynamics']);

    % MATLAB Function code references parameters by name. Values come from
    % Parameter-scoped data resolved against the model workspace.
    % 'persistent' variables retain values across timesteps (like C's static).
    code = {
        'function [total_mem, h_mem, kill_event, G_val, n_kills] = OOM_Dynamics(state_in)'
        'persistent mem_total kills restart_timer restarting'
        'if isempty(mem_total)'
        '    mem_total = n_procs * mem_per_proc;'
        '    kills = 0;'
        '    restart_timer = -1;'
        '    restarting = false;'
        'end'
        ''
        'dt = 0.01;'
        ''
        '% Check OOM condition'
        'kill_event = 0;'
        'if mem_total > S'
        '    mem_total = mem_total - mem_freed;  % kill largest'
        '    kill_event = 1;'
        '    kills = kills + 1;'
        '    restart_timer = restart_delay;  % start restart countdown'
        '    restarting = true;'
        'end'
        ''
        '% Restart logic'
        'if restarting'
        '    restart_timer = restart_timer - dt;'
        '    if restart_timer <= 0'
        '        restarting = false;'
        '    end'
        'end'
        ''
        '% Post-restart allocation (ramps up)'
        'if ~restarting && restart_timer > -2 && restart_timer <= 0'
        '    mem_total = mem_total + alloc_rate * dt;'
        '    if mem_total >= S  % will trigger OOM again if G >= 1'
        '        restart_timer = -2;  % stop ramping'
        '    end'
        'end'
        ''
        'total_mem = mem_total;'
        'h_mem = S - mem_total;'
        'G_val = alloc_on_restart / mem_freed;'
        'n_kills = kills;'
    };
    mf.Script = strjoin(code, newline);

    % Register parameters so the block resolves them from model workspace
    params = {'S', 'n_procs', 'mem_per_proc', 'restart_delay', ...
              'alloc_rate', 'alloc_on_restart', 'mem_freed'};
    for i = 1:numel(params)
        d = Stateflow.Data(mf);
        d.Name = params{i};
        d.Scope = 'Parameter';
    end

    %% Constant input (state placeholder)
    % Dummy constant input — the real state is tracked via persistent variables inside the MATLAB Function block
    add_block('simulink/Sources/Constant', [model '/state_in'], ...
        'Value', '0', 'Position', [50 80 100 110]);

    %% To Workspace
    % Cell array of output names — used to programmatically create To Workspace blocks in a loop
    outputs = {'total_mem', 'h_mem', 'kill_event', 'G_val', 'n_kills'};
    var_names = {'oom_mem', 'oom_h', 'oom_kills', 'oom_G', 'oom_n_kills'};
    for i = 1:numel(outputs)
        add_block('simulink/Sinks/To Workspace', [model '/' outputs{i} '_out'], ...
            'VariableName', var_names{i}, ...
            'Position', [550 30+50*(i-1) 600 60+50*(i-1)]);
    end

    %% Scope
    % Scope displays live plots during simulation — useful for visual debugging
    add_block('simulink/Sinks/Scope', [model '/mem_scope'], ...
        'Position', [550 300 580 330], 'NumInputPorts', '2');

    %% Wiring
    add_line(model, 'state_in/1', 'OOM_Dynamics/1');
    for i = 1:numel(outputs)
        add_line(model, sprintf('OOM_Dynamics/%d', i), [outputs{i} '_out/1']);
    end
    add_line(model, 'OOM_Dynamics/1', 'mem_scope/1');
    add_line(model, 'OOM_Dynamics/2', 'mem_scope/2');

    %% Simulation settings
    set_param(model, 'StopTime', num2str(p.sim_time));
    set_param(model, 'SolverType', 'Fixed-step');
    set_param(model, 'FixedStep', '0.01');

    save_system(model, fullfile('models', [model '.slx']));
    fprintf('Created models/%s.slx\n', model);
end
