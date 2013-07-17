function [beta0_final,beta_final,beta_scale,glmstats] = ...
    kruskal_sparsereg(X,M,y,r,dist,lambda,pentype,penparam,varargin)
% KRUSKAL_SPARSEREG  Rank-r GLM sparse Kruskal regression
%
% [BETA0,BETA,BETA_SCALE,GLMSTATS] =
% KRUSKAL_SPARSEREG(X,M,Y,R,DIST,LAMBDA,PENTYPE,PENPARAM) fits the sparse
% Kruskal tensor regression using penalty PENTYPE at fixed tuning paramete
% value LAMBDA.
%
%   INPUT:
%       X: n-by-p0 regular covariate matrix
%       M: array variates (or tensors) with dim(M) = [p1,p2,...,pd,n]
%       y: n-by-1 respsonse vector
%       r: rank of tensor regression
%       dist: 'binomial'|'normal'|'poisson'
%       lambda: penalty tuning constant
%       pentype: 'enet'|'log'|'mcp'|'power'|'scad'
%       penparam: the index parameter for the pentype
%
%   Optional input name-value pairs:
%       'BurninMaxIter': Max. iter. for the burn-in runs, default is 20
%       'BurninTolFun': Tolerance for the burn-in runs, default is 1e-2
%       'BurninReplicates': Number of the burn-in runs, default is 5
%       'Display': 'off' (default) | 'iter'
%       'PenaltyMaxIter': Max. iters. at penalization stage, default is 50
%       'PenaltyTolFun': Tolerence at penalization stage, default is 1e-3
%       'weights': observation weights, default is ones for each obs.
%
%   OUTPUT:
%       beta0_final: regression coefficients for the regular covariates
%       beta_final: a tensor of regression coefficientsn for array variates
%       beta_scale: a tensor of the scaling constants for the array
%           coefficients
%       glmstats: GLM statistics from the last fitting of the regular
%           covariates
%
% Reference
%   H Zhou, L Li, and H Zhu (2013) Tensor regression with applications in
%   neuroimaging data analysis, JASA 108(502):540-552
%
% TODO
%
% COPYRIGHT 2011-2013 North Carolina State University
% Hua Zhou (hua_zhou@ncsu.edu) and Lexin Li

% parse inputs
argin = inputParser;
argin.addRequired('X', @isnumeric);
argin.addRequired('M', @(x) isa(x,'tensor') || isnumeric(x));
argin.addRequired('y', @isnumeric);
argin.addRequired('r', @isnumeric);
argin.addRequired('dist', @(x) ischar(x));
argin.addRequired('lambda', @(x) isnumeric(x) && x>=0);
argin.addRequired('pentype', @ischar);
argin.addRequired('penparam', @isnumeric);
argin.addParamValue('Display', 'off', @(x) strcmp(x,'off')||strcmp(x,'iter'));
argin.addParamValue('BurninMaxIter', 20, @(x) isnumeric(x) && x>0);
argin.addParamValue('BurninTolFun', 1e-2, @(x) isnumeric(x) && x>0);
argin.addParamValue('BurninReplicates', 5, @(x) isnumeric(x) && x>0);
argin.addParamValue('PenaltyMaxIter', 50, @(x) isnumeric(x) && x>0);
argin.addParamValue('PenaltyTolFun', 1e-3, @(x) isnumeric(x) && x>0);
argin.addParamValue('weights', [], @(x) isnumeric(x) && all(x>=0));
argin.parse(X,M,y,r,dist,lambda,pentype,penparam,varargin{:});

Display = argin.Results.Display;
BurninMaxIter = argin.Results.BurninMaxIter;
BurninTolFun = argin.Results.BurninTolFun;
BurninReplicates = argin.Results.BurninReplicates;
PenaltyMaxIter = argin.Results.BurninMaxIter;
PenaltyTolFun = argin.Results.PenaltyTolFun;
wts = argin.Results.weights;
if (isempty(wts))
    wts = ones(size(X,1),1);
end

% check validity of rank r
if (isempty(r))
    r = 1;
end

% decide least squares or GLM model
if (strcmpi(dist,'normal'))
    isglm = false;
else
    isglm = true;
    % translate to model specifier for sparse regression
    if (strcmpi(dist,'binomial'))
        glmmodel = 'logistic';
    elseif (strcmpi(dist,'poisson'))
        glmmodel = 'loglinear';
    end
end

% check dimensions
[n,p0] = size(X);
d = ndims(M)-1; % dimension of array variates
p = size(M);    % sizes array variates
if (p(end)~=n)
    error('tensorreg:kruskal_sparsereg:dim', ...
        'dimension of M does not match that of X!');
end

% convert M into a tensor T
TM = tensor(M);

% turn off warnings
warning('off','stats:glmfit:IterationLimit');
warning('off','stats:glmfit:BadScaling');
warning('off','stats:glmfit:IllConditioned');

% if space allowing, pre-compute mode-d matricization of TM
if (strcmpi(computer,'PCWIN64') || strcmpi(computer,'PCWIN32'))
    iswindows = true;
    % memory function is only available on windows !!!
    [dummy,sys] = memory; %#ok<ASGLU>
else
    iswindows = false;
end
% CAUTION: may cause out of memory on Linux
if (~iswindows || d*(8*prod(size(TM)))<.75*sys.PhysicalMemory.Available) %#ok<PSIZE>
    Md = cell(d,1);
    for dd=1:d
        Md{dd} = double(tenmat(TM,[d+1,dd],[1:dd-1 dd+1:d]));
    end
end

% Burn-in stage (loose convergence criterion)
if (~strcmpi(Display,'off'))
    display(' ');
    display('==================');
    display('Burn-in stage ...');
    display('==================');
end
[dummy,beta_burnin] = ...
    kruskal_reg(X,M,y,r,dist,'MaxIter',BurninMaxIter,'TolFun',BurninTolFun,...
    'Replicates',BurninReplicates,'weights',wts); %#ok<ASGLU>

% penalization stage
if (~strcmpi(Display,'off'))
    display(' ');
    display('==================');
    display('Penalization stage');
    display('==================');
end
glmstats = cell(1,d+1);
dev0 = inf;
beta = beta_burnin;
for iter = 1:PenaltyMaxIter
    % update regular covariate coefficients
    if (iter==1)
        eta = double(tenmat(TM,d+1)*tenmat(beta,1:d));
    else
        eta = Xj*betatmp(1:end-1);
    end
    [betatmp,devtmp,glmstats{d+1}] = glmfit_priv([X,eta],y,dist,'constant','off', ...
        'weights',wts);
    beta0 = betatmp(1:p0);
    % stopping rule
    diffdev = devtmp-dev0;
    dev0 = devtmp;
    if (abs(diffdev)<PenaltyTolFun*(abs(dev0)+1))
        break;
    end
    % update scale of array coefficients and standardize
    beta = arrange(beta*betatmp(end));
    for j=1:d
        beta.U{j} = bsxfun(@times,beta.U{j},(beta.lambda').^(1/d));
    end
    beta.lambda = ones(r,1);
    % cyclic update of array regression coefficients
    eta0 = X*beta0;
    for j=1:d
        if (j==1)
            cumkr = ones(1,r);
        end
        if (exist('Md','var'))
            if (j==d)
                Xj = reshape(Md{j}*cumkr,n,p(j)*r);
            else
                Xj = reshape(Md{j}*khatrirao([beta.U(d:-1:j+1),cumkr]),...
                    n,p(j)*r);
            end
        else
            if (j==d)
                Xj = reshape(double(tenmat(TM,[d+1,j]))*cumkr, ...
                    n,p(j)*r);
            else
                Xj = reshape(double(tenmat(TM,[d+1,j])) ...
                    *khatrirao({beta.U{d:-1:j+1},cumkr}),n,p(j)*r);
            end
        end
        if (isglm)
%             betatmp = glm_sparsereg([Xj,eta0],y,lambda,glmmodel,'weights',wts,...
%                 'x0',[beta{j}(:);0],'penidx',[true(1,p(j)*r),false],...
%                 'penalty',pentype,'penparam',penparam);
            betatmp = glm_sparsereg([Xj,eta0],y,lambda,glmmodel,'weights',wts,...
                'penidx',[true(1,p(j)*r),false],...
                'penalty',pentype,'penparam',penparam);

        else
            betatmp = lsq_sparsereg([Xj,eta0],y,lambda,'weights',wts,...
                'x0',[beta{j}(:);0],'penidx',[true(1,p(j)*r),false],...
                'penalty',pentype,'penparam',penparam);
        end
        beta{j} = reshape(betatmp(1:end-1),p(j),r);
        eta0 = eta0*betatmp(end);
        cumkr = khatrirao(beta{j},cumkr);
    end
    
    if (~strcmpi(Display,'off'))
        disp(' ');
        disp(['  iterate: ' num2str(iter)]);
        disp([' deviance: ' num2str(dev0)]);
        disp(['    beta0: ' num2str(beta0')]);
    end
end
beta0_final = beta0;
beta_final = beta;

% turn off warnings
warning('off','stats:glmfit:IterationLimit');
warning('off','stats:glmfit:BadScaling');
warning('off','stats:glmfit:IllConditioned');
if (~strcmpi(Display,'off'))
    display(' ');
    display('==================');
    display('Scaling stage');
    display('==================');
end

% find a scaling for the estimates
beta_scale = ktensor(arrayfun(@(j) zeros(p(j),r), 1:d, ...
    'UniformOutput',false));
eta0 = X*beta0;
for j=1:d
    idxj = 1:d;
    idxj(j) = [];
    if (exist('Md','var'))
        Xj = reshape(Md{j}*khatrirao(beta.U(idxj(end:-1:1))),n,p(j)*r);
    else
        Xj = reshape(double(tenmat(TM,[d+1,j])) ...
            *khatrirao(beta.U(idxj(end:-1:1))),n,p(j)*r);
    end
    [~,~,glmstats{d}] = glmfit_priv([Xj,eta0],y,dist,'constant','off');
    beta_scale{j} = reshape(glmstats{d}.se(1:end-1),p(j),r);
end

% output the BIC
cutoff = 1e-8;
if (d==2)
    glmstats{d+1}.BIC = dev0 + log(n)*max(nnz(abs(beta.U{1})>cutoff) ...
        +nnz(abs(beta.U{2})>cutoff)-r*r,0);
else
    glmstats{d+1}.BIC = dev0 + log(n)* ...
        max(sum(arrayfun(@(j) nnz(beta.U{j}), 1:d, 'UniformOutput',true)) ...
        -r*(d-1),0);
end

% say goodbye
if (~strcmpi(Display,'off'))
    disp(' ');
    disp(' DONE!');
    disp(' ');
end

warning on all;

end