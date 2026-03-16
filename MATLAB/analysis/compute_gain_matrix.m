function G = compute_gain_matrix(params)
% COMPUTE_GAIN_MATRIX Compute the recovery gain matrix for a system.
%
%   G = compute_gain_matrix(params) where params has field .type and
%   system-specific parameters. Returns [n x n] gain matrix.
%
%   Types:
%     'tcp'       - scalar G = -0.5 (exponential backoff halves rate)
%     'swap'      - 2x2 cross-resource [epsilon, beta; alpha, epsilon]
%     'cassandra' - 2x2 disk/CPU feedback during hint replay
%     'oom'       - scalar G = alloc_on_restart / mem_freed

    % MATLAB's switch/case compares strings with strcmp internally — no need for strcmp() yourself
    switch params.type
        case 'tcp'
            % Exponential backoff: each congestion event halves recovery rate.
            % G = -0.5 (negative = contraction)
            G = -0.5;

        case 'swap'
            % G = [epsilon, beta; alpha, epsilon]
            % alpha = d(swap_IOPS)/d(-h_mem) = 2f/W
            % beta  = d(mem_demand)/d(-h_disk) = buf_per_blocked * block_rate
            % alpha: how much disk IOPS increase per page of memory pressure. Derived from: 2 IOPS per page fault, fault_prob ~ E/W
            alpha = 2 * params.f / params.W;
            % beta: how much memory demand increases per unit of disk saturation (blocked processes hold I/O buffers)
            beta  = params.buf_per_blocked * params.block_rate_per_iops;
            eps_  = params.epsilon;  % self-feedback (small)
            G = [eps_, beta; alpha, eps_];

        case 'cassandra'
            % During hint replay:
            % g_disk_disk: disk contention self-amplification
            % g_disk_cpu:  CPU contention -> slower disk ops -> more queuing
            % g_cpu_disk:  disk saturation -> blocked threads -> CPU waste
            % g_cpu_cpu:   CPU contention self-amplification (read repairs)
            %
            % The read repair cascade:
            %   high disk util -> high read latency (M/M/1) -> timeouts
            %   -> read repairs -> more disk IOPS + more CPU
            repair_iops    = params.repair_cost;        % IOPS per read repair
            timeout_rate   = params.read_rate * params.timeout_fraction;
            repair_cpu     = params.repair_cpu_cost;    % CPU fraction per repair

            % Gain: how much additional recovery per unit headroom lost
            g_dd = repair_iops * timeout_rate / params.D_total;
            g_dc = 0.1;   % CPU contention has minor effect on disk
            g_cd = repair_cpu * timeout_rate / 1.0;  % disk pressure -> CPU via repairs
            g_cc = 0.1;   % CPU self-amplification (context switching)
            G = [g_dd, g_dc; g_cd, g_cc];

        case 'oom'
            % Scalar: ratio of memory allocated on restart to memory freed by kill
            G = params.alloc_on_restart / params.mem_freed;

        otherwise
            error('compute_gain_matrix:unknownType', ...
                'Unknown system type: %s', params.type);
    end
end
