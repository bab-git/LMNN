function [L,Det]=lmnn_dist(Dist_raw,y,L0,pars)
% Input:
%
% Dist_raw = matrix of pairwise distances per dimension
% y = labels
%
% Important Parameters:
% diagonal = (default false) If set to true, a diagonal matrix is learned
% stepsize = (default 1e-09)
% outdim = (default: size(x,1)) output dimensionality
% maxiter = maximum number of iterations (default: 1000)
% validation = (def 0) fraction of data used as validation
%               (e.g. 0.2 means 20% of the training data is used as val)
% validationstep = (def 15) every "valcount" steps do validation
% quiet = {0,1} surpress output (default=0)
% mu = must be within (0,1) - tradeoff between loss and regularizer (default mu=0.5)
% subsample = (default 0.1) percentage of constraints that are subsampled (set to 1 for exact solution)
%
% Specific parameters (for experts only):
% correction = (def 15) how many steps between each update
%              The number of impostors are fixed for until next "correction"
% factor = (def 1.1) multiplicative factor by which the
%         "correction" gab increases
% obj = (def 1) if 1, solver solves in L, if 0, solver solves in L'*L
% thresho = (def 1e-9) cut off for change in objective function (if
%           improvement is less, stop)
% thresha = (def 1e-22) cut off for stepsize, if stepsize is
%           smaller stop
% scale = (def. 0) if 1, all data gets re-scaled s.t. average
%         distance to closest neighbor is 1
%
%
% Output:
%
% L = linear transformation xnew=L*x
%
% Det.obj = objective function over time
% Det.nimp = number of impostors over time
% Det.pars = all parameters used in run
% Det.time = time needed for computation
% Det.iter = number of iterations
% Det.verify = verify (results of validation - if used)
%=================================

if(nargin==0)
    help lmnn;
    return;
end;

if ~exist('pars')
    error('The input parameters are not set correctly')
end

tic

if(size(Dist_raw,3)>length(L0)) error('data and L must have matching dimensions!\n');end;
if size(y,1)>size(y,2) y=y'; end
%=== parameters setting
pars.diagonal=0;
if ~isfield(pars,'stepsize')
    pars.stepsize=1e-09;
end
pars.minstepsize=0;
pars.tempid=-1;
if ~isfield(pars,'maxiter')
    pars.maxiter=3000;
end
pars.factor=1.1;
pars.correction=15;
pars.thresho=1e-7;
pars.thresha=1e-22;
pars.ifraction=1;
if ~isfield(pars,'scale')
    pars.scale=1;
end
pars.obj=1;
if ~isfield(pars,'quiet')
    pars.quiet=0;
end
if ~isfield(pars,'classsplit')
    pars.classsplit=0;
end
if ~isfield(pars,'validation')
    pars.validation=0;
end
if ~isfield(pars,'validation_')
    pars.validation_=0;
end
pars.validationstep=50;
pars.earlystopping=15;
pars.valrand=1;

pars.aggressive=0;
pars.stepgrowth=1.01;
pars.mu=0.5;
pars.maximp=100000;
pars.maximp0=1000000;
pars.treesize=50;
pars.valindex=[];
pars.checkup=2; %0=notree 1=tree 2=choose
pars.subsample=min(max(2000/length(y),0.1),1);

pars.pars=[];

L=L0;
pars.L=L;
Kg=pars.Kg;
if isstruct(pars.pars), pars=pars.pars;end;
if(~pars.quiet),fprintf('LMNN stable version 2.4b\n');end;
if pars.diagonal, pars.obj=2;L=eye(size(L)); end;

L=L(1:pars.outdim,:);

if(pars.validation<0 | pars.validation>1)
    error('validation parameter should be >0 and <1. Thanks.');
end;
earlycounter=0;
if isempty(pars.valindex),
    [itr,ite]=makesplits_CV(y,1-pars.validation_,1,pars.classsplit,Kg+1,pars.valrand);
else
    pars.validation_=0.2;
    ite=find(ismember(1:length(y),pars.valindex));
    itr=find(~ismember(1:length(y),pars.valindex));
end;

if pars.validation>0,
    pars.validation_=pars.validation;
    pars.validation=0;
    [~,Det]=lmnn_dist(Dist_raw,y,L0,pars);
    pars.maxiter=Det.bestiter;
    pars.validation_=0;
    fprintf('Setting maxiter to %i \n',pars.maxiter);
end;
Dist_all=sum(Dist_raw,3);

yv=y(:,ite);
y=y(itr);
Nf=size(Dist_raw,3);
Dist_raw=Dist_raw([itr ite],[itr ite],:);
Dist_perm=permute(Dist_raw,[3 1 2]);
Dist_all=Dist_all([itr ite],[itr ite]);
tempA=permute(Dist_raw,[3,1,2]);
tempB=reshape(tempA,Nf,[]);
Ntr=length(itr);Nte=length(ite);

xt=(1:Ntr)';
xe=(Ntr+1:Ntr+Nte)';

%% Protection against k too small
un=unique(y);
for i=1:length(un)
    ii=(y==un(i));
    if sum(ii)<=Kg, % remove all points from that label
        Kg=sum(ii)-1;
    end;
end;

if length(unique(y))<2,
    error('At least two classes must have more inputs than the neighborhood size.');
end;


besterr=inf;
clear('xo','yo');
verify=zeros(1,pars.maxiter);
bestL=L;

if(~pars.quiet)
    pars
end;


N=length(xt);

fprintf('%i input vectors with %i dimensions\n',N,Nf)

[gen,NN]=getGenLS_dist(Dist_all,xt',y,Kg,pars);

obj=zeros(1,pars.maxiter);
nimp=zeros(1,pars.maxiter);

fprintf('Total number of genuine pairs: %i\n',size(gen,2))

dfG=vec(SOD_dist(Dist_perm,gen(1,:),gen(2,:)));

if(pars.scale)
    tempC=L*tempB;
    tempD=sum(tempC.*tempC,1);
    Dist_L=reshape(tempD,size(Dist_raw,1),size(Dist_raw,2));
    sc=sqrt(mean(diag(Dist_L(1:Ntr,NN(end,:)))));
    L=2.*L./sc;
end;

df=zeros(Nf^2,1);
correction=1;
ifraction=pars.ifraction;
stepsize=pars.stepsize;


% flush gradient
for nnid=1:Kg; a1{nnid}=[];a2{nnid}=[];end;
df=zeros(size(dfG));
imp=zeros(2,0);

% Main Loop
for iter=1:pars.maxiter
    Lold=L;dfold=df;
    for nnid=1:Kg; a1old{nnid}=a1{nnid};a2old{nnid}=a2{nnid};end;
    
    % perform gradient step
    if(iter>1)
        L=step(L,mat((dfG.*pars.mu+df.*(1-pars.mu))),stepsize,pars);
    end;
    %
    if(~pars.quiet)fprintf('%i.',iter);end;
    
    Ni=zeros(Kg,N);
    %================ new distamces based on L
    tempC=L*tempB;
    tempD=sum(tempC.*tempC,1);
    Dist_L=reshape(tempD,size(Dist_raw,1),size(Dist_raw,2));
    
    for nnid=1:Kg
        Ni(nnid,:)=diag(Dist_L(1:Ntr,NN(nnid,:)))+1;
    end;
    % check validation data set for early stopping
    if(pars.validation_>0 && (mod(iter,pars.validationstep)==0 | iter==1))
        dist_fnc = @(x,Z)Dist_L(1:size(Z,1),x);% 
        knnmodel=fitcknn(xt, y','NumNeighbors',Kg,'Distance',@(x,Z)dist_fnc(x,Z)); 
        [Details.lTe2,score,cost] = predict(knnmodel,xe); 
        verify(iter)=sum(Details.lTe2'~=yv)/Nte; 
        fprintf('kNN validation error: %2.2f ',verify(iter)*100);
        if(verify(iter)<besterr)
            fprintf('< %2.2f   :-) %i/%i\n',besterr*100,earlycounter,pars.earlystopping);besterr=verify(iter);bestL=L;Det.bestiter=iter;
            earlycounter=0;
        else
            earlycounter=earlycounter+1;
            fprintf('>= %2.2f   :-( %i/%i\n',besterr*100,earlycounter,pars.earlystopping);
        end;
        if(pars.earlystopping>0 & earlycounter>=pars.earlystopping)
            fprintf('Validation error is no longer improving!\n');break;
        end;
    end;
    
    % update working set occasionally
    correction=correction-1;
    if correction==0 | mod(iter,500)==0,
        % every now and so often recompute the gradient from scratch (as inaccuracies accumulate)
        if iter>2 & (obj(iter-1)<0 |  mod(iter,500)==1),
            for nnid=1:Kg; a1{nnid}=[];a2{nnid}=[];end;
            df=zeros(size(dfG));
            fprintf('Flushing gradient!\n');
        end;
        
        %%%<<<
        os=pars.subsample;if isempty(a1{1}), pars.subsample=max(0.5,os);end;
        Vio=checkup(Dist_L,L,y,NN(Kg,:),pars); 
        pars.subsample=os;clear('os');
        
        Vio=setdiff(Vio',imp','rows')';% matlab funcion
        if(pars.maximp<inf)
            i=randperm(size(Vio,2));
            Vio=Vio(:,i(1:min(pars.maximp*(iter>1)+pars.maximp0*(iter==1),size(Vio,2))));
        end;
        ol=size(imp,2);
        imp_temp=imp;
        [imp i1 i2]=unique([imp Vio].','rows');
        imp=imp.';
        if(size(imp,2)~=ol)
            for nnid=1:Kg;
                a1{nnid}=i2(a1{nnid});
                a2{nnid}=i2(a2{nnid});
            end;
        end;
        if(~pars.quiet)fprintf('Added %i constraints to active set (%i total).\n',size(imp,2)-ol,size(imp,2));end;
        %%% <<<
        correction=pars.correction;
    end;
    
    % compute gradient
    [impostors,df,a1,a2]=computeGradient(Dist_L,Dist_perm,Kg,NN,Ni,df,imp,a1,a2); 
    
    obj(iter)=(dfG.*pars.mu+df.*(1-pars.mu))'*vec(L'*L)+impostors.*(1-pars.mu);
    nimp(iter)=impostors;
    delta=obj(iter)-obj(max(iter-1,1));
    if(~pars.quiet)fprintf(['  Obj:%2.2f Nimp:%i Delta:%2.4f max(G): %2.4f             \n   '],obj(iter),nimp(iter),delta,max(max(abs(df))));end;
    
    % increase stepsize if it makes good progress, otherwise decrease
    if(iter>1 & delta>0 & correction~=pars.correction)
        stepsize=stepsize*0.5;
        if(~pars.quiet)fprintf('***correcting stepsize***\n');end;
        %         fprintf('***correcting stepsize***\n')
        if(stepsize<pars.minstepsize) stepsize=pars.minstepsize;end;
        if(~pars.aggressive)
            L=Lold;
            df=dfold;
            for nnid=1:Kg; a1{nnid}=a1old{nnid};a2{nnid}=a2old{nnid};end;
            obj(iter)=obj(iter-1);
        end;
    else
        if(correction~=pars.correction)stepsize=stepsize*pars.stepgrowth;end;
    end;
    
    % check if converged
    if (iter>10) & (max(abs(diff(obj(iter-3:iter))))<pars.thresho*obj(iter)  | stepsize<pars.thresha)
        if iter<20, % special case: stuck because initial stepsize was too small
            stepsize=stepsize*10;
            continue;
        end;
        if(pars.correction-correction>=5)
            correction=1;
            continue;
        end;
        switch(pars.obj)
            case 0
                fprintf('Stepsize too small. No more progress!\n')
                break;
            case 1
                pars.obj=0;
                pars.correction=15;
                stepsize=pars.stepsize;
                correction=1;
                for nnid=1:Kg; a1{nnid}=[];a2{nnid}=[];end;
                df=zeros(size(dfG));
                imp=zeros(2,0);
                if(~pars.quiet | 1)
                    fprintf('\nVerifying solution! %i\n',obj(iter))
                end;
        end;
    end;
end;


if iter==pars.maxiter
    fprintf('MAXIMUM Number of iterations reached. Terminating without convergence.\n')
end;
% Output
Det.obj=obj(1:iter);
Det.nimp=nimp(1:iter);
Det.pars=pars;
Det.time=toc;
Det.iter=iter;

Det.verify=verify;

if(pars.validation_>0)
    Det.minL=L;
    L=bestL;
    Det.verify=verify;
end;


function  [impostors,df,a1,a2]=computeGradient(Dist_L,Dist_perm,Kg,NN,Ni,df,imp,a1,a2)
impostors=0;
g0=cdist_dist(Dist_L,imp(1,:),imp(2,:)); 
g1=Ni(:,imp(1,:));
g2=Ni(:,imp(2,:));
for nnid=Kg:-1:1
    act1=find(g0<g1(nnid,:));
    act2=find(g0<g2(nnid,:));
    active=[act1 act2];
    if(~isempty(a1{nnid}) | ~isempty(a2{nnid}))
        try
            [plus1,minus1]=sd(act1(:)',a1{nnid}(:)');
            [plus2,minus2]=sd(act2(:)',a2{nnid}(:)');
        catch, disp(lasterr);keyboard;end;
    else
        plus1=act1;plus2=act2;
        minus1=[];minus2=[];
    end;
    
    MINUS1a=[imp(1,minus1) imp(2,minus2)]; MINUS1b=[imp(1,[plus1 plus2])];
    MINUS2a=[NN(nnid,imp(1,minus1)) NN(nnid,imp(2,minus2))]; MINUS2b=[imp(2,[plus1 plus2])];
    
    [isplus2,i]= sort(imp(2,plus2));plus2=plus2(i);
    PLUS1a=[imp(1,plus1) isplus2]; PLUS1b=[imp(1,[minus1 minus2])];
    PLUS2a=[NN(nnid,imp(1,plus1)) NN(nnid,isplus2)]; PLUS2b=[imp(2,[minus1 minus2])];
    
    [PLUS ,pweight]=count([PLUS1a;PLUS2a]);
    [MINUS,mweight]=count([MINUS1a;MINUS2a]);
    
    df2=SODW_dist(Dist_perm,PLUS(1,:),PLUS(2,:),pweight)-SODW_dist(Dist_perm,MINUS(1,:),MINUS(2,:),mweight);
    df4=SOD_dist(Dist_perm,PLUS1b,PLUS2b)-SOD_dist(Dist_perm,MINUS1b,MINUS2b);
    df=df+vec(df2+df4);
    
    a1{nnid}=act1;a2{nnid}=act2;
    impostors=impostors+length(active);
end;
if(any(any(isnan(df))))
    fprintf('Gradient has NaN value!\n');
    keyboard;
end;



function L=step(L,G,stepsize,pars);
% do step in gradient direction
if(size(L,1)~=size(L,2)) pars.obj=1;end;
switch(pars.obj)
    case 0    % updating Q
        Q=L'*L;
        Q=Q-stepsize.*G;
        % decompose Q
        [L,dd]=eig(Q);
        dd=real(diag(dd));
        L=real(L);
        % reassemble Q (ignore negative eigenvalues)
        j=find(dd<1e-10);
        if(~isempty(j))
            if(~pars.quiet)fprintf('[%i]',length(j));end;
        end;
        dd(j)=0;
        [temp,ii]=sort(-dd);
        L=L(:,ii);
        dd=dd(ii);
        L=(L*diag(sqrt(dd)))';
    case 1   % updating L
        G=2.*(L*G);
        L=L-stepsize.*G;
        return;
    case 2 % diagonal L
        Q=L'*L;
        Q=Q-stepsize.*G;
        Q=diag(Q);
        L=diag(sqrt(max(Q,0)));
        return;
    otherwise
        error('Objective function has to be 0,1,2\n');
end;






function [gen,NN]=getGenLS_dist(Dist_all,x,y,Kg,pars);
if(~pars.quiet);fprintf('Computing nearest neighbors ...\n');end; %#ok<SEPEX>
[D,N]=size(x);

un=unique(y);
Gnn=zeros(Kg,N);
for c=un
    if(~pars.quiet) fprintf('%i nearest genuine neighbors for class %i:',Kg,c);end;
    i=find(y==c);
    nn=LSKnn_dist(Dist_all,i,i,2:Kg+1,pars);  
    Gnn(:,i)=i(nn);
    if(~pars.quiet)fprintf('\r');end;
end;
if(~pars.quiet),fprintf('\n');end;
NN=Gnn;
gen1=vec(Gnn(1:Kg,:)')';
gen2=vec(repmat(1:N,Kg,1)')';
gen=[gen1;gen2];



function [gen,NN]=getGenLS(x,y,Kg,pars);
if(~pars.quiet);fprintf('Computing nearest neighbors ...\n');end; %#ok<SEPEX>
[D,N]=size(x);

un=unique(y);
Gnn=zeros(Kg,N);
for c=un
    if(~pars.quiet) fprintf('%i nearest genuine neighbors for class %i:',Kg,c);end;
    i=find(y==c);
    nn=LSKnn(x(:,i),x(:,i),2:Kg+1,pars);
    Gnn(:,i)=i(nn);
    if(~pars.quiet)fprintf('\r');end;
end;
if(~pars.quiet),fprintf('\n');end;
NN=Gnn;
gen1=vec(Gnn(1:Kg,:)')';
gen2=vec(repmat(1:N,Kg,1)')';
gen=[gen1;gen2];


% ============================
function imp=checkup(Dist_L,L,y,NN,pars,~)

persistent treetime notreetime;

if pars.subsample<1,
    imp=checkupnotree(L,y,NN,pars); 
    return;
end;
if(nargin==6)
    treetime=-1;
    notreetime=-1;
end;
if(~pars.quiet)fprintf('Updating working set.\n');end;
t1=toc;
if(pars.checkup==1 | (pars.checkup==2 & treetime<notreetime))
    imp=checkupmtree(Dist_L,y,NN,pars);treetime=toc-t1;
else
    imp=checkupnotree(Dist_L,y,NN,pars);notreetime=toc-t1;
end;
% if there are too many constraints - subsample
if(size(imp,2)>pars.maximp0)
    ip=randperm(size(imp,2));
    ip=ip(1:pars.maximp0);
    imp=imp(:,ip);
    fprintf('Too many constraints - subsampling %i\n',pars.maximp0)
end;



function imp=checkupmtree(Dist_L,y,NN,pars)
if(~pars.quiet);fprintf('[Tree] Computing nearest neighbors ...\n');end;
N=length(y);
Ni=diag(Dist_L(1:N,NN))'+2;
un=unique(y);

% build up ball trees
for c=1:length(un)
    classindex{c}=find(y==un(c));
    forest{c}.tree=buildmtreemex(Lx(:,classindex{c}),pars.treesize);
end;
imp=[];
for c=1:length(un)-1
    if(~pars.quiet)fprintf('All impostors for class %i    \r',c);end;
    for c2=c+1:length(un)
        try
            limps=findNimex(forest{c2}.tree,Lx(:,classindex{c2}),Lx(:,classindex{c}),Ni(classindex{c2}),Ni(classindex{c}));
        catch
            fprintf('The bizarre error happened!\n');
            fprintf('Check class index, c2 etc\n');
            fprintf('Line 629 in lmnn_DTW\n');
            keyboard;
        end;
        
        %    keyboard;
        if(size(limps,2)>pars.maximp)
            ip=randperm(size(limps,2));
            ip=ip(1:pars.maximp);
            limps=limps(:,ip);
        end;
        limps=[classindex{c}(limps(1,:));classindex{c2}(limps(2,:))];
        imp=[imp limps];
    end;
end;
try
    imp=unique(sort(imp)','rows')';
catch
    fprintf('Sorry, probably ran out of memory!');
    keyboard;
end;



function imp=checkupnotree(Dist_L,y,NN,pars)
if(~pars.quiet) fprintf('Computing nearest neighbors ...\n');end;
N=length(y);
Ni=diag(Dist_L(1:N,NN))'+2;  % 

un=unique(y);
imp=[];

for c=un(1:end-1)
    if(~pars.quiet)fprintf('All nearest impostor neighbors for class %i :',c);end;
    i=find(y==c);
    index=find(y>c);
    %keyboard;
    %% experimental
    ir=randperm(length(i));ir=ir(1:ceil(length(ir)*pars.subsample));
    ir2=randperm(length(index));ir2=ir2(1:ceil(length(ir2)*pars.subsample));
    index=index(ir2);
    i=i(ir);
    %% experimental
    
    limps=LSImps2(Dist_L,index,i,Ni(index),Ni(i),pars);
    if(size(limps,2)>pars.maximp)
        ip=randperm(size(limps,2));
        ip=ip(1:pars.maximp);
        limps=limps(:,ip);
    end;
    imp=[imp [i(limps(2,:));index(limps(1,:))]];
    
    if(~pars.quiet)fprintf('\r');end;
end;

try
    imp=unique(sort(imp)','rows')';
catch
    fprintf('Sorry, probably ran out of memory!');
    keyboard;
end;



function limps=LSImps2(Dist_L,X1,X2,Thresh1,Thresh2,pars);
B=2000;
N2=length(X2);
N1=length(X1);
limps=[];
for i=1:B:N2
    BB=min(B,N2-i);
    % finding if there are cases that the data is nearest to another class
    % sample than within class data
    newlimps=findimps3Dm_dist(Dist_L,X1,X2(:,i:i+BB), Thresh1,Thresh2(i:i+BB));
    if isempty(newlimps)
        newlimps=findimps3Dm_dist(Dist_L,X1,X2(:,i:i+BB), Thresh1,Thresh2(i:i+BB));
    end
    if(~isempty(newlimps) & newlimps(end)==0)
        [minv,endpoint]=min(min(newlimps));
        newlimps=newlimps(:,1:endpoint-1);
    end;
    newlimps=unique(newlimps','rows')';
    newlimps(2,:)=newlimps(2,:)+i-1;
    limps=[limps newlimps];
    if(~pars.quiet)fprintf('(%i%%) ',round((i+BB)/N2*100)); end;
end;
if(~pars.quiet)fprintf(' [%i]              ',size(limps,2));end;

% ============================
function NN=LSKnn_dist(Dist_all,X1,X2,ks,pars);
B=750;
[~,N]=size(X2);
NN=zeros(length(ks),N);
DD=zeros(length(ks),N);

for i=1:B:N
    BB=min(B,N-i);
    if(~pars.quiet)  fprintf('.');end;
    Dist=Dist_all(X1,X2(:,i:i+BB)); 
    if(~pars.quiet)  fprintf('.');end;
    [dist,nn]=mink(Dist,max(ks));
    clear('Dist');
    if(~pars.quiet)  fprintf('.');end;
    NN(:,i:i+BB)=nn(ks,:);
    clear('nn','dist');
    if(~pars.quiet),fprintf('(%i%%) ',round((i+BB)/N*100)); end;
end;


function NN=LSKnn(X1,X2,ks,pars);
global Euc_dist;
B=750;
[~,N]=size(X2);
NN=zeros(length(ks),N);
DD=zeros(length(ks),N);

for i=1:B:N
    BB=min(B,N-i);
    if(~pars.quiet)  fprintf('.');end;
    Dist=distance(X1,X2(:,i:i+BB));
    if(~pars.quiet)  fprintf('.');end;
    [dist,nn]=mink(Dist,max(ks));
    clear('Dist');
    if(~pars.quiet)  fprintf('.');end;
    NN(:,i:i+BB)=nn(ks,:);
    clear('nn','dist');
    if(~pars.quiet),fprintf('(%i%%) ',round((i+BB)/N*100)); end;
end;




