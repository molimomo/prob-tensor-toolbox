function [E_FACT,E_FACT2, E_Lambda, Lowerbound, model,all_samples]=VB_CP_ALS(X,D,constraints,varargin)
%VB_CP_ALS Fits a Candecomp/PARAFAC (CP) tensor decomposition model to "X"
% with "D" components (rank) and subject to the supplied "constraints".
% INPUTS:
% There are 3 required inputs:
%   X:              A tensor (2nd order or higher) with the observed data.
%                       Missing values should be represented by NaN.
%   D:              The number of components (or rank) to be estimated.
%   constraints:    A cell(ndims(X),1) containing a string which specify
%                   the constraint on the corresponding mode. How to
%                   specify each constraint and the distribution of the
%                   factor is given below:
%
%       'normal'    The factor follows a multivariate normal distribution
%                   with one of the following priors:
%                       'constant'  Zero mean and unit covariance
%                       'scale'     Zero mean and isotropic covariance (precision follows a Gamma distribution)
%                       'ard'       Zero mean and diagonal covariance (each elements (columns) precision follows a Gamma distribution) 
%                       'wishart'   Zero mean and full covariance (the precision matrix (inverse covariance) follows a Wishart distribution 
%       'non-negative'
%                   Each element follows a univariate truncated normal
%                   distribution with one of the following priors:
%                       'constant', 'scale', 'ard'  (As defined for the normal)
%                       'sparse'    Zero mean and element specific precision (following a Gamma distribution)
%       'non-negative exponential'
%                   Each element follows a univariate exponential
%                   distribution, with one of the following priors:
%                   'constant', 'scale', 'ard', 'sparse  (As defined for "non-negative")
%       'orthogonal'  
%                   This factor follows a von Mises-Fisher matrix
%                   distribution, where the prior is uniform across the
%                   sphere (e.g. concentration matrix = 0).
%                       NOTE: It is not possible for the user to specify a
%                       prior for this distribution. Additionally, it is
%                       not possible to model missing elements when
%                       including orthogonal factors.
%       'infty'     
%                   Each element Follows a Uniform(0,1) distribution, which
%                   has no priors. 
%
%       Note:       If the same prior is specified on two or more modes, then the
%                   prior is shared (by default), e.g. 'normal ard' and
%                   'normal ard'. The prior can be made mode specific by
%                   appending 'individual' (or indi') when specifying the
%                   constraint, e.g. 'normal ard indi'.   
%       Note2:      For sparsity, the number of observations in the shared
%                   modes must be equal. 
%   varargin:   Passing optional input arguments
%      'conv_crit'      Convergence criteria, the algorithm stops if the
%                       relative change in lowerbound is below this value
%                       (default 1e-8). 
%      'maxiter'        Maximum number of iteration, stops here if
%                       convergence is not achieved (default 500).
%      'model_tau'      Model the precision of homoscedastic noise
%                       (default: true) 
%      'model_lambda'   Model the hyper-prior distributions on the factors
%                       (default: true) 
%      'fixed_tau'      Number of iterations before modeling noise
%                       commences (default: 10). 
%      'fixed_lambda'   Number of iterations before modeling hyper-prior
%                       distributions (default: 5).
%      'inference'      Defines how probabilistic inference should be
%                       performed (default: 'variational').
%      'noise'          A binary vector of length ndims(X). Where 0 is
%                       homoscedastic and 1 is heteroscedastic noise on the
%                       corresponding mode.
%      'init_factors'   A cell array with inital factors (first moment only).
%
% OUTPUTS:
%   'E_FACT':       Expected first moment of the distributions.
%   'E_FACT2':      Expected second moment of the distributions.
%   'E_Lambda':     Expected first moment of the hyper-prior distributions.
%   'Lowerbound':   The value of the evidience lowerbound at each
%                   iteration (for variational inference).
%   'model'         Distributions and lots of stuff... (currently mostly
%                   for debugging)
%
%% Initialize paths
if exist('./setup_paths.m')==2 && ~exist('FactorMatrixInterface.m')
    evalc('setup_paths');
end

%% Read input and Setup Parameters
paramNames = {'conv_crit', 'maxiter', ...
    'model_tau', 'fixed_tau', 'tau_a0', 'tau_b0',...
    'model_lambda', 'fixed_lambda', 'lambda_a0', 'lambda_b0'...
    'init_method','inference','noise','init_factors','impute missing',...
    'init_noise', 'fix_factors', 'fix_noise'};
defaults = {1e-8, 500, ...
    true , 10  , 1e-4, 1e-4,...
    true , 5 , 1e-4, 1e-4,...
	0, 'variational',false(ndims(X),1), [], false,[], [], []};
% Initialize variables to default value or value given in varargin
[conv_crit, maxiter, ...
    model_tau, fixed_tau, tau_alpha0, tau_beta0,...
    model_lambda, fixed_lambda, lambda_alpha0, lambda_beta0,...
    init_method, inference_scheme, hetero_noise_modeling, initial_factors,...
    usr_impute_missing, init_noise, dont_update_factor, dont_update_noise]...
    = internal.stats.parseArgs(paramNames, defaults, varargin{:});

% Check input is allowed (and sensible)
assert(ndims(X) == length(hetero_noise_modeling), ' Unknown noise modeling strategy')
assert(length(constraints) == ndims(X),...
    'The order of the data is not equal to the number of constraints.')
hetero_noise_modeling = logical(hetero_noise_modeling);

if D == 1
    % To avoid getting stuck in initial local optima (VB)
    fixed_lambda = 0;
    fixed_tau = 0;
else
    % The modeling delay time must be lower than the maximum number of iterations
    if maxiter <= fixed_lambda
        fixed_lambda=floor(maxiter/2);
    end
    if maxiter <= fixed_tau
        fixed_tau=floor(maxiter/2);
    end
end

if ~isempty(init_noise) && iscell(init_noise) && ~any(hetero_noise_modeling)
    error(['Homoscedastic noise was specified, but initial noise was specified',...
        ' as heteroscedastic.'])
end

% Check whether noise modeling is done and inform user.
if ~any(hetero_noise_modeling)
    fprintf('Homoscedastic noise modeling\n')
else
    fprintf('Heteroscedastic noise modeling on mode ')
    for i = find(hetero_noise_modeling)
        fprintf('%i, ',i)
    end
    fprintf('\n')
    if conv_crit < 1e-7
        warning('Heteroscedastic noise modeling may cause cost function to diverge, when tolerance is strict. Tolerence reduced to %4.2e',1e-7)
        conv_crit = 1e-7;
    end
end    

constraints = strtrim(constraints); % Remove leading and trailing whitespaces
inference_scheme = strtrim(inference_scheme);

% Determine how factor and noise inference should be performed.
[inference_scheme, noise_inference ] = processAndValidateInferenceSchemes(...
    inference_scheme, ndims(X) );
only_variational_inference = all(all(strcmpi('variational',inference_scheme)));
some_variables_are_sampled = any(any(strcmpi('sampling',inference_scheme)));
all_samples = cell(ndims(X)+1, 2);

%% Initialize the factor matrices and noise
R_obs=~isnan(X); % Set observed (true) or not observed (false) status.
has_missing_marg = ~all(R_obs(:));
impute_x = ~R_obs;  % find(~R_obs) gives the indices, but they require more space.

if has_missing_marg && usr_impute_missing
    impute_missing = true;
else
    impute_missing = false;
end

if impute_missing
   R_obs(:) = true; % Set to true to avoid any marginalization
   has_missing_marg = false;
else
    X(~R_obs)=0;
end

Nx=ndims(X); %Tensor order
N=size(X); %Elements in each dimension

% Initialize distributions according to the specified constraints
[factors, priors, shares_prior] = initializePriorDistributions(...
    N,D, has_missing_marg, ...
    constraints, inference_scheme, lambda_alpha0, lambda_beta0);

% Get relevant expected moments of the factors and setup X and R matricized
% for each mode. 
E_FACT = cell(Nx,1);
E_FACT2 = cell(Nx,1);
E_Contribution2FactorPrior = cell(Nx,1);
E_Lambda = cell(Nx,1);

if ~isempty(initial_factors)
    % #TODO: If fewer are specified, set the remaining to empty [].
    %       Additionally, the sizes could be checked.
    assert(length(initial_factors) == Nx,'Number of initial factors must be equal to the number of modes')
end

for i = 1:Nx  % Setup each factor
    
    init_E2 = false;
    % Initialize factor as specified by the user (if provided)
    if ~isempty(initial_factors) && ~isempty(initial_factors{i})
        
        if isobject(initial_factors{i}) ...
                && strcmp(class(initial_factors{i}),class(factors{i}))
            % FactorMatrix object passed
            factors{i} = initial_factors{i};
            priors{i} = factors{i}.hyperparameter; % !TODO Investigate what this call brakes!
            init_E2 = true;
            E_FACT2{i} = factors{i}.getExpSecondMoment();
        elseif (ismatrix(initial_factors{i}) && ~isobject(initial_factors{i}))...
                    || iscell(initial_factors{i})
            if iscell(initial_factors{i})  % First and second moment passed
                factors{i}.initialize(initial_factors{i}{1});
                E_FACT2{i} = initial_factors{i}{2};
                init_E2 = true;
            else
                factors{i}.initialize(initial_factors{i});
            end
        end
    end
    
    fprintf(factors{i}.getSummary()); fprintf('\n')
    
    % Get/initialize expected values
    E_FACT{i} = factors{i}.getExpFirstMoment();
    if ~init_E2
         E_FACT2{i} = E_FACT{i}'*E_FACT{i} + eye(D);
    end
    E_Lambda{i} = priors{i}.getExpFirstMoment();
    
end

if impute_missing
   % initial imputation
   X_recon = nmodel(E_FACT);
   X(impute_x) = X_recon(impute_x);
   clear X_recon
else
    X(~R_obs)=0;
end

f_unfold_i_to_j = @(data, un_idx, mat_idx) matricizing(unmatricizing(data,un_idx,N),mat_idx);
% for i = 1:Nx
%     Xm{i} = matricizing(X,i);
%     Rm{i} = matricizing(R_obs,i);
% 
%     %% TODO: This check never fails when imputing data, as empty fibers have been imputed above..
%     assert(all(sum(abs(Xm{i}),2)>0), 'One or more %i-mode fibers are entirely unobserved!', i)
% end

% Initializes elementwise second moment (possibly with pairwise interactions)
E_FACT2elementpairwise = cell(length(E_FACT),1);
for i = 1:Nx
   if has_missing_marg || hetero_noise_modeling(i)
        E_FACT2elementpairwise{i} = computeUnfoldedMoments(E_FACT{i},{[]});
    elseif my_contains(constraints{i},'sparse','IgnoreCase',true)
        E_FACT2elementpairwise{i} = E_FACT{i}.^2+1;
    else
        E_FACT2elementpairwise{i} = [];
    end
end

% Initialize Factor Contribution to Prior Updates 
for i = 1:Nx
   if my_contains(constraints{i},'sparse','IgnoreCase',true)
        E_Contribution2FactorPrior{i} = E_FACT2elementpairwise{i}; 
   else
        E_Contribution2FactorPrior{i} = E_FACT2{i};
   end
    
end

% Initialize noise (homo- or heteroscedastic)
if any(hetero_noise_modeling) % Does any modes have heteroscedastic noise
    %assert(~any(my_contains(constraints,'orth')), 'Heteroscedastic noise modelling is not supported in the presence of orthogonal factors.')
    assert(~any(my_contains(constraints,'orth') & hetero_noise_modeling), 'Heteroscedastic noise modelling is not supported on orthogonal factors.')
    
    noiseType = cell(Nx,1);
    Etau = cell(Nx,1);
    Eln_tau = cell(Nx,1);
    for i = 1:Nx
        if hetero_noise_modeling(i) % Mode-i has heteroscedastic noise
            noiseType{i} = GammaNoiseHeteroscedastic(...
                i, X,R_obs, tau_alpha0, tau_beta0, noise_inference);
                       
            % Initialize noise specified by user (if provided)
            if ~isempty(init_noise) && ~isempty(init_noise{i})
                if isobject(init_noise{i}) && strcmp(class(noiseType{i}), class(init_noise{i}))
                    noiseType{i} = init_noise{i};
                    
                elseif isvector(init_noise{i}) && ~isobject(init_noise{i})
                    noiseType{i}.noise_value = init_noise{i};
                    noiseType{i}.noise_log_value = log(init_noise{i});
                    
                end
            end
            Etau{i} = noiseType{i}.getExpFirstMoment();
            Eln_tau{i} = noiseType{i}.getExpLogMoment();
            
        else
            % These are only defined for convienience, and could be removed
            % entirely (if desired).
            Etau{i} = ones(N(i),1,'like',X);
            Eln_tau{i} = zeros(N(i),1,'like',X);
        end
    end
    i = find(hetero_noise_modeling); i=i(1);
    SST = noiseType{i}.SST;
    
else
    % Homoscedastic noise
    noiseType = GammaNoise(X,R_obs, tau_alpha0, tau_beta0, noise_inference);
    % Initialize noise specified by user (if provided)
    if ~isempty(init_noise)
        if isobject(init_noise) && strcmp(class(noiseType), class(init_noise))
            noiseType = init_noise;

        elseif isvector(init_noise) && ~isobject(init_noise)
            noiseType.noise_value = init_noise;
            noiseType.noise_log_value = log(init_noise);

        end
    end
    Etau = noiseType.getExpFirstMoment();
    SST = noiseType.getSST();
end

%% Variables for diagnostics.... more to come
lambda_dev = zeros(D,maxiter);

%% If any factors are infinity normed, then run a single update of all factors
if any(my_contains(constraints, {'infi','orthogonal'}, 'IgnoreCase', true))
    
    infty_idx = my_contains(constraints, {'infi','orthogonal'}, 'IgnoreCase', true);
    for i = [find(~infty_idx), ...  % First update all non-infty factors
            find(infty_idx)]        % Second update all infty factors
%         factors{i}.updateFactor(i, matricizing(X,i), matricizing(R_obs,i), [], E_FACT, E_FACT2, E_FACT2elementpairwise, Etau)
        factors{i}.updateFactor(i, matricizing(X,i), matricizing(R_obs,i), [], [], E_FACT, E_FACT2, E_FACT2elementpairwise, Etau) 
                
        E_FACT{i} = factors{i}.getExpFirstMoment();
        E_FACT2{i} = factors{i}.getExpSecondMoment();
        if has_missing_marg || hetero_noise_modeling(i)
            E_FACT2elementpairwise{i} = factors{i}.getExpElementwiseSecondMoment();
        elseif my_contains(constraints{i},'sparse','IgnoreCase',true)
            E_FACT2elementpairwise{i} = factors{i}.getExpSecondMomentElem();
        else
            E_FACT2elementpairwise{i} = [];
        end
    end
end

%% Setup how information should be displayed.
disp([' '])
disp(['Probabilistic Candecomp/PARAFAC (CP) Decomposition'])        %TODO: Better information about what is running..
disp(['A ' num2str(D) ' component model will be fitted']);
disp([' '])
disp(['To stop algorithm press control C'])
disp([' ']);
dheader = sprintf(' %16s | %16s | %16s | %16s | %16s | %16s | %16s |','Iteration', ...
    'Cost', 'rel. \Delta cost', 'Noise (s.d.)', 'Var. Expl.', 'Time (sec.)', 'Time CPU (sec.)');
dline = repmat('------------------+',1,7);

%% Start Inference Procedure (Optimization, Sampling, or both)
iter = 0;
old_cost = -inf;
delta_cost = inf;
Lowerbound = zeros(maxiter,1,'like', SST);
rmse = zeros(maxiter,1,'like', SST);
Evarexpl = zeros(maxiter,1,'like', SST);
total_realtime = tic;
total_cputime = cputime;

fprintf('%s\n%s\n%s\n',dline, dheader, dline);
X = matricizing(X,1);
R = matricizing(R_obs,1);
i_mode_unfolded = 1;

while delta_cost>=conv_crit && iter<maxiter || ...
        (iter <= fixed_lambda) || (iter <= fixed_tau)
    iter = iter + 1;
    time_tic_toc = tic;
    time_cpu = cputime;
    
    %% Update factor matrices (one at a time)
    for i = 1:Nx % IDEA: Consider randomizing the order, i.e. i = randperm(Nx)
        
        % Update factor distribution parameters
        if isempty(dont_update_factor) || ~dont_update_factor(i)
            X = f_unfold_i_to_j(X,i_mode_unfolded,i);
            R = f_unfold_i_to_j(R,i_mode_unfolded,i);
            i_mode_unfolded = i;

            factors{i}.updateFactor(i, X, R, [], [], E_FACT, E_FACT2, E_FACT2elementpairwise, Etau) 
        end
        
        % Get the expected value (sufficient statistics)
        if hetero_noise_modeling(i)
            E_FACT{i} = factors{i}.getExpFirstMoment(Etau{i});
            E_FACT2{i} = factors{i}.getExpSecondMoment(Etau{i});
        else
            E_FACT{i} = factors{i}.getExpFirstMoment();
            E_FACT2{i} = factors{i}.getExpSecondMoment();
        end
        E_Contribution2FactorPrior{i} = factors{i}.getContribution2Prior();

        % Calculate the expected second moment between pairs (missing,
        % noise modeling) or each element (sparsity) or not at all. 
        % - TODO: If only unimodal factors, then only the exp. elem. moment
        %         is needed (not pairs)..
        if has_missing_marg || hetero_noise_modeling(i) % add or all factors are univariate (for space)
            E_FACT2elementpairwise{i} = factors{i}.getExpElementwiseSecondMoment(); 
        elseif my_contains(constraints{i},'sparse','IgnoreCase',true)
            E_FACT2elementpairwise{i} = factors{i}.getExpSecondMomentElem(); 
        else
            E_FACT2elementpairwise{i} = [];
        end
        
        % Updates local (factor specific) prior (hyperparameters)
        if model_lambda && iter > fixed_lambda && ~shares_prior(i)...
                && (isempty(dont_update_factor) || ~ dont_update_factor(i))
            factors{i}.updateFactorPrior(E_Contribution2FactorPrior{i})
            E_Lambda{i} = priors{i}.getExpFirstMoment();
        end
        
    end
    
    % Calculate ELBO/cost contribution
    cost = 0;
    for i = 1:Nx
        if ~shares_prior(i)
            cost = cost + factors{i}.calcCost()...
                + priors{i}.calcCost();
            assert(isreal(cost))
        end
    end
    
    %% Updates shared priors (hyperparameters)
    if any(shares_prior)
        for j = unique(nonzeros(shares_prior(:)))'
            shared_idx = find(shares_prior == j)';
            fsi = shared_idx(1);
       
%             assert(isempty(dont_update_factor) ||...
%                 all(~dont_update_factor(shared_idx)),...
%                 'Trying to update shared prior on a fixed factor.. This is not handled atm.')
            
            if model_lambda && iter > fixed_lambda && ...
                    (isempty(dont_update_factor) ||...
                    all(~dont_update_factor(shared_idx)))
                % Update shared prior
                distr_constr = 0.5*ones(length(shared_idx),1); % Normal or truncated normal
                distr_constr(my_contains(constraints(shared_idx),'expo','IgnoreCase',true)) = 1;
                factors{fsi}.updateFactorPrior(E_Contribution2FactorPrior(shared_idx), distr_constr);
            end
            
            %Get cost for the shared prior and each factor.
            cost = cost + priors{fsi}.calcCost();
            for f = shared_idx
                cost = cost+factors{f}.calcCost();
                E_Lambda{f} = priors{f}.getExpFirstMoment();
                
                assert(all(all(E_Lambda{fsi} == E_Lambda{f})), 'Error, shared prior is not shared');
            end
        end
    end
    
    %% Updates global hyperparameters
    % if any?
    if impute_missing
        % Impute new values
        X_recon = nmodel(E_FACT);  % Dont reconstruct explicitly, if few values.
        X = unmatricizing(X,i_mode_unfolded,N);
        X(impute_x) = X_recon(impute_x);
        clear X_recon
        X = matricizing(X,i_mode_unfolded);
%         for i = 1:Nx
%             Xm{i} = matricizing(X,i);
%         end
        % Technically not corrected as <x_miss.^2> is wrong.. (missing variance term..)
        if ~any(hetero_noise_modeling)
            SST = sum(X(:).^2); 
        noiseType.SST = SST;
        end
        
        % Calculate prior contribution?
        % - Is this already in SSE??
    end
    
    
    %% Update noise precision
    if any(hetero_noise_modeling) % Heteroscedastic noise (mode specific)
        
        if isempty(dont_update_noise) % Specified by user
            idx = find(hetero_noise_modeling); 
        else
            idx = find(hetero_noise_modeling(:) .* ~dont_update_noise(:));
        end
        
        if isempty(idx) % Need a mode for calculating SSE og loglike
            noise_final_mode = find(hetero_noise_modeling,1);
        else
            noise_final_mode = idx(end);
        end
        
        for i = idx(:)'
            X = f_unfold_i_to_j(X,i_mode_unfolded,i);
            R = f_unfold_i_to_j(R,i_mode_unfolded,i);
            i_mode_unfolded = i;
            
            if model_tau && iter > fixed_tau
                % Update each heteroscedastic noise mode
                noiseType{i}.updateNoise(X,R, E_FACT, E_FACT2, E_FACT2elementpairwise, Etau);
                Etau{i} = noiseType{i}.getExpFirstMoment();
                Eln_tau{i} = noiseType{i}.getExpLogMoment();
                E_FACT{i} = factors{i}.getExpFirstMoment(Etau{i});
                E_FACT2{i} = factors{i}.getExpSecondMoment(Etau{i});

            elseif i == noise_final_mode
                % Don't update the noise, but calculate SSE
                noiseType{noise_final_mode}.calcSSE(...
                    X,R,...
                    E_FACT, E_FACT2, E_FACT2elementpairwise, Etau);
            end
            
            if i ~= noise_final_mode
               cost = cost + noiseType{i}.calcPriorAndEntropy(); 
            end
        end
        SSE = noiseType{noise_final_mode}.getSSE();
        SST = noiseType{noise_final_mode}.SST;
        
        % Cost contribution from the likelihood
        % - calculated for the "noise_final_mode", but includes a
        %   correction for all other modes (i.e. log(det(..)) )
        % - TODO: Use smart method from "CoreArrayNormal.getLogPrior()". It
        %           should work for full observed data.
        idx = 1:Nx; idx(noise_final_mode) = [];
        ldnp = Eln_tau{idx(1)};
        for i = idx(2:end)
            ldnp = krsum(Eln_tau{i}, ldnp); % TODO: Ignore modes with no noise
        end
        ldnp = R*ldnp;
        cost = cost + noiseType{noise_final_mode}.calcCost(ldnp);

    else % Homoscedastic noise
        X = f_unfold_i_to_j(X,i_mode_unfolded,1);
        R = f_unfold_i_to_j(R,i_mode_unfolded,1);
        i_mode_unfolded = 1;
        
        if model_tau && iter > fixed_tau
            noiseType.updateNoise(X,R, E_FACT, E_FACT2, E_FACT2elementpairwise);
            Etau = noiseType.getExpFirstMoment();
        else
            noiseType.calcSSE(X,R, E_FACT, E_FACT2, E_FACT2elementpairwise);
        end
        SSE = noiseType.getSSE();
        
        % Cost contribution from the likelihood
        cost = cost + noiseType.calcCost();
    end
    
    assert(isreal(cost), 'Cost was not a real number!')
    delta_cost = (cost-old_cost)/abs(cost);
    
    Lowerbound(iter) = cost;
    rmse(iter) = sum(SSE);
    Evarexpl(iter) = 1-sum(SSE)/sum(SST);
    old_cost = cost;
    
    %% Display
    if mod(iter,100)==0
        fprintf('%s\n%s\n%s\n',dline, dheader, dline);
    end
    
    if mod(iter,1)==0
        time_tic_toc = toc(time_tic_toc);
        time_cpu = cputime-time_cpu;
        
        if any(hetero_noise_modeling)
            fprintf(' %16i | %16.4e | %16.4e | %16.4e | %16.4f | %16.4f | %16.4f |\n',...
                            iter, cost, delta_cost, 1/sqrt(median(cat(1,Etau{hetero_noise_modeling}))), Evarexpl(iter), time_tic_toc,...
                            time_cpu);

        else
            fprintf(' %16i | %16.4e | %16.4e | %16.4e | %16.4f | %16.4f | %16.4f |\n',...
            iter, cost, delta_cost, sqrt(1./Etau), Evarexpl(iter), time_tic_toc, time_cpu);
        end
    end
    
    %% Check update was valid (Only works if ALL inference is variational)
    % delta_cost is only garanteed to be positive for variational
    % inference, so for sampling, it should just keep going until the
    % change is low enough.
    if only_variational_inference && ~usr_impute_missing
        [~, c_fixed_lambda, c_fixed_tau] = isElboDiverging(...
            iter, delta_cost, conv_crit,...
            {'hyperprior (lambda)', model_lambda, fixed_lambda},...
            {'noise (tau)', model_tau, fixed_tau});
        fixed_lambda = min(fixed_lambda, c_fixed_lambda);
        fixed_tau = min(fixed_tau, c_fixed_tau);
    else
        delta_cost = abs(delta_cost);
    end
    
    %% Save samples
    if some_variables_are_sampled
        for i = 1:Nx
            if strcmpi(inference_scheme{i,1},'sampling')
                all_samples{i,1}(:,:,maxiter-iter+1) = E_FACT{i}; % factor
            end
            
            if strcmpi(inference_scheme{i,2},'sampling') && ~isempty(E_Lambda{i})
                all_samples{i,2}(:,:,maxiter-iter+1) = E_Lambda{i}; % precision prior
            end
        end
        if strcmpi(noise_inference, 'sampling')
            if any(hetero_noise_modeling)
                all_samples{end,1}(:,maxiter-iter+1) = cat(1,Etau{:}); % noise
            else
                all_samples{end,1}(maxiter-iter+1) = Etau; % noise
            end
        end
    end
    %% Save some stuff for diagnostics.
    if all(size(E_Lambda{2}(:))==[D,1])
        lambda_dev(:,iter) = E_Lambda{2}(:);
    end
    
    %% If components are pruned, what should happen?
    % - fix their contribution and reduce D?
    % - try sampling to get them back?
    % - other ideas...
    
end
total_realtime = toc(total_realtime);
total_cputime = cputime-total_cputime;

fprintf('Total realtime: %6.4f sec.\nTotal CPU time: %6.4f sec.\n',total_realtime,total_cputime)

%% Algorithm completed, now finalize function output.
Lowerbound(iter+1:end)=[];
%TODO: Fix fliped signs when modelling two orthogonal factors...
% B = td_y{end-1,1}; 
% B_org = B;
% 
% orth_sign = sign(diag(B{1}'*B{2})');
% orth_sign(orth_sign==0) = 1; % Do not zero out components (though they probably are zero already..)
% B{2} = bsxfun(@times, B{2},orth_sign);
% B{end} = bsxfun(@times, B{end}, orth_sign);
% 
% X_recon = nmodel(B);
% X_recon2 = nmodel(B_org);
% 
% rms(X_recon(:)-X_recon2(:))

% if nargout > 3 % TODO: Investigate if evalc('') does not provide nargout.
   model.factors = factors;
   model.priors = priors;
   model.noise = noiseType;
   model.shares_prior = shares_prior;
   model.cost = Lowerbound;
   model.rmse = rmse;
   model.varexpl = Evarexpl;
   model.SST = SST;
   model.realtime = total_realtime;
   model.cputime = total_cputime;
   model.lambda_dev = lambda_dev;
% end

if any(hetero_noise_modeling)
    for i = 1:Nx
        E_FACT{i} = factors{i}.getExpFirstMoment();
        E_FACT2{i} = factors{i}.getExpSecondMoment();
    end
end

fprintf('Algorithm ran to completion\n')