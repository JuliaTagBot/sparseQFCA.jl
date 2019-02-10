module sparseQFCA
export QFCA

using LinearAlgebra, SparseArrays, JuMP, GLPKMathProgInterface       

function QFCA(S, rev)
#=
QFCA computes the table of flux coupling relations and the list of blocked 
reactions for a metabolic network specified by its stoichiometric matrix 
and irreversible reactions and also returns the DCE positive certificates.
    Usage:
    certificates, blocked, fctable = QFCA(S, rev)
        - S: the associated sparse stoichiometric matrix
        - rev: the boolean vector with trues corresponding to the reversible reactions
        
        - certificates: the fictitious metabolites for the sparse positive certificates
        - blocked: the boolean vector with trues corresponding to the blocked reactions
        - fctable: the resulting flux coupling matrix
            * For the choice of entries, we use the F2C2 convention for the
            sake of compatibility. The meaning of the entry [i, j] is:
                0 - uncoupled reactions
                1 - fully coupled reactions
                2 - partially coupled reactions
                3 - reaction i is directionally coupled to reaction j
                4 - reaction j is directionally coupled to reaction i
=#
    model = Model(solver = GLPKSolverLP())
    m, n = size(S)
    ub = [fill(Inf, m); fill(0.0, n)]
    lb = -copy(ub)
    @variable(model, lb[j] <= z[j=1:m+n] <= ub[j])
    A = [S' -sparse(I, n, n)]
    for j in 1:n
        if rev[j]
            @constraint(model, sum{A[j,k]*z[k], k=1:m+n} == 0.0)
        else
            @constraint(model, sum{A[j,k]*z[k], k=1:m+n} <= 0.0)
        end
    end
    @objective(model, Min, sum{z[j], j = [m + j for j in 1:n if !rev[j]]})
    for j in 1:n
        setupperbound(z[m + j], 0.0)
        setlowerbound(z[m + j], rev[j] ? 0.0 : -1.0)
    end
    status = solve(model)
    result = getvalue(z)[m+1:end]
    blocked = result .≈ -1
    finalBlocked = copy(blocked)
    Z = nullspace(Matrix(S[:, .!blocked]))
    blocked = [norm(Z[j, :]) < norm(S, 2)*eps(Float64) for j in 1:size(Z, 1)]
    finalBlocked[.!finalBlocked] = blocked
    S = S[:, .!finalBlocked]
    rev = rev[.!finalBlocked] 
    S = unique(S, dims = 1)
    Z = Z[.!blocked, :]
    X = Z*Z'
    Y = Diagonal(diag(X).^(-1//2))
    Y = Y*X*Y
    X = Y.^2 .≈ 1
    fc = unique(X, dims = 1)
    for i in 1:size(fc, 1)
        if any(rev[fc[i,:]]) && any(.!rev[fc[i,:]])
            rev[fc[i,:]]' .= false
            index = findfirst(.!rev[fc[i,:]])
            for j in findall(fc[i,:])
                if Y[index,j] .≈ -1
                    S[:, j] = -S[:, j]
                    Y[:, j] = -Y[:, j]
                    Y[j, :] = -Y[j, :]
                end
            end
        end
    end   
    fullModel = Model(solver = GLPKSolverLP())
    m, n = size(S)
    ub = [fill(Inf, m); fill(0.0, n)]
    lb = -copy(ub)
    @variable(fullModel, lb[j] <= x[j=1:m+n] <= ub[j])
    A = [S' -sparse(I, n, n)]
    for j in 1:n
        if rev[j]
            @constraint(fullModel, sum{A[j,k]*x[k], k=1:m+n} == 0.0)
        else
            @constraint(fullModel, sum{A[j,k]*x[k], k=1:m+n} <= 0.0)
        end
    end
    fctable = zeros(n, n)
    certificates = Array{Float64,2}(undef, n, n)
    for i in 1:size(fc, 1)
        indices = findall(fc[i,:])
        for j in 1:n
            setupperbound(x[m + j], in(j, indices) ? Inf : 0.0)
            setlowerbound(x[m + j], in(j, indices) ? -Inf : (rev[j] ? 0.0 : -1.0))
        end
        @objective(fullModel, Min, sum{x[j], j = [m + j for j in 1:n if !(in(j, indices) || rev[j])]})
        status = solve(fullModel)
        result = getvalue(x)[m+1:end]
        blocked = [!in(j, indices) && result[j] ≈ -1 for j = 1:n]
        if any(blocked)
            index = indices[findmax(result[indices].^2)[2]]
            if rev[index]
                for j in indices
                    if j == index
                        setupperbound(x[m + j], sign(result[j]))
                        setlowerbound(x[m + j], sign(result[j]))
                    else
                        setupperbound(x[m + j], 0)
                        setlowerbound(x[m + j], 0)
                    end
                end
                @objective(fullModel, Max, sum{x[k]*S[k,j], k=1:m, j=findall(blocked)})
                status = solve(fullModel)
                certificate = getvalue(x)[1:m]
            else
                sparseModel = Model(solver = GLPKSolverLP())
                @variable(sparseModel, y[j=1:m])
                for j in 1:n
                    if j == index
                        @constraint(sparseModel, sum{y[k]*S[k,j], k=1:m} == sign(result[j]))
                    elseif blocked[j]
                        @constraint(sparseModel, sum{y[k]*S[k,j], k=1:m} <= 0)
                    else
                        @constraint(sparseModel, sum{y[k]*S[k,j], k=1:m} == 0)
                    end
                end
                @objective(sparseModel, Max, sum{y[k]*S[k,j], k=1:m, j=findall(blocked)})
                status = solve(sparseModel)
                certificate = getvalue(y)
            end
            blocked = [in(j, indices) || result[j] ≈ -1 for j = 1:n]
            temp = sum(.!blocked)
            Y = sparse(I, temp, temp)/Matrix(S[:, .!blocked])
            Y = Y*Matrix(S[:, .!blocked]) - sparse(I, temp, temp)
            blocked[.!blocked] = [norm(Y[:, j]) < norm(S[:, .!blocked], 2)*eps(Float64) for j in 1:temp]
        else
            certificate = getvalue(x)[1:m]
        end
        certificates[:, indices] .= S'*certificate
        coupled = findall(blocked)
        fctable[coupled, indices] .= [fctable[indices[1], j] == 3 ? 2 : 3 for j in coupled]
        fctable[indices, coupled] .= [fctable[indices[1], j] == 3 ? 2 : 4 for j in coupled]'
    end
    fctable[X] .= 1
    return certificates, finalBlocked, fctable
end
                                    
end