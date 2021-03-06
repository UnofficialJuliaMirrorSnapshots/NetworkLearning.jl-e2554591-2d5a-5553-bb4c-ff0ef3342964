#########################
# Entity-based learning #
#########################

# The state of the network learner: it is defined by estimates for all nodes
# and a mask that specifies which of the estimates are to be update (in case the training
# data is used as well


"""
Entity-based network learning model state. It consists of an `Array` with estimates and a an update
mask in the form of a `BitVector` indicating which observation estimates are to be updated (the
ones that are not updated are considered training/stable observations).
"""
mutable struct NetworkLearnerState{T<:AbstractArray, OD<:LearnBase.ObsDimension}
	ê::T			# estimates
	update::BitVector	# which estimates to update
	obsdim::OD

	function NetworkLearnerState(ê::T, update::BitVector, obsdim::OD) where {T<:AbstractArray, OD<:LearnBase.ObsDimension}
		@assert  nobs(ê,obsdim=obsdim) == length(update) "Number of NetworkLearner estimates should be equal to the length of the update mask."
		new{T,OD}(ê, update, obsdim)
	end
end

Base.show(io::IO, m::NetworkLearnerState) = print(io, "NetworkLearner state: $(sum(m.update))/$(length(m.update)) entities can be updated") 



"""
Entity-based network learning model type.
"""
mutable struct NetworkLearnerEnt{S,V,
				    NS<:NetworkLearnerState,
				    R<:Vector{<:AbstractRelationalLearner},
				    C<:AbstractCollectiveInferer,
				    A<:Vector{<:AbstractAdjacency},
				    OD<:LearnBase.ObsDimension} <: AbstractNetworkLearner 			 
	state::NS										# state 
	Mr::S											# relational model
	fr_exec::V										# relational model execution function
	RL::R											# relational learner
	Ci::C											# collective inferer	
	Adj::A											# adjacency information
	size_out::Int										# expected output dimensionality
	obsdim::OD										# observation dimension
end



# Printers
Base.show(io::IO, m::NetworkLearnerEnt) = begin 
	println(io,"NetworkLearner, $(m.size_out) estimates, entity-based")
	println(io,"`- state: $(sum(m.state.update))/$(nobs(m.state.update)) entities can be updated"); 
	print(io,"`- relational model: "); println(io, m.Mr)
	print(io,"`- relational learners: "); println(io, m.RL)
	print(io,"`- collective inferer: "); println(io, m.Ci)
	print(io,"`- adjacency: "); println(io, m.Adj)	
	println(io,"`- observations are: $(m.obsdim == ObsDim.Constant{1} ? "rows" : "columns")");
end



####################
# Training methods #
####################
"""
	fit(::Type{NetworkLearnerEnt}, X, update, Adj, fl_train, fl_exec, fr_train, fr_exec [;kwargs])

Training method for the entity-based network learning framework.

# Arguments
  * `Xo::AbstractMatrix` initial estimates for the entities
  * `update::BitVector` mask that indicates wether estimates can be updated (`true` value) or not (`false` value); false values 
  generally can be associated with estimates of training samples
  * `Adj::Vector{AbstractAdjacency}` a vector containing the entity relational structures (adjacency objects)
  * `fr_train` relational model training `function`; can be anything that suports the call `fr_train((Xr,y))` where `y = f_targets(Xo)` 
  * `fr_exec` relational model prediction `function`; can be anything that suports the call `fr_exec(Mr,Xr)` where `Mr = fr_train((Xr,y))`
  and `Xr` is a dataset of relational variables generated by the relational learner using the estimates `Xo` and the  adjacency structures.

# Keyword arguments
  * `priors::Vector{Float64}` class priors (if applicable)
  * `learner::Symbol` relational learner (i.e. variable generator); available options `:rn`, `:wrn`, `:bayesrn` and `:cdrn` (default `:wrn`)
  * `inference::Symbol` collective inference method; available options `:rl`, `:ic` and `:gs` (default `:rl`)
  * `normalize::Bool` whether to normalize the relational variables per-entity to the L1 norm (default `true`)
  * `f_targets::Function` function that extracts targets from estimates generated by the local/relational models 
  (default `f_targets = x->MLDataPattern.targets(indmax,x)`)
  * `obsdim::Int` observation dimension (default `2`)
  * `tol::Float64` maximum admissible mean estimate error for collective inference convergence (default `1e-6`)
  * `κ::Float64` relaxation labeling starting constant, used if `learner == :rl` (default `1.0`)
  * `α::Float64` relaxation labeling decay constant, used if `learner == :rl` (default `0.99`)
  * `maxiter::Int` maximum number of iterations for collective inference (default `100`)
  * `bratio::Float64` percentage of iterations i.e. `maxiter` used for Gibbs sampling burn-in (default `0.1`)
"""
function fit(::Type{NetworkLearnerEnt}, Xo::AbstractMatrix, update::BitVector, Adj::A where A<:Vector{<:AbstractAdjacency}, 
	     	fr_train, fr_exec; 
		learner::Symbol=:wvrn, inference::Symbol=:rl, normalize::Bool=true, f_targets::Function=x->targets(indmax,x), 
		obsdim::Int=2, priors::Vector{Float64}=1/nvars(Xo,ObsDim.Constant(obsdim)).*ones(nvars(Xo,ObsDim.Constant(obsdim))),
		tol::Float64=1e-6, κ::Float64=1.0, α::Float64=0.99, maxiter::Int=100, bratio::Float64=0.1) 

	# Parse, transform input arguments
	κ = clamp(κ, 1e-6, 1.0)
	α = clamp(α, 1e-6, 1.0-1e-6)
	tol = clamp(tol, 0.0, Inf)
	maxiter = ifelse(maxiter<=0, 1, maxiter)
	bratio = clamp(bratio, 1e-6, 1.0-1e-6)

	@assert obsdim in [1,2] "Observation dimension can have only two values 1 (row-major) or 2 (column-major)."
	@assert all((priors.>=0.0) .& (priors .<=1.0)) "All priors have to be between 0.0 and 1.0."
	
	# Parse relational learner argument and generate relational learner type
	if learner == :rn
		Rl = SimpleRN
	elseif learner == :wrn
		Rl = WeightedRN
	elseif learner == :cdrn 
		Rl = ClassDistributionRN
	elseif learner == :bayesrn
		Rl = BayesRN
	else
		@print_verbose 1 "Unknown relational learner. Defaulting to :wrn."
		Rl = WeightedRN
	end

	# Parse collective inference argument and generate collective inference objects
	if inference == :rl
		Ci = RelaxationLabelingInferer(maxiter, tol, f_targets, κ, α)
	elseif inference == :ic
		Ci = IterativeClassificationInferer(maxiter, tol, f_targets)
	elseif inference == :gs
		Ci = GibbsSamplingInferer(maxiter, tol, f_targets, ceil(Int, maxiter*bratio))
	else
		@print_verbose 1 "Unknown collective inferer. Defaulting to :rl."
		Ci = RelaxationLabelingInferer(maxiter, tol, f_targets, κ, α)
	end
	
	fit(NetworkLearnerEnt, Xo, update, Adj, Rl, Ci, fr_train, fr_exec; 
     		priors=priors, normalize=normalize, obsdim=ObsDim.Constant{obsdim}())
end



"""
Training method for the network learning framework. This method should not be called directly.
"""
function fit(::Type{NetworkLearnerEnt}, Xo::T, update::BitVector, Adj::A, Rl::R, Ci::C, fr_train::U, fr_exec::U2; 
	    	normalize::Bool=true, obsdim::LearnBase.ObsDimension=ObsDim.Constant{2}(),
	    	priors::Vector{Float64}=1/nvars(Xo,obsdim).*ones(nvars(Xo,obsdim)) ) where {
			T<:AbstractMatrix, 
			A<:Vector{<:AbstractAdjacency}, 
			R<:Type{<:AbstractRelationalLearner}, 
			C<:AbstractCollectiveInferer, 
			U, U2
		}
	 
	# Step 0: pre-process input arguments and retrieve sizes
	n = nobs(Xo,obsdim)									# number of entities
	p = nvars(Xo,obsdim)									# number of estimates/entity
	m = length(Adj) * p									# number of relational variables

	@assert p == length(priors) "Found $p entities/estimate, the priors indicate $(length(priors))."
	
	# Step 1: Get relational variables by training and executing the relational learner 
	@print_verbose 2 "Calculating relational variables ..."
	mₜ = .!update										# training mask (entities that are not updated
	Xoₜ = datasubset(Xo, mₜ, obsdim)							#    are considered training or high/certainty samples)
	nₜ = sum(mₜ)										# number of training observations
	yₜ = Ci.tf(Xoₜ)										# get targets
	Adjₜ = [adjacency(adjacency_matrix(Aᵢ)[mₜ,mₜ]) for Aᵢ in Adj]
	RL = [fit(Rl, Aᵢₜ, Xoₜ, yₜ; obsdim=obsdim, priors=priors, normalize=normalize)
       		for Aᵢₜ in Adjₜ]								# Train relational learners				

	# Pre-allocate relational variables array	
	Xr = matrix_prealloc(n, m, obsdim, 0.0)
	Xrᵢ = matrix_prealloc(nₜ, p, obsdim, 0.0)						# Initialize temporary storage	
	Xrₜ = datasubset(Xr, mₜ, obsdim)
	for (i,(RLᵢ,Aᵢₜ)) in enumerate(zip(RL,Adjₜ))		
		
		# Apply relational learner
		transform!(Xrᵢ, RLᵢ, Aᵢₜ, Xoₜ, yₜ)

		# Update relational data output		
		_Xrₜ = datasubset(Xrₜ, (i-1)*p+1 : i*p, oppdim(obsdim))
		_Xrₜ[:] = Xrᵢ		
	end
	

	# Step 2 : train relational model 
	@print_verbose 2 "Training relational model ..."
	Mr = fr_train((Xrₜ,yₜ))

	# Step 3: Apply collective inference
	@print_verbose 2 "Collective inference ..."
	transform!(Xo, Ci, obsdim, Mr, fr_exec, RL, Adj, 0, Xr, update)	
	
	# Step 3: return network learner 
	return NetworkLearnerEnt(NetworkLearnerState(Xo,update,obsdim), Mr, fr_exec, RL, Ci, Adj, p, obsdim)
end



"""
Function that calls collective inference using the information in contained in the entity-based network learner
"""
function infer!(model::T) where T<:NetworkLearnerEnt
	p = nvars(model.state.ê, model.obsdim)							# number of estimates/entity
	m = length(model.Adj) * p								# number of relational variables
	Xr = matrix_prealloc(nobs(model.state.ê, model.obsdim), m, model.obsdim, 0.0)

	transform!(model.state.ê, model.Ci, model.obsdim, model.Mr, model.fr_exec, model.RL, model.Adj, 0, Xr, model.state.update) 
end
