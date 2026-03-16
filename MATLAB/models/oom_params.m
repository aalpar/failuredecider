function p = oom_params(gain)
% OOM_PARAMS Default parameters for OOM killer feedback model.
%
%   p = oom_params()     — G = 1.2 (cascade case, article default)
%   p = oom_params(0.8)  — G = 0.8 (stable case)

    if nargin < 1, gain = 1.2; end
    % nargin = Number of ARGuments IN. Provides default gain=1.2 if caller omits it.

    p.type = 'oom';

    p.S              = 16e6;       % total system memory (pages)
    p.n_procs        = 50;         % number of processes
    p.mem_per_proc   = 3.3e5;      % ~330K pages per process (~1.3GB)
    p.restart_delay  = 2;          % seconds before supervisor restarts
    p.alloc_rate     = 50000;      % pages/sec allocated after restart

    % Gain control
    p.mem_freed        = p.mem_per_proc;  % largest process
    p.alloc_on_restart = gain * p.mem_freed;  % what restart allocates
    % This is the key: if gain >= 1, restart allocates MORE than kill freed -> cascade

    p.sim_time       = 60;         % simulation duration (seconds)
end
