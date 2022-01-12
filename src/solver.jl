Base.@kwdef struct LiftedTrajectoryGameSolver{TA,TT,TH,TF,TS,TR}
    "A collection of action generators, one for each player in the game."
    trajectory_parameter_generators::TA
    "A acollection of trajectory generators, one for each player in the game"
    trajectory_generators::TT
    "The number of time steps to plan into the future."
    planning_horizon::TH
    "The solver for the high-level finite game"
    finite_game_solver::TF = FiniteGames.LemkeHowsonGameSolver()
    "A value network to predict the game value for each player"
    statevalue_predictor::TS = nothing
    "A random number generator to generate non-deterministic strategies."
    rng::TR = Random.MersenneTwister(1)
    "A flag that can be set to enable/disable learning"
    enable_learning::Ref{Bool} = Ref(true)
end

"""
Convenience constructor to drive a suitable solver directly form a given game.
"""
function LiftedTrajectoryGameSolver(
    game::TrajectoryGame{<:ZeroSumCostStructure,<:ProductDynamics},
    planning_horizon;
    rng = Random.MersenneTwister(1),
    n_actions = 2,
    network_configs = Iterators.repeated((;
        n_hidden_layers = 2,
        hidden_dim = 100,
        learning_rate = 1,
    )),
    trajectory_parameterizations = Iterators.repeated(
        InputReferenceParameterization(; α = 5, params_abs_max = 4),
    ),
    trajectory_solver = QPSolver(),
    enable_learning = true,
    kwargs...,
) where {T}
    num_players(game) == 2 ||
        error("Currently, onlye 2-player problems are supported by this solver.")
    # TODO: these should be derived from the cost structure
    player_learning_rate_signs = [1, -1]

    # setup a trajectory generator for every player
    trajectory_generators =
        map(game.dynamics.subsystems, trajectory_parameterizations) do subdynamics, parameterization
            DifferentiableTrajectoryGenerator(
                ParametricOptimizationProblem(
                    parameterization,
                    subdynamics,
                    game.env,
                    planning_horizon,
                ),
                trajectory_solver,
            )
        end

    trajectory_parameter_generators = map(
        trajectory_generators,
        player_learning_rate_signs,
        network_configs,
    ) do trajectory_generator, learning_rate_sign, network_config
        OnlineOptimizationActionGenerator(;
            n_params = param_dim(trajectory_generator),
            n_actions,
            trajectory_generator.problem.parameterization.params_abs_max,
            learning_rate = network_config.learning_rate * learning_rate_sign,
            rng,
        )
    end

    LiftedTrajectoryGameSolver(;
        trajectory_parameter_generators,
        trajectory_generators,
        planning_horizon,
        enable_learning = Ref(enable_learning[]),
        kwargs...,
    )
end

# TODO: Re-introduce state-value learning
function TrajectoryGamesBase.solve_trajectory_game!(
    solver::LiftedTrajectoryGameSolver,
    game::TrajectoryGame{<:ZeroSumCostStructure,<:ProductDynamics},
    initial_state,
)
    # TODO: this should not be hard-coded
    local Vs, mixing_strategies, player_references, player_trajectory_candidates

    ∇V1 = Zygote.gradient(Flux.params(solver.trajectory_parameter_generators...)) do
        player_references = map(gen -> gen(initial_state), solver.trajectory_parameter_generators)
        player_trajectory_candidates = map(
            blocks(initial_state),
            player_references,
            solver.trajectory_generators,
        ) do substate, refs, trajectory_generator
            [trajectory_generator(substate, ref)[1] for ref in refs]
        end

        cost_tensor = map(Iterators.product(player_trajectory_candidates...)) do (t1, t2)
            xs = map(t1, t2) do x_p1, x_p2
                mortar([x_p1, x_p2])
            end
            # TODO: the trajectory generator shouuld also return us so that we can have outer costs
            # depend on them here
            us = [nothing for _ in xs]
            game.cost(1, xs, us)
        end

        mixing_strategies = let
            sol = FiniteGames.solve_mixed_nash(solver.finite_game_solver, cost_tensor)
            (; sol.x, sol.y)
        end

        Vs = FiniteGames.game_cost(mixing_strategies.x, mixing_strategies.y, cost_tensor)
        Vs.V1
    end

    γs = map(
        mixing_strategies,
        Vs,
        player_trajectory_candidates,
    ) do weights, V, trajectory_candidates
        info = (;
            V,
            ∇_norm = sum(
                norm(∇V1[p] for p in Flux.params(solver.trajectory_parameter_generators...)),
            ),
        )
        LiftedTrajectoryStrategy(trajectory_candidates, weights, initial_state, info, solver.rng)
    end

    if solver.enable_learning[]
        for parameter_generator in solver.trajectory_parameter_generators
            update_parameters!(parameter_generator, ∇V1)
        end
    end

    JointStrategy(γs)
end
