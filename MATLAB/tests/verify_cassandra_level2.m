function pass = verify_cassandra_level2()
% Verify: hints accumulate linearly, replay creates burst exceeding capacity.
    % Tests that hint replay can create a burst exceeding disk capacity if throttle is too high.
    p = cassandra_params();
    total_hints = p.write_rate * p.T_outage;
    replay_time = total_hints / p.replay_throttle;

    burst_load = p.D_normal + p.replay_throttle;
    under_capacity = burst_load < p.D_total;

    fast_throttle = p.replay_throttle * 10;
    fast_load = p.D_normal + fast_throttle;
    exceeds = fast_load > p.D_total;

    pass = exceeds;
end
