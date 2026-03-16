function p = swap_params(workload)
% SWAP_PARAMS Default parameters for UNIX swap thrashing model.
%
%   p = swap_params()           — database workload (article default)
%   p = swap_params('web')      — light web workload
%   p = swap_params('database') — database workload
%   p = swap_params('analytics')— analytics scan workload
%
%   Resources: Memory (pages), Disk (IOPS)
%   Article reference: "Computing h*: UNIX swap thrashing"

    % nargin = Number of ARGuments INput. Provides a default when no argument is given.
    if nargin < 1, workload = 'database'; end

    p.S       = 16e6;       % physical memory: 16M pages (64GB / 4KB)
    p.page_KB = 4;          % page size in KB

    % Disk parameters — two scenarios
    p.D_total_hdd  = 200;   % total HDD IOPS
    p.D_normal_hdd = 100;   % HDD IOPS consumed by normal workload
    p.D_spare_hdd  = 100;   % D' for HDD

    p.D_total_nvme  = 100000; % total NVMe IOPS
    p.D_normal_nvme = 50000;  % NVMe IOPS consumed by normal workload
    p.D_spare_nvme  = 50000;  % D' for NVMe

    % Cross-feedback parameters
    p.epsilon           = 0.05;   % self-feedback (small)
    p.buf_per_blocked   = 4;      % pages of I/O buffers per blocked process (8-16KB / 4KB)
    p.block_rate_per_iops = 0.001; % fraction of blocked processes per IOPS of saturation

    % Workload-specific
    % switch/case is MATLAB's equivalent of if/elseif chains for string comparison.
    switch workload
        case 'web'
            p.f = 10000;          % page access rate (pages/sec)
            p.W = p.S * 1.005;    % working set: 0.5% over physical
            % W > S means working set exceeds physical memory — this forces swapping.
            p.workload_name = 'Light web (1K req/s)';
        case 'database'
            p.f = 100000;
            p.W = p.S * 1.0005;   % working set: 0.05% over physical
            p.workload_name = 'Database (1K qps)';
        case 'analytics'
            p.f = 1000000;
            p.W = p.S * 1.00005;  % working set: 0.005% over physical
            p.workload_name = 'Analytics scan';
        otherwise
            % error() throws an exception. First arg is an error ID ('package:name'),
            % second is the message with sprintf-style formatting (%s = string).
            error('swap_params:unknownWorkload', 'Unknown workload: %s', workload);
    end

    p.sim_time = 50;       % simulation duration (seconds)
    p.disk_type = 'hdd';   % default disk type
end
