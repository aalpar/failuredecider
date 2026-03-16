function pass = test_check_invariant()
% Test check_invariant against a known-stable system (TCP-like).

    sys.name  = 'test_stable';
    sys.n     = 1;
    sys.C     = 100;
    sys.w     = @(t) 60;
    % Complex anonymous function modeling adaptive recovery rate. floor(), log2(), max() work element-wise on scalars.
    sys.r     = @(t,h) max(0, 1./(1 * 2.^max(0, floor(-log2(max(h,0.01)/40)))));
    sys.delta = 1;
    sys.G     = -0.5;

    result = check_invariant(sys);
    % check_invariant returns a struct with level0/1/2/3 pass/fail and diagnostic fields

    % MATLAB has no built-in test assertions in base — we return true/false and let verify_all handle reporting.
    pass = true;
    pass = pass && result.level0;    % resource model valid
    pass = pass && result.level1;    % individual cost bounded
    pass = pass && result.level3;    % rho(G) < 1
    pass = pass && (result.rho < 1);
    pass = pass && (abs(result.rho - 0.5) < 0.01);
end
