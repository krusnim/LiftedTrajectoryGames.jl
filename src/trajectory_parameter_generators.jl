struct NNActionGenerator{M,O}
    model::M
    optimizer::O
    n_actions::Int
end
@functor NNActionGenerator (model,)

function NNActionGenerator(;
    state_dim,
    hidden_dim,
    n_hidden_layers,
    n_params,
    params_abs_max,
    n_actions,
    learning_rate,
    rng,
)
    init(in, out) = Flux.glorot_uniform(rng, in, out)

    model = Chain(
        Dense(state_dim, hidden_dim, tanh; init),
        (Dense(hidden_dim, hidden_dim, tanh; init) for _ in 1:(n_hidden_layers - 1))...,
        Dense(hidden_dim, n_params * n_actions, tanh; init),
        x -> params_abs_max .* x,
    )

    optimizer = Optimise.Descent(learning_rate)

    NNActionGenerator(model, optimizer, n_actions)
end

function (g::NNActionGenerator)(states)
    x = reduce(vcat, states)
    stacked_goals = g.model(x)
    collect(eachcol(reshape(stacked_goals, :, g.n_actions)))
end

function update_parameters!(g, ∇)
    θ = Flux.params(g)
    Optimise.update!(g.optimizer, θ, ∇)
end
