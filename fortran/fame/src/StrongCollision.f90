! ==============================================================================
!
! 	StrongCollision.f90
!
! 	Written by Josh Allen (jwallen@mit.edu)
!
! ==============================================================================

module StrongCollisionModule

	use SimulationModule
	use IsomerModule
	use ReactionModule

	implicit none
	
contains

	! --------------------------------------------------------------------------
	
	! Subroutine: ssmscRates()
	! 
	! Uses the steady state/modified strong collision approach of Chang,
	! Bozzelli, and Dean to estimate the phenomenological rate coefficients 
	! from a full ME matrix for the case of a chemically activated system.
	!
	! Parameters:
	!
	subroutine ssmscRates(simData, uniData, multiData, rxnData, Kij, Fim, Gnj, Jnm, bi, bn, K)

		! Provide parameter type checking of inputs and outputs
		type(Simulation), intent(in)				:: 	simData
		type(Isomer), dimension(:), intent(in)		:: 	uniData
		type(Isomer), dimension(:), intent(in)	:: 	multiData
		type(Reaction), dimension(:), intent(in)	:: 	rxnData
		real(8), dimension(:,:,:), intent(in)		:: 	Kij
		real(8), dimension(:,:,:), intent(in)		:: 	Fim
		real(8), dimension(:,:,:), intent(in)		:: 	Gnj
		real(8), dimension(:,:,:), intent(in)		:: 	Jnm
		real(8), dimension(:,:), intent(in)			:: 	bi
		real(8), dimension(:,:), intent(in)			:: 	bn
		real(8), dimension(:,:), intent(out) 		:: 	K
		
		real(8), dimension(:,:), allocatable		:: 	ai
		real(8), dimension(:,:), allocatable		:: 	an
		
		
		! Steady-state populations
		real(8), dimension(:,:), allocatable	:: 	p
		
		! Steady-state matrix and vector
		real(8), dimension(:,:), allocatable	:: 	A
		real(8), dimension(:), allocatable		:: 	b
		! Collision frequency and efficiency
		real(8), dimension(:), allocatable				::	w
		real(8) eps, mu
		! Gas concentration
		real(8) gasConc
		! Number of active-state energy grains for each unimolecular isomer
		integer, dimension(:), allocatable				:: 	nAct
		! Indices i and j represent sums over unimolecular wells
		integer											::	i, j
		! Indices m and n represent sums over bimolecular sources/sinks
		integer											::	m, n
		! Indices r and s represent sums over energy grains
		integer											::	r, s
		! Variables for BLAS and LAPACK
		integer, dimension(:), allocatable				::	iPiv
		integer											::	info
		integer	src, start
		real(8)	temp
		
		! Gas concentration in molecules/m^3
		gasConc = simData%P * 1e5 / 1.381e-23 / simData%T

		! Renormalize equilibrium distributions
		allocate( ai(1:simData%nGrains, 1:simData%nUni) )
		allocate( an(1:simData%nGrains, 1:simData%nMulti) )
		do i = 1, simData%nUni
    		ai(:,i) = bi(:,i) / sum(bi(:,i))
		end do
        do n = 1, simData%nMulti
    		an(:,n) = bn(:,n) / sum(bn(:,n))
		end do
		
		! Determine collision frequency for each isomer
		allocate( w(1:simData%nUni) )
		do i = 1, simData%nUni
			mu = 1.0 / ( 1.0 / uniData(i)%MW(1) + 1.0 / simData%bathGas%MW ) / 6.022e26
			call collisionFrequency(simData%T, 0.5 * (uniData(i)%sigma(1) + simData%bathGas%sigma), &
				0.5 * (uniData(i)%eps(1) + simData%bathGas%eps), mu, gasConc, w(i))
		end do
		
		! Zero rate coefficient matrix
		do i = 1, simData%nUni + simData%nMulti
			do j = 1, simData%nUni + simData%nMulti
				K(i,j) = 0.0
			end do
		end do
		
		! Find steady-state populations at each grain
		allocate( A(1:simData%nUni, 1:simData%nUni) )
		allocate( b(1:simData%nUni) )
		allocate( iPiv(1:simData%nUni) )
		allocate( p(1:simData%nGrains, 1:simData%nUni) )
			
		do src = 1, simData%nUni+simData%nMulti

			! Determine collision efficiency
			eps = collisionEfficiency(simData, uniData, rxnData, src)

			! Determine starting grain
			start = activeSpaceStart(simData, uniData, rxnData, src)
			
			do r = 1, start-1
				do i = 1, simData%nUni
					p(r,i) = 0.0
				end do
			end do
			
			do r = start, simData%nGrains

				! Zero A matrix and b vector
				do i = 1, simData%nUni
					do j = 1, simData%nUni
						A(i,j) = 0.0
					end do
					b(i) = 0.0
				end do
				
				! Collisional deactivation
				do i = 1, simData%nUni
					A(i,i) = - eps * w(i)
				end do
				
				! Isomerization
				do i = 1, simData%nUni
					do j = 1, simData%nUni
						if (i /= j) then
							A(i,j) = Kij(r,i,j)
							A(i,i) = A(i,i) - Kij(r,j,i)
						end if
					end do
				end do

				! Dissociation
				do i = 1, simData%nUni
					do n = 1, simData%nMulti
						A(i,i) = A(i,i) - Gnj(r,n,i)
						b(i) = 0.0
					end do
				end do
				
				! Activation
				if (src > simData%nUni) then
					n = src - simData%nUni
					do i = 1, simData%nUni
						b(i) = Fim(r,i,n) * an(r,n)
					end do
				else
					b(src) = eps * w(src) * ai(r,src)
				end if
				
				! Solve for steady-state population
				call DGESV( simData%nUni, 1, A, simData%nUni, iPiv, b, simData%nUni, info )
				if (info > 0) then
					write (*,*), "A singular matrix was encountered! Aborting."
					stop
				end if
				p(r,:) = -b
				
			end do
			
			! Calculate rates
			
			! Stabilization rates (i.e.) R + R' --> Ai or M --> Ai
			do i = 1, simData%nUni
				if (i /= src) then
					temp = eps * w(i) * sum(p(:,i))
					K(i,src) = K(i,src) + temp
					K(src,src) = K(src,src) - temp
				end if
			end do
			
			! Dissociation rates (i.e.) R + R' --> Bn + Cn or M --> Bn + Cn
			do i = 1, simData%nUni
				do n = 1, simData%nMulti
					if (n /= src - simData%nUni .and. Gnj(simData%nGrains,n,i) > 0) then
						temp = sum(Gnj(:,n,i) * p(:,i))
						K(n+simData%nUni,src) = K(n+simData%nUni,src) + temp
						K(src,src) = K(src,src) - temp
					end if
				end do
			end do
			
		end do

		! Clean up
		deallocate( w, A, b, iPiv, p, ai, an )

	end subroutine

	! --------------------------------------------------------------------------

	! collisionFrequency() 
	!
	!   Computes the Lennard-Jones (12-6) collision frequency.
	!
	! Input:
	!   T = absolute temperature in K
	!   sigma = effective Lennard-Jones well-minimum parameter for collision in m
	!   eps = effective Lennard-Jones well-depth parameter for collision in J
	!   mu = reduced mass of molecules involved in collision in kg
	!   Na = molecules of A per m^3
	!
	! Output:
	!   omega = collision frequency in molecules m^-3 s^-1
	!
	subroutine collisionFrequency(T, sigma, eps, mu, Na, omega)
	
		! Provide parameter type-checking
		real(8), intent(in)					:: 	T
		real(8), intent(in)					:: 	sigma
		real(8), intent(in)					:: 	eps
		real(8), intent(in)					:: 	mu
		real(8), intent(in)					:: 	Na
		real(8), intent(out)				:: 	omega
		
		real(8)		:: kB = 1.3806504e-23
		real(8)		:: collisionIntegral
		
		collisionIntegral = 1.16145 / T**0.14874 + 0.52487 / exp(0.77320 * T) + 2.16178 / exp(2.43787 * T) &
			-6.435/10000 * T**0.14874 * sin(18.0323 * T**(-0.76830) - 7.27371)
    
		! Evaluate collision frequency
		omega = collisionIntegral *	sqrt(8 * kB * T / 3.141592654 / mu) * 3.141592654 * sigma**2 * Na
	
	end subroutine
	
	! --------------------------------------------------------------------------

	! collisionEfficiency() 
	!
	!   Computes the fraction of collisions that result in deactivation.
	!
	function collisionEfficiency(simData, uniData, rxnData, src)
	
		! Provide parameter type checking of inputs and outputs
		type(Simulation), intent(in)				:: 	simData
		type(Isomer), dimension(:), intent(in)		:: 	uniData
		type(Reaction), dimension(:), intent(in)	:: 	rxnData
		integer, intent(in)							:: 	src
		real(8)										::	collisionEfficiency
		
		real(8) E0
		integer t
		
		if (src > simData%nUni) then
			collisionEfficiency = 0.38
		else

			collisionEfficiency = 0.38

! 			E0 = simData%Emax
! 			do t = 1, size(rxnData)
! 				if (rxnData(t)%isomer(1) == src .or. rxnData(t)%isomer(2) == src) then
! 					if (rxnData(t)%E < E0) E0 = rxnData(t)%E
! 				end if
! 			end do
! 
! 			collisionEfficiency = efficiency(simData%T, &
! 				simData%alpha * (1000 / 6.022e23), &
! 				uniData(src)%densStates / (1000 / 6.022e23), &
! 				simData%E * (1000 / 6.022e23), &
! 				E0 * (1000 / 6.022e23))
			
		end if
	
	end function
	
	! --------------------------------------------------------------------------
	! 
	! efficiency() 
	!
	!   Computes the fraction of collisions that result in deactivation. All
	!	parameters are assumed to be in SI units.
	!
	function efficiency(T, alpha, rho, E, E0)

		! Provide parameter type checking of inputs and outputs
		real(8), intent(in)					:: 	T
		real(8), intent(in)					:: 	alpha
		real(8), dimension(:), intent(in)	:: 	rho
		real(8), dimension(:), intent(in)	:: 	E
		real(8), intent(in)					:: 	E0
		real(8)								::	efficiency
		
		real(8) kB, Delta, dE
		real(8) Fe, FeNum, FeDen
		real(8) Delta1, Delta2, DeltaN
		real(8) temp
		integer r
		
		kB = 1.381e-23						! [=] J/K
		Delta = 1
		dE = E(2) - E(1)					! [=] J

		FeNum = 0
		FeDen = 0
		do r = 1, size(E)
			temp = rho(r) * exp(-E(r) / kB / T) * dE
			if (E(r) > E0) then
				FeNum = FeNum + temp * dE
				if (FeDen == 0) FeDen = temp * kB * T
			end if
		end do

		Fe = FeNum / FeDen

		Delta1 = 0
		Delta2 = 0
		DeltaN = 0
		do r = 1, size(E)
			temp = rho(r) * exp(-E(r) / kB / T) * dE
			if (E(r) < E0) then
				Delta1 = Delta1 + temp * dE
				Delta2 = Delta2 + temp * exp(-(E0 - E(r)) / (Fe * kB * T)) * dE
			end if
			DeltaN = DeltaN + temp * dE
		end do
		Delta1 = Delta1 / DeltaN
		Delta2 = Delta2 / DeltaN

		Delta = Delta1 - (Fe * kB * T) / (alpha + Fe * kB * T) * Delta2
		
		efficiency = (alpha / (alpha + Fe * kB * T))**2 / Delta
		write (*,*), FeNum, FeDen, Fe, Delta, efficiency
		
	end function
	
	! --------------------------------------------------------------------------

	! Subroutine: activeSpaceStart()
	! 
	! Determines the grain below which the reservoir approximation will be used
	! and above which the pseudo-steady state approximation will be used by
	! examining the energies of the transition states connected to each 
	! unimolecular isomer.
	!
	! Parameters:
	!   simData - The simulation parameters.
	!   uniData - The chemical data about each unimolecular isomer.
	!   rxnData - The chemical data about each transition state.
	!
	! Returns:
	!	nRes - The reservoir cutoff grains for each unimolecular isomer.
	function activeSpaceStart(simData, uniData, rxnData, well)
	
		type(Simulation), intent(in)				:: 	simData
		type(Isomer), dimension(:), intent(in)		:: 	uniData
		type(Reaction), dimension(:), intent(in)	:: 	rxnData
		integer, intent(in)							::	well
		integer										::	activeSpaceStart
		
		real(8) Eres
		
		integer t, start
		
		start = simData%nGrains
		
		Eres = simData%Emax
		do t = 1, simData%nRxn
			if (rxnData(t)%isomer(1) == well .or. rxnData(t)%isomer(2) == well) then
				if (rxnData(t)%E < Eres) Eres = rxnData(t)%E
			end if
		end do
		activeSpaceStart = ceiling((Eres - simData%Emin) / simData%dE) + 1

	end function
	
	! --------------------------------------------------------------------------

end module
