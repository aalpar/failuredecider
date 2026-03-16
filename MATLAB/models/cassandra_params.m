function p = cassandra_params()
% CASSANDRA_PARAMS Default parameters for Cassandra hinted handoff model.
%
%   Resources: Disk IOPS, CPU utilization
%   Article reference: "Hinted handoff violates Level 2, Level 3"
% Returns a struct 'p' with all parameters as fields (MATLAB structs use dot notation).

    p.type = 'cassandra';

    % Traffic
    p.write_rate      = 10000;   % writes/sec to affected partition
    p.read_rate       = 5000;    % reads/sec to affected partition

    % Outage
    p.T_outage        = 600;     % 10-minute outage (seconds)

    % Replay
    p.replay_throttle = 128;     % hint replays/sec (1024 kbps / ~8KB per hint)
    % 1024 kbps / ~8KB per hint = ~128 hints/sec — this is the replay bottleneck

    % Disk
    p.D_total         = 500;     % total disk IOPS on returning node
    p.D_normal        = 200;     % IOPS consumed by normal read/write path

    % Read path
    p.base_latency    = 0.005;   % base read latency (5ms)
    p.read_timeout    = 0.5;     % read timeout (500ms)
    p.repair_cost     = 3;       % IOPS per read repair
    p.repair_cpu_cost = 0.01;    % CPU fraction per read repair

    % Derived (set during simulation)
    p.timeout_fraction = 0;      % fraction of reads that timeout (computed dynamically)
    % This gets overwritten during simulation — declared here so the struct field exists

    p.sim_time        = 1800;    % simulate 30 minutes
end
