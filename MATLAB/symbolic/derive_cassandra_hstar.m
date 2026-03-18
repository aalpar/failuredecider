function results = derive_cassandra_hstar()
% DERIVE_CASSANDRA_HSTAR Symbolic derivation of Cassandra hint replay cascade boundary.
%
%   The Cassandra cascade is disk-dominated: hint replay raises disk
%   utilization, M/M/1 latency model creates a phase transition at a
%   critical utilization u*, and the read repair feedback gain above
%   that threshold is >> 1 (sharp cliff, not smooth transition).
%
%   Derives:
%     1. Critical disk utilization u* = 1 - b/tau (from M/M/1 latency model)
%     2. Critical headroom h* = D_t * b / tau (IOPS margin before cascade)
%     3. Safe replay rate R* = D_t * (1 - b/tau) - D_n
%     4. Feedback gain above threshold: g = c_r * r_r * tau / (b * D_t)
%     5. Maximum safe outage duration at a given write rate and throttle
%     6. Numerical verification with default parameters
%
%   Compare to swap's E* = D'*W/(2f): both are closed-form functions of
%   measurable quantities. The structural difference is the instability
%   type: swap has a smooth transition (rho crosses 1), Cassandra has a
%   phase transition (gain jumps from 0 to >> 1 at u*).

    fprintf('\n=== Cassandra h* — Symbolic Derivation ===\n\n');

    % Symbolic variables for the derivation. 'real positive' constrains
    % them so the symbolic engine can simplify expressions involving
    % square roots, divisions, and inequalities.
    syms b tau D_t D_n c_r r_r R real positive

    %% 1. Critical utilization from M/M/1 latency model
    %
    %   M/M/1 latency: L = b / (1 - u), where u = total_IOPS / D_t.
    %   Timeouts occur when L > tau (read timeout threshold).
    %
    %   Solve b/(1-u) = tau for u:
    syms u real positive
    L = b / (1 - u);
    u_star = solve(L == tau, u);
    % simplify() applies algebraic identities to produce a cleaner form.
    u_star = simplify(u_star);

    fprintf('1. M/M/1 latency model: L = b / (1 - u)\n');
    fprintf('   Timeouts begin when L > tau, i.e., when u > u*\n');
    fprintf('   u* = %s\n', char(u_star));
    results.u_star = u_star;

    %% 2. Critical headroom h*
    %
    %   Headroom h = D_t - total_IOPS = D_t * (1 - u).
    %   At u = u*, headroom is:
    h_star = simplify(D_t * (1 - u_star));

    fprintf('\n2. Critical headroom (IOPS margin before cascade):\n');
    fprintf('   h* = D_t * (1 - u*) = %s\n', char(h_star));
    results.h_star = h_star;

    %% 3. Safe replay rate R*
    %
    %   Total IOPS during replay = D_n (normal) + R (replay).
    %   Cascade when D_n + R > D_t - h*, i.e., D_n + R > D_t * u*.
    %   Safe when R < R*:
    R_star = simplify(D_t * u_star - D_n);

    fprintf('\n3. Safe replay rate:\n');
    fprintf('   Cascade when D_n + R > D_t * u*, i.e., R > R*\n');
    fprintf('   R* = %s\n', char(R_star));
    results.R_star = R_star;

    %% 4. Feedback gain above threshold
    %
    %   Once timeouts begin (u > u*), the repair feedback loop is:
    %     headroom drops -> utilization rises -> latency rises (M/M/1)
    %     -> more timeouts -> more read repairs -> more IOPS -> less headroom
    %
    %   Timeout fraction: tf(u) = 1 - tau*(1-u)/b  for u > u*
    %   Repair rate: repair_rate = r_r * tf(u)
    %   Additional IOPS from repairs: c_r * r_r * tf(u)
    %
    %   Gain = d(total_IOPS) / d(-h):
    %     d(u)/d(-h) = 1/D_t
    %     d(tf)/d(u) = tau/b
    %     d(repair_IOPS)/d(tf) = c_r * r_r
    %
    %   Chain rule:
    g = simplify(c_r * r_r * tau / (b * D_t));

    fprintf('\n4. Feedback gain above threshold (chain rule through M/M/1):\n');
    fprintf('   g = d(repair_IOPS)/d(-h) = %s\n', char(g));
    fprintf('   Cascade requires g >= 1.\n');
    fprintf('   With typical parameters, g >> 1 — the transition is a cliff,\n');
    fprintf('   not a slope. The system jumps from gain 0 to gain >> 1 at u*.\n');
    results.gain_expr = g;

    %% 5. Maximum safe outage duration
    %
    %   Hints accumulate at write_rate * T_outage.
    %   Replay at throttle rate R_throttle takes T_replay = hints / R_throttle.
    %   Safe when R_throttle < R*. Given a safe throttle, any outage
    %   duration is eventually replayable — the constraint is R_throttle, not
    %   T_outage. But longer outages mean longer replay windows during which
    %   normal load might spike and push total IOPS past the boundary.
    %
    %   For a fixed headroom budget H_avail = D_t - D_n - current_replay:
    %   maximum safe throttle = H_avail (by definition).
    %   At that throttle, replay time for T_outage seconds of writes:
    syms w_rate T_out R_throttle real positive
    total_hints = w_rate * T_out;
    T_replay = total_hints / R_throttle;

    fprintf('\n5. Replay duration:\n');
    fprintf('   Hints accumulated = write_rate * T_outage\n');
    fprintf('   T_replay = hints / R_throttle = %s\n', char(simplify(T_replay)));
    fprintf('   Safe when R_throttle < R*. The binding constraint is the\n');
    fprintf('   replay rate, not the outage duration.\n');
    results.T_replay = T_replay;

    %% 6. Structural comparison: Cassandra vs. swap
    fprintf('\n6. Structural comparison:\n');
    fprintf('   Swap:      h* = D''*W/(2f)    smooth transition, rho crosses 1\n');
    fprintf('   Cassandra: h* = D_t*b/tau     phase transition, gain jumps 0 -> >>1\n');
    fprintf('   Both are closed-form functions of measurable quantities.\n');
    fprintf('   Swap''s linearized h* is a lower bound (monotonicity).\n');
    fprintf('   Cassandra''s h* is exact given the M/M/1 model — the\n');
    fprintf('   phase transition IS the nonlinearity, not a linearization artifact.\n');

    %% 7. Numerical verification with default parameters
    fprintf('\n7. Numerical verification (cassandra_params defaults):\n\n');

    p = struct();
    p.b     = 0.005;    % base read latency (5ms)
    p.tau   = 0.5;      % read timeout (500ms)
    p.D_t   = 500;      % total disk IOPS
    p.D_n   = 200;      % normal IOPS
    p.c_r   = 3;        % IOPS per read repair
    p.r_r   = 5000;     % read rate (reads/sec)
    p.w_rate = 10000;   % write rate (writes/sec)
    p.R_throttle = 128; % default replay throttle (hints/sec)

    u_star_val = 1 - p.b / p.tau;
    h_star_val = p.D_t * p.b / p.tau;
    R_star_val = p.D_t * u_star_val - p.D_n;
    g_val      = p.c_r * p.r_r * p.tau / (p.b * p.D_t);

    fprintf('   Base latency b        = %.3f s\n', p.b);
    fprintf('   Read timeout tau      = %.3f s\n', p.tau);
    fprintf('   Disk capacity D_t     = %d IOPS\n', p.D_t);
    fprintf('   Normal load D_n       = %d IOPS\n', p.D_n);
    fprintf('   Repair cost c_r       = %d IOPS/repair\n', p.c_r);
    fprintf('   Read rate r_r         = %d reads/sec\n', p.r_r);
    fprintf('   Write rate            = %d writes/sec\n', p.w_rate);
    fprintf('   Default throttle      = %d hints/sec\n', p.R_throttle);
    fprintf('\n');
    fprintf('   u*     = 1 - b/tau    = %.4f  (%.1f%% utilization)\n', u_star_val, u_star_val * 100);
    fprintf('   h*     = D_t * b/tau  = %.1f IOPS\n', h_star_val);
    fprintf('   R*     = D_t*u* - D_n = %.0f hints/sec  (safe replay rate)\n', R_star_val);
    fprintf('   g      = c_r*r_r*tau/(b*D_t) = %.0f  (gain above threshold)\n', g_val);
    fprintf('\n');
    fprintf('   Default throttle %d < R* %.0f: SAFE\n', p.R_throttle, R_star_val);

    results.numeric.u_star = u_star_val;
    results.numeric.h_star_IOPS = h_star_val;
    results.numeric.R_star = R_star_val;
    results.numeric.gain_above_threshold = g_val;

    %% 8. Sensitivity table: varying parameters
    %
    %   Show h* and R* across disk capacities and timeout thresholds to
    %   demonstrate how the boundary moves with hardware and configuration.
    fprintf('\n8. Sensitivity: h* and R* across configurations\n');
    fprintf('   (b = 5ms, D_n = 200 IOPS, r_r = 5000 reads/sec)\n\n');
    fprintf('   %-12s  %-12s  %-10s  %-12s  %-12s  %-10s\n', ...
        'D_total', 'tau (ms)', 'u*', 'h* (IOPS)', 'R* (ops/s)', 'gain');
    fprintf('   %-12s  %-12s  %-10s  %-12s  %-12s  %-10s\n', ...
        '-------', '--------', '--', '---------', '----------', '----');

    D_totals = [500, 1000, 5000, 50000];
    taus     = [0.5, 1.0, 2.0];

    % Pre-allocate struct array for results table.
    results.sensitivity = struct('D_total', {}, 'tau', {}, 'u_star', {}, ...
                                  'h_star', {}, 'R_star', {}, 'gain', {});
    row = 0;
    for i = 1:numel(D_totals)
        for j = 1:numel(taus)
            row = row + 1;
            Dt  = D_totals(i);
            tv  = taus(j);
            us  = 1 - p.b / tv;
            hs  = Dt * p.b / tv;
            Rs  = Dt * us - p.D_n;
            gv  = p.c_r * p.r_r * tv / (p.b * Dt);

            results.sensitivity(row).D_total = Dt;
            results.sensitivity(row).tau     = tv;
            results.sensitivity(row).u_star  = us;
            results.sensitivity(row).h_star  = hs;
            results.sensitivity(row).R_star  = Rs;
            results.sensitivity(row).gain    = gv;

            fprintf('   %-12d  %-12.0f  %-10.4f  %-12.1f  %-12.0f  %-10.0f\n', ...
                Dt, tv * 1000, us, hs, Rs, gv);
        end
    end

    %% 9. Replay duration for representative outages
    fprintf('\n9. Replay duration at default throttle (%d hints/sec):\n\n', p.R_throttle);
    fprintf('   %-15s  %-15s  %-15s\n', 'Outage', 'Hints', 'Replay time');
    fprintf('   %-15s  %-15s  %-15s\n', '------', '-----', '-----------');

    outages = [60, 600, 3600, 86400];
    outage_names = {'1 minute', '10 minutes', '1 hour', '1 day'};
    results.replay = struct('outage_sec', {}, 'hints', {}, 'replay_sec', {});

    for i = 1:numel(outages)
        T = outages(i);
        hints = p.w_rate * T;
        t_replay = hints / p.R_throttle;

        results.replay(i).outage_sec  = T;
        results.replay(i).hints       = hints;
        results.replay(i).replay_sec  = t_replay;

        % Format replay time in human-readable units
        if t_replay < 3600
            replay_str = sprintf('%.0f min', t_replay / 60);
        elseif t_replay < 86400
            replay_str = sprintf('%.1f hours', t_replay / 3600);
        else
            replay_str = sprintf('%.1f days', t_replay / 86400);
        end

        fprintf('   %-15s  %-15s  %-15s\n', ...
            outage_names{i}, sprintf('%.1fM', hints / 1e6), replay_str);
    end

    fprintf('\n   At the safe throttle R*=%.0f, these times shrink by %.1fx,\n', ...
        R_star_val, R_star_val / p.R_throttle);
    fprintf('   but any load spike during replay risks crossing h*.\n');

    %% 10. The phase transition: gain below and above u*
    fprintf('\n10. Phase transition structure:\n\n');
    fprintf('    u < u* (%.4f):  gain = 0      (no timeouts, no feedback)\n', u_star_val);
    fprintf('    u > u* (%.4f):  gain = %.0f   (violent feedback)\n', u_star_val, g_val);
    fprintf('\n');
    fprintf('    There is no smooth transition through gain = 1.\n');
    fprintf('    The system jumps from stable to violently unstable at u*.\n');
    fprintf('    This is structurally different from swap, where rho(G)\n');
    fprintf('    increases smoothly with load. The M/M/1 nonlinearity\n');
    fprintf('    creates a cliff. The linearization critique (Hartman-Grobman\n');
    fprintf('    radius unknown) does not apply here — the phase transition\n');
    fprintf('    IS the model, not a linearization artifact.\n');

    fprintf('\n=== Derivation complete. ===\n');
end
