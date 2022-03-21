using Dierckx

struct QuadraticForcedMeltRate{T <: Real} <: AbstractMeltRate
    γT :: T                       #(calibrated) heat exchange velocity
    λ1 :: T                       #liquidus slope 
    λ2 :: T                       #liquidus intercept 
    λ3 :: T                       #liquidus pressure coefficient
    ρi :: T                       #ice density 
    ρw :: T                       #water density
    L :: T                        #latent heat of fusion for ice 
    c :: T                        #specific heat capacity of ocean water 
    TaSpline :: Spline2D                #ambient temperature spline
    SaSpline :: Spline2d                #ambient salinity spline
    flocal :: Bool                #Flag for local or non-local temperature dependence
    melt_partial_cell :: Bool     #Flag for melting applied to partial cells or not
end

"""
    QuadraticForcedMeltRate(; ,kwargs)

Construct a QuadraticForcedMeltRate object to prescribe the melt rate in WAVI. 
Pass a set of reference times tref (size (N x 1)) and depths zref (size (1 x M)), and reference ambient temperature Ta (size (N x M)) and salinity Sa (size (N x M))
We compute the ambient profiles at a depth z1 and time t1 by interpolating from the reference values.
e.g. if t1 corresponds to the ith entry in tref and z1 corresponds to the jth entry in zref, then Ta and Sa at this depth and time are Ta(i,j) and Sa(i,j), resp. 
For values which don't match exactly, we use linear interpolation. For (t,z) pairs outside of domain (tref, zref), we take the nearest value in the domain (not recommended!)

Keyword arguments 
=================
- γT: (calibrated) heat exchange velocity (units m/s).
- λ1: liquidus slope (units ∘C)
- λ2: liquidus intercept (units ∘C)
- λ3: liquidus pressure coefficient (units K/m)
- ρi: ice density (units kg/m^3)
- ρw: water density (units kg/m^3)
- L: latent heat of fusion for ice (units: J/kg)
- c: specific heat capacity of water (units J/kg/K)
- tref: reference time co-ordinates, size (N x 1)
- zref: reference z co-ordinates, size (1 x M)
- Ta:   reference ambient temperature, size (M x N) 
- Ta:   reference ambient salinity, size (M x N) 
- flocal: flag for local or non-local temperature dependence. Set to true for local dependence (eqn 4 in Favier 2019 GMD) or false for non-local dependence (eqn 5)
- melt_partial_cell: flag for specify whether to apply melt on partially floating cells (true) or not (false)
"""

function QuadraticTimeDepMeltRate(;
                            γT = 1.e-3,
                            λ1 = -5.73e-2,
                            λ2 = 8.32e-4,
                            λ3 = 7.61e-4,
                            L = 3.35e5,
                            c = 3.974e3,
                            ρi = 918.8,
                            ρw = 1028.0,
                            zref = nothing,
                            tref = nothing,
                            Ta = nothing,
                            Sa = nothing,
                            flocal = true,
                            melt_partial_cell = false)

    # Check that reference values are passed
    ~(Sa === nothing) || throw(ArgumentError("Must pass reference salinity"))
    ~(Ta === nothing) || throw(ArgumentError("Must pass reference temperature"))
    ~(zref === nothing) || throw(ArgumentError("Must pass reference depths"))
    ~(tref === nothing) || throw(ArgumentError("Must pass reference times"))

    #check sizes of input variables
    (size(Ta) == (length(tref), length(zref))) || throw(DimensionMismatch("size of reference ambient temperature must be (length(tref), length(zref)"))
    (size(Sa) == (length(tref), length(zref))) || throw(DimensionMismatch("size of reference ambient temperature must be (length(tref), length(zref)"))

    #make splines of ambient temperature and salinity profiles
    TaSpline = Spline2D(tref, zref, Ta)
    SaSpline = Spline2D(tref, zref, Sa)

    return QuadraticForcedMeltRate(γT, λ1, λ2, λ3, ρi, ρw, L, c, TaSpline, SaSpline, flocal, melt_partial_cell)
end


"""
    update_melt_rate!(quad_melt_rate::QuadraticForcedMeltRate, fields, grid, clock)

Wrapper script to update the melt rate for a QuadraticForcedMeltRate.
"""
function update_melt_rate!(quad_melt_rate::QuadraticForcedMeltRate, fields, grid, clock)
    @unpack basal_melt, h, b, grounded_fraction = fields.gh #get the ice thickness and grounded fraction
 
    #compute the ice draft
    zb = fields.gh.b .* (grounded_fraction .== 1) + - quad_melt_rate.ρi / quad_melt_rate.ρw .* fields.gh.h .* (grounded_fraction .< 1)

    set_quadratic_forced_melt_rate!(basal_melt,
                            quad_melt_rate,
                            zb, 
                            grounded_fraction,
                            clock.time)
    return nothing
end


function set_quadratic_forced_melt_rate!(basal_melt,
                                            qmr,
                                            zb, 
                                            grounded_fraction,
                                            t)

    #compute ambient temperature and salinity on the shelf
    Sa_shelf = qmr.SaSpline.(t,zb)
    Ta_shelf = qmr.TaSpline.(t,zb)

    #compute thermal driving
    Tstar = qmr.λ1 .* Sa_shelf .+ qmr.λ2 .+ qmr.λ3 .* zb .- Ta_shelf
    Tstar_shelf_mean = sum(Tstar[grounded_fraction .== 0])/length(Tstar[grounded_fraction .== 0])

    #set melt rate
    if (qmr.melt_partial_cell) && (qmr.flocal) #partial cell melting and local 
        basal_melt[:] .=  qmr.γT .* (qmr.ρw * qmr.c / qmr.ρi /qmr.L)^2 .* Tstar[:].^2 .* (1 .- grounded_fraction[:])
        
    elseif ~(qmr.melt_partial_cell) && (qmr.flocal) #no partial cell melting and local
        basal_melt[grounded_fraction .== 0] .=  qmr.γT .* (qmr.ρw * qmr.c / qmr.ρi /qmr.L)^2 .* Tstar[grounded_fraction .== 0].^2
        basal_melt[.~(grounded_fraction .== 0)] .= 0 

    elseif (qmr.melt_partial_cell) && ~(qmr.flocal) #partial cell melting and non-local 
        basal_melt[:] .=  qmr.γT .* (qmr.ρw * qmr.c / qmr.ρi /qmr.L)^2 .* Tstar[:].^2 .* (1 .- grounded_fraction[:])

    elseif ~(qmr.melt_partial_cell) && ~(qmr.flocal) #no partial cell and non-local
        basal_melt[grounded_fraction .== 0] .=  qmr.γT .* (qmr.ρw * qmr.c / qmr.ρi /qmr.L)^2 .* Tstar[grounded_fraction .== 0] .* Tstar_shelf_mean
        basal_melt[.~(grounded_fraction .== 0)] .= 0 
    end
    basal_melt[:] .= basal_melt[:].* 365.25*24*60*60
    return nothing
end
