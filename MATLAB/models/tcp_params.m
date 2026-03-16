function p = tcp_params()
% TCP_PARAMS Default parameters for TCP retransmission model.
%
%   Resource: link bandwidth (segments/RTT)
%   Article reference: Section "TCP Got This Right (Mostly)"

    % p is a struct; dot notation (p.field) creates or sets named fields on it.
    p.C           = 100;   % link capacity (segments/RTT)
    p.w0          = 60;    % normal traffic rate (segments/RTT)
    p.RTO_base    = 1;     % initial RTO (seconds), from Jacobson estimator
    p.max_retries = 15;    % tcp_retries2 default
    p.perturb_mag = 30;    % congestion spike magnitude (segments/RTT)
    p.perturb_t   = 5;     % time of perturbation (seconds)
    p.sim_time    = 120;   % simulation duration (seconds)
    % Returning p gives callers a single struct containing all parameters.
end
