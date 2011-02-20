function [w0,wlow,whigh,Flow,Fhigh,iGfun,jGvar,userfun,wrapupfun,iname,oname] = dircol_snopt_transcription(sys,costFun,finalCostFun,x0,utraj0,con,options)

  if (~isfield(con,'mode')) error('con.mode must be defined for FiniteStateMachines'); end
  for i=1:length(x0)
    if (length(x0{i})~=sys.getNumContStates()), error('x0 should NOT have the mode variable as the first element.'); end
  end
  for m=1:length(con.mode)
    % todo: check here that utraj0{m} starts at t=0?
    [w0{m},wlow{m},whigh{m},Flow{m},Fhigh{m},iGfun{m},jGvar{m},mode_userfun{m},mode_wrapup{m},mode_iname{m},mode_oname{m}] = dircol_snopt_transcription(sys.modes{con.mode{m}.mode_num},costFun{m},finalCostFun{m},x0{m},utraj0{m},rmfield(con.mode{m},'mode_num'),options);
    tOrig{m} = utraj0{m}.getBreaks();
    N(m) = length(w0{m});
    nT(m) = length(tOrig{m});
    nf(m) = length(Flow{m});
    if (m>1)
      nf(m)=nf(m)-1;  % don't duplicate cost function
      Flow{1}(1)=Flow{1}(1)+Flow{m}(1); Flow{m} = Flow{m}(2:end);
      Fhigh{1}(1)=Fhigh{1}(1)+Fhigh{m}(1); Fhigh{m} = Fhigh{m}(2:end);
      njind = (iGfun{m}~=1);  
      iGfun{m}(njind) = iGfun{m}(njind)+sum(nf(1:m-1))-1;  %subtract 1 to remove J ind
      jGvar{m} = jGvar{m}+sum(N(1:m-1));
      mode_oname{m}=mode_oname{m}(2:end);
    end
  end
  m=m+1;
  [nf(m), iGfun{m}, jGvar{m}, Fhigh{m}, Flow{m}, fsm_oname] = fsmObjFun_ind(sys,N,nT,options);
  iGfun{m} = iGfun{m}+sum(nf(1:m-1));
  w0=[w0{:}]; wlow=[wlow{:}]; whigh=[whigh{:}]; Flow=[Flow{:}]; Fhigh=[Fhigh{:}]; iGfun=[iGfun{:}]; jGvar=[jGvar{:}];

  % handle additional constraints
  for f=fieldnames(con)'
    switch(f{1})
      case 'mode'
        continue  %handled above
      otherwise
        warning([f,' constraint not handled by FSM dircol (at least not yet)']);
    end
  end
  
  userfun = @(w) dircol_userfun(sys,w,mode_userfun,tOrig,N,con,options);
  wrapupfun = @(w) dircol_wrapup(sys,w,mode_wrapup,tOrig,N,con,options);
  
  if (options.grad_test)
    iname = {};  oname = {};
    for i=1:length(con.mode), 
      for j=1:length(mode_iname{i}), 
        iname = {iname{:},['m',num2str(i),' ',mode_iname{i}{j}]};
      end
      for j=1:length(mode_oname{i}),
        oname = {oname{:},['m',num2str(i),' ',mode_oname{i}{j}]};
      end
    end
    oname = {oname{:},fsm_oname{:}};
  else
    iname={};
    oname={};
  end

  
  
end

function [f,G] = dircol_userfun(sys,w,userfun,tOrig,N,con,options)
  ind = 0;
  f=0;
  G=[];
  for m=1:length(N)
    [cf,cG] = userfun{m}(w(ind+(1:N(m))));
    ind = ind+N(m);
    f(1) = f(1)+cf(1);  % add costs
    f = [f; cf(2:end)]; % tally up constraints
    G = [G; cG];
  end
  
%  return;
  
  nX = sys.getNumContStates();
  nU = sys.getNumInputs();
  %% additional fsm constraints:
  for m=1:length(N)-1
    from_mode = con.mode{m}.mode_num; 
    to_mode = con.mode{m+1}.mode_num;
    
    % final value for each mode (except the last) needs to have or(relevant zcs=0).  not
    % just any zc, but a zc that transitions me to the correct next node.
    if (m>1) from_ind = cumsum(N(1:m-1)); else from_ind = 0; end
    tscale = w(from_ind+1);
    nT = length(tOrig{m}); 
    tc = tscale*tOrig{m}(end); xc = w(from_ind+1+(nT-1)*nX+(1:nX));  uc = w(from_ind+1+nT*nX+(nT-1)*nU+(1:nU));
    zc = 1; dzc = zeros(1,1+nX+nU);  % d/d[tscale,xc,uc]
    min_g = inf; min_g_ind = 0;
    for i=find(sys.target_mode{from_mode}==to_mode)
      [g,dg] = sys.guard{from_mode}{i}(sys,tc,xc,uc);
      dg = dg{1}; dg(1) = dg(1)*tOrig{m}(end);
      if (g<min_g), min_g = g; min_g_ind = i; end 
      dzc = dzc*g + zc*dg;
      zc = zc*g;  % multiply zcs to implement logical OR.
    end
    f = [f; zc];
    G = [G; dzc(:)];
    
%    continue;
  
    % initial value for each mode (except the first) needs to equal final
    % value of the previous after the transition update.
    if (min_g_ind<1) error('no applicable zero crossings defined'); end
    to_ind = from_ind+N(m);
    to_x0 =  w(to_ind+1+(1:nX));
    [to_x,status,dto_x] = sys.update{from_mode}{min_g_ind}(sys,tc,xc,uc);
    dto_x = dto_x{1};  dto_x(1,:) = dto_x(1,:)*tOrig{m}(end);
    f = [f; to_x - to_x0];
    G = [G; dto_x(:); -ones(nX,1)];  % df/d[tc,xc,uc]; df/d[to_x0]
  end
  
end


function [nf, iGfun, jGvar, Fhigh, Flow, oname] = fsmObjFun_ind(sys,N,nT,options)
  nX = sys.getNumContStates();
  nU = sys.getNumInputs();
 
  %% additional fsm constraints:
  nf = 0;
  iGfun=[]; jGvar=[];   oname={};
  
  % for debugging
%  Fhigh=[]; Flow=[]; return
  
  for m=1:length(N)-1
    % final value for each mode (except the last) needs to have zc=0.
    if (m>1) from_ind = cumsum(N(1:m-1)); else from_ind = 0; end
    iGfun = [iGfun, nf + ones(1,1+nX+nU)];
    jGvar = [jGvar, from_ind + [1,1+(nT(m)-1)*nX+(1:nX),1+nT(m)*nX+(nT(m)-1)*nU+(1:nU)]];  
    nf = nf + 1;
    
    % for debugging
%    oname = {oname{:}, ['mode(',num2str(m),').xf zc']};  continue;
    
    % initial value for each mode (except the first) needs to equal final
    % value of the previous after the transition update.
    to_ind = from_ind+N(m);
    iGfun = [iGfun, nf + reshape(repmat(1:nX,1+nX+nU,1)',1,[]), nf + (1:nX)];
    jGvar = [jGvar, from_ind + reshape(repmat([1,1+(nT(m)-1)*nX+(1:nX),1+nT(m)*nX+(nT(m)-1)*nU+(1:nU)],nX,1),1,[]), to_ind+1+(1:nX)];
    nf = nf + nX;

    if (options.grad_test) 
      oname = {oname{:}, ['mode(',num2str(m),').xf zc']};
      for j=1:nX, 
        oname = {oname{:}, ['update(mode(',num2str(m),').xf)(i) - mode(',num2str(m+1),').x0']}; 
      end
    end
  end
  Fhigh = zeros(1,nf);
  Flow = Fhigh;
end

function [utraj,xtraj] = dircol_wrapup(sys,w,mode_wrapupfun,tOrig,N,con,options)

  t=0;
  ind=0;
  for m=1:length(N)
    [utraj{m},mode_xtraj] = mode_wrapupfun{m}(w(ind +(1:N(m))));
    utraj{m} = shiftTime(utraj{m},t);
    mode_xtraj = shiftTime(mode_xtraj,t);
    
    tnext=t+w(ind+1)*tOrig{m}(end);
    ind = ind+N(m);

    mtraj=PPTrajectory(zoh([t tnext],repmat(con.mode{m}.mode_num,1,2)));
    xtraj{m} = MixedTrajectory({mtraj,mode_xtraj},{1,1+[1:sys.getNumContStates()]});
    t=tnext;
  end
  
  utraj = HybridTrajectory(utraj);
  xtraj = HybridTrajectory(xtraj);

end
