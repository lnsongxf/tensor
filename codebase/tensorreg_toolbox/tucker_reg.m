function [beta0_final,beta_final,glmstats_final,dev_final] = ...
    tucker_reg(X,M,y,r,dist,varargin)
% TUCKER_REG Fit rank-r Tucker tensor regression
%
% INPUT:
%   X - n-by-p0 regular covariate matrix
%   M - array variates (or tensors) with dim(M) = [p1,p2,...,pd,n]
%   y - n-by-1 respsonse vector
%   r - d-by-1 ranks of Tucker tensor regression
%   dist - 'binomial', 'gamma', 'inverse gaussian','normal', or 'poisson'
%
% Output:
%   beta0_final - regression coefficients for the regular covariates
%   beta_final - a tensor of regression coefficientsn for array variates
%   glmstats_final - GLM regression summary statistics for regular
%       covariates

% COPYRIGHT: North Carolina State University
% AUTHOR: Hua Zhou (hua_zhou@ncsu.edu)

% parse inputs
argin = inputParser;
argin.addRequired('X', @isnumeric);
argin.addRequired('M', @(x) isa(x,'tensor') || isnumeric(x));
argin.addRequired('y', @isnumeric);
argin.addRequired('r', @isnumeric);
argin.addRequired('dist', @(x) ischar(x));
argin.addParamValue('Display', 'off', @(x) strcmp(x,'off')||strcmp(x,'iter'));
argin.addParamValue('MaxIter', 100, @(x) isnumeric(x) && x>0);
argin.addParamValue('TolFun', 1e-4, @(x) isnumeric(x) && x>0);
argin.addParamValue('Replicates', 5, @(x) isnumeric(x) && x>0);
argin.addParamValue('weights', [], @(x) isnumeric(x) && all(x>=0));
argin.parse(X,M,y,r,dist,varargin{:});

Display = argin.Results.Display;
MaxIter = argin.Results.MaxIter;
TolFun = argin.Results.TolFun;
Replicates = argin.Results.Replicates;
wts = argin.Results.weights;

% check validity of rank r
if (isempty(r))
    error('need to input the d-by-1 rank vector!');
elseif (any(r==0))
    [beta0_final,dev_final,glmstats_final] = ...
        glmfit_priv(X,y,dist,'constant','off','weights',wts);
    beta_final = 0;
    return;
elseif (size(r,1)==1 && size(r,2)==1)
    r = repmat(r,1,ndims(M)-1);
end

% check dimensions
[n,p0] = size(X);
d = ndims(M)-1; % dimension of array variates
p = size(M);    % sizes of array variates
if (n~=p(end))
    error('sample size in X dose not match sample size in M');
end
if (n<p0 || n<max(r.*p(1:end-1)))    
    error('sample size n is not large enough to estimate all parameters!');
end

% turn off warnings
warning('off','stats:glmfit:IterationLimit');
warning('off','stats:glmfit:BadScaling');
warning('off','stats:glmfit:IllConditioned');

% pre-allocate variables
glmstats = cell(1,d+2);
dev_final = inf;

% convert M into a tensor T (if it's not)
TM = tensor(M);

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
Mn = double(tenmat(TM,d+1,1:d));    % n-by-prod(p)

% loop over replicates
for rep=1:Replicates
    
    % initialize tensor regression coefficients from uniform [-1,1]
    beta = ttensor(tenrand(r),arrayfun(@(j) 1-2*rand(p(j),r(j)), 1:d, ...
        'UniformOutput',false));
    
    % main loop
    for iter=1:MaxIter
        % update coefficients for the regular covariates
        if (iter==1)
            [beta0, dev0] = glmfit_priv(X,y,dist,'constant','off',...
                'weights',wts);
        else
            eta = Xcore*betatmp(1:end-1);
            [betatmp,devtmp,glmstats{d+2}] = ...
                glmfit_priv([X,eta],y,dist,'constant','off','weights',wts);
            beta0 = betatmp(1:p0);
            diffdev = devtmp-dev0;
            dev0 = devtmp;
            % stopping rule
            if (abs(diffdev)<TolFun*(abs(dev0)+1))
                break;
            end
            % update scale of array coefficients and standardize
            for j=1:d
                colnorms = sqrt(sum(beta.U{j}.^2,1));
                if any(colnorms==0)
                    warning('tuckerreg:degenerateU', ...
                        'zero columns of beta.U found');
                    colnorms(colnorms==0) = 1;
                end
                beta.U{j} = bsxfun(@times,beta.U{j},1./colnorms);
                beta.core = ttm(beta.core,diag(colnorms),j);
            end
            beta.core = beta.core*betatmp(end);
        end
        eta0 = X*beta0;
        % cyclic update of the array coefficients
        for j=1:d
            if (j==1)
                cumkron = 1;
            end
            if (exist('Md','var'))
                % need to optimize the computation!
                if (j==d)
                    Xj = reshape(Md{j}*cumkron...
                        *double(tenmat(beta.core,j))', n, p(j)*r(j));                    
                else
                    Xj = reshape(Md{j}...
                        *arraykron([beta.U(d:-1:j+1),cumkron])...
                        *double(tenmat(beta.core,j))', n, p(j)*r(j));
                end
            else
                if (j==d)
                    Xj = reshape(double(tenmat(TM,[d+1,j]))*cumkron...
                        *double(tenmat(beta.core,j))', n, p(j)*r(j));                    
                else
                    Xj = reshape(double(tenmat(TM,[d+1,j])) ...
                        *arraykron([beta.U(d:-1:j+1),cumkron])...
                        *double(tenmat(beta.core,j))', n, p(j)*r(j));
                end
            end
            [betatmp,devtmp,glmstats{j}] = ...
                glmfit_priv([Xj,eta0],y,dist,'constant','off','weights',wts); %#ok<ASGLU>
            beta{j} = reshape(betatmp(1:end-1),p(j),r(j));
            eta0 = eta0*betatmp(end);
            cumkron = kron(beta{j},cumkron);
        end
        % update the core tensor
        Xcore = Mn*cumkron; % n-by-prod(r)
        [betatmp,devtmp,glmstats{d+1}] = ...
            glmfit_priv([Xcore,eta0],y,dist,'constant','off','weights',wts); %#ok<ASGLU>
        beta.core = tensor(betatmp(1:end-1),r);
    end
    
    % record if it has a smaller deviance
    if (dev0<dev_final)
        beta0_final = beta0;
        beta_final = beta;
        glmstats_final = glmstats;
        dev_final = dev0;
        glmstats_final{d+2}.BIC = dev_final ...
            + log(n)*(sum(p(1:end-1).*r)+prod(r)-sum(r.^2)+p0);
    end
    
    if (strcmpi(Display,'iter'))
        disp(' '); disp(' ');
        disp(['replicate: ' num2str(rep)]);
        disp([' iterates: ' num2str(iter)]);
        disp([' deviance: ' num2str(dev0)]);
        disp(['    beta0: ' num2str(beta0')]);
    end
    
end
warning on all;

    function X = arraykron(U)
        %ARRAYKRON Kronecker product of matrices in an array
        %   AUTHOR: Hua Zhou (hua_zhou@ncsu.edu)
        X = U{1};
        for i=2:length(U)
            X = kron(X,U{i});
        end
    end

    function X = kron(A,B)
        %KRON Kronecker product.
        %   kron(A,B) returns the Kronecker product of two matrices A and B, of
        %   dimensions I-by-J and K-by-L respectively. The result is an I*J-by-K*L
        %   block matrix in which the (i,j)-th block is defined as A(i,j)*B.
        
        %   Version: 03/10/10
        %   Authors: Laurent Sorber (Laurent.Sorber@cs.kuleuven.be)
        
        [I J] = size(A);
        [K L] = size(B);
        if ~issparse(A) && ~issparse(B)
            A = reshape(A,[1 I 1 J]);
            B = reshape(B,[K 1 L 1]);
            X = reshape(bsxfun(@times,A,B),[I*K J*L]);
        else
            [ia,ja,sa] = find(A);
            [ib,jb,sb] = find(B);
            ix = bsxfun(@plus,K*(ia-1).',ib);
            jx = bsxfun(@plus,L*(ja-1).',jb);
            if islogical(sa) && islogical(sb)
                X = sparse(ix,jx,bsxfun(@and,sb,sa.'),I*K,J*L);
            else
                X = sparse(ix,jx,double(sb)*double(sa.'),I*K,J*L);
            end
        end
    end

end