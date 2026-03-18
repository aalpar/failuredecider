function G = compute_gain_matrix(params)
% COMPUTE_GAIN_MATRIX Compute the recovery gain matrix for a system.
%
%   G = compute_gain_matrix(params) where params has field .type and
%   system-specific parameters. Returns [n x n] gain matrix.
%
%   Types:
%     'tcp'       - scalar G = -0.5 (exponential backoff halves rate)
%     'swap'      - 2x2 cross-resource [epsilon, alpha; beta, epsilon] (rows: disk, memory)
%     'cassandra' - scalar disk-dominated gain (M/M/1 phase transition)
%     'oom'       - scalar G = alloc_on_restart / mem_freed

    % MATLAB's switch/case compares strings with strcmp internally — no need for strcmp() yourself
    switch params.type
        case 'tcp'
            % Exponential backoff: each congestion event halves recovery rate.
            % G = -0.5 (negative = contraction)
            G = -0.5;

        case 'swap'
            % G = [epsilon, alpha; beta, epsilon]  (rows: disk, memory)
            % alpha = d(swap_IOPS)/d(-h_mem) = 2f/W
            % beta  = d(mem_demand)/d(-h_disk) = buf_per_blocked * block_rate
            % alpha: how much disk IOPS increase per page of memory pressure. Derived from: 2 IOPS per page fault, fault_prob ~ E/W
            alpha = 2 * params.f / params.W;
            % beta: how much memory demand increases per unit of disk saturation (blocked processes hold I/O buffers)
            beta  = params.buf_per_blocked * params.block_rate_per_iops;
            eps_  = params.epsilon;  % self-feedback (small)
            G = [eps_, alpha; beta, eps_];

        case 'cassandra'
            % The Cassandra cascade is disk-dominated. The feedback loop:
            %   hint replay -> IOPS increase -> disk utilization u rises
            %   -> read latency rises (M/M/1: L = b/(1-u))
            %   -> timeouts when L > tau -> read repairs (c_r IOPS each)
            %   -> more IOPS (loop)
            %
            % The gain is derived via chain rule through the M/M/1 model:
            %   d(u)/d(-h) = 1/D_t
            %   d(tf)/d(u) = tau/b       (timeout fraction sensitivity)
            %   d(repair_IOPS)/d(tf) = c_r * r_r
            %
            % Composed: g = c_r * r_r * tau / (b * D_t)
            %
            % This gain is zero below the critical utilization u* = 1 - b/tau
            % (no timeouts, no feedback) and jumps to >> 1 above it (phase
            % transition). See derive_cassandra_hstar.m for full derivation.
            %
            % Scalar because disk dominates: eigenvalue analysis of the 2x2
            % disk/CPU matrix shows the dominant eigenvalue is ~g_dd. CPU
            % terms contribute negligibly.

            c_r = params.repair_cost;          % IOPS per read repair
            r_r = params.read_rate;            % reads/sec
            b   = params.base_latency;         % base read latency (seconds)
            tau = params.read_timeout;          % read timeout threshold (seconds)
            D_t = params.D_total;              % total disk IOPS capacity

            % Critical utilization where timeouts begin (from M/M/1)
            u_star = 1 - b / tau;

            % Current disk utilization (without repair feedback)
            D_n = params.D_normal;
            u_current = D_n / D_t;
            if isfield(params, 'replay_rate')
                u_current = (D_n + params.replay_rate) / D_t;
            end

            if u_current > u_star
                % Above threshold: feedback gain from chain rule
                G = c_r * r_r * tau / (b * D_t);
            else
                % Below threshold: no timeouts, no repair feedback
                G = 0;
            end

        case 'oom'
            % Scalar: ratio of memory allocated on restart to memory freed by kill
            G = params.alloc_on_restart / params.mem_freed;

        otherwise
            error('compute_gain_matrix:unknownType', ...
                'Unknown system type: %s', params.type);
    end
end
