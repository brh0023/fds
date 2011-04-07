MODULE FIRE
 
! Compute combustion 
 
USE PRECISION_PARAMETERS
USE GLOBAL_CONSTANTS
USE MESH_POINTERS
USE COMP_FUNCTIONS, ONLY: SECOND
 
IMPLICIT NONE
PRIVATE
CHARACTER(255), PARAMETER :: fireid='$Id$'
CHARACTER(255), PARAMETER :: firerev='$Revision$'
CHARACTER(255), PARAMETER :: firedate='$Date$'

TYPE(REACTION_TYPE), POINTER :: RN=>NULL()
REAL(EB) :: Q_UPPER

PUBLIC COMBUSTION, GET_REV_fire
 
CONTAINS
 

SUBROUTINE COMBUSTION(NM)

INTEGER, INTENT(IN) :: NM
REAL(EB) :: TNOW

IF (EVACUATION_ONLY(NM)) RETURN

TNOW=SECOND()

IF (INIT_HRRPUV) RETURN

CALL POINT_TO_MESH(NM)

! Upper bounds on local HRR per unit volume

Q_UPPER = HRRPUA_SHEET/CELL_SIZE + HRRPUV_AVERAGE

! Call combustion ODE solver

CALL COMBUSTION_SOLVER

TUSED(10,NM)=TUSED(10,NM)+SECOND()-TNOW

END SUBROUTINE COMBUSTION



SUBROUTINE COMBUSTION_SOLVER

USE PHYSICAL_FUNCTIONS, ONLY : GET_SPECIFIC_GAS_CONSTANT,GET_AVERAGE_SPECIFIC_HEAT
REAL(EB) :: Y_FU_0,Y_P_0,Y_LIMITER,Y_O2_0,DYF,DELTA, & 
            Q_NEW,O2_F_RATIO,Q_BOUND_1,Q_BOUND_2,ZZ_GET(0:N_TRACKED_SPECIES), &
            DYAIR,TAU_D,TAU_U,TAU_G,EPSK,KSGS,CPBAR_F_0,CPBAR_F_N,CPBAR_G_0,CPBAR_G_N,&
            DUDX,DUDY,DUDZ,DVDX,DVDY,DVDZ,DWDX,DWDY,DWDZ,SS2,S12,S13,S23
REAL(EB), PARAMETER :: Y_FU_MIN=1.E-10_EB,Y_O2_MIN=1.E-10_EB
INTEGER :: I,J,K,IC,ITMP,N,II,JJ,KK,IW,IIG,JJG,KKG
REAL(EB), POINTER, DIMENSION(:,:,:) :: UU=>NULL(),VV=>NULL(),WW=>NULL()

! Misc initializations

RN => REACTION(1)
O2_F_RATIO = RN%NU(0)     *SPECIES(O2_INDEX)%MW  *SPECIES_MIXTURE(0)%VOLUME_FRACTION(O2_INDEX)/ &
            (RN%NU(I_FUEL)*SPECIES(FUEL_INDEX)%MW*SPECIES_MIXTURE(I_FUEL)%VOLUME_FRACTION(FUEL_INDEX))

UU => US
VV => VS
WW => WS

!$OMP PARALLEL DEFAULT(NONE) & 
!$    SHARED(MIX_TIME,DT,Q,D_REACTION, &
!$           IBAR,KBAR,JBAR,CELL_INDEX,SOLID,I_FUEL,SPECIES_MIXTURE,FUEL_INDEX,O2_INDEX,ZZ,I_PRODUCTS, &
!$           RN,Y_P_MIN_EDC,SUPPRESSION,TMP,O2_F_RATIO,N_TRACKED_SPECIES, &
!$           USE_MAX_FILTER_WIDTH,DX,DY,DZ,TWO_D,LES,SC,RHO,MU,RDX,RDY,RDZ,UU,VV,WW,PI,GRAV, &
!$           TAU_CHEM,TAU_FLAME,D_Z,FIXED_MIX_TIME,BETA_EDC,Q_UPPER,RSUM, &
!$           N_EXTERNAL_WALL_CELLS,BOUNDARY_TYPE,IJKW)


!$OMP WORKSHARE
MIX_TIME   = DT
Q          = 0._EB
D_REACTION = 0._EB
!$OMP END WORKSHARE

!$OMP DO COLLAPSE(3) SCHEDULE(DYNAMIC) &
!$    PRIVATE(K,J,I,IC,Y_FU_0,Y_O2_0,Y_P_0,DYF,ZZ_GET,CPBAR_F_0,CPBAR_F_N,CPBAR_G_0,CPBAR_G_N,DYAIR,DELTA, &
!$            TAU_D,DUDX,DUDY,DUDZ,DVDX,DVDY,DVDZ,DWDX,DWDY,DWDZ,S12,S13,S23,SS2,EPSK,KSGS,TAU_U,TAU_G,ITMP, &
!$            Y_LIMITER,Q_BOUND_1,Q_BOUND_2,Q_NEW,N)
DO K=1,KBAR
   DO J=1,JBAR
      DO I=1,IBAR

         IC = CELL_INDEX(I,J,K)
         IF (SOLID(IC)) CYCLE

         Y_FU_0  = ZZ(I,J,K,I_FUEL)*SPECIES_MIXTURE(I_FUEL)%MASS_FRACTION(FUEL_INDEX)
         IF (Y_FU_0<=Y_FU_MIN) CYCLE
         Y_O2_0  = (1._EB-SUM(ZZ(I,J,K,:)))*SPECIES_MIXTURE(0)%MASS_FRACTION(O2_INDEX)
         IF (Y_O2_0<=Y_O2_MIN) CYCLE
         Y_P_0 = ZZ(I,J,K,I_PRODUCTS)*RN%NU(I_FUEL)*SPECIES_MIXTURE(I_FUEL)%MW/&
                                     (RN%NU(I_FUEL)*SPECIES_MIXTURE(I_FUEL)%MW+RN%NU(0)*SPECIES_MIXTURE(0)%MW)
         Y_P_0 = MAX(Y_P_MIN_EDC,Y_P_0)

         IF_SUPPRESSION: IF (SUPPRESSION) THEN

            ! Evaluate empirical extinction criteria

            IF (TMP(I,J,K) < RN%AUTO_IGNITION_TEMPERATURE) CYCLE
            DYF = MIN(Y_FU_0,Y_O2_0/O2_F_RATIO) 
            ZZ_GET = 0._EB
            ZZ_GET(I_FUEL) = 1._EB
            CALL GET_AVERAGE_SPECIFIC_HEAT(ZZ_GET,CPBAR_F_0,TMP(I,J,K)) 
            CALL GET_AVERAGE_SPECIFIC_HEAT(ZZ_GET,CPBAR_F_N,RN%CRIT_FLAME_TMP)
            ZZ_GET(1:N_TRACKED_SPECIES) = ZZ(I,J,K,1:N_TRACKED_SPECIES)
            ZZ_GET(I_FUEL) = 0._EB
            ZZ_GET = ZZ_GET / (1._EB - Y_FU_0)
            CALL GET_AVERAGE_SPECIFIC_HEAT(ZZ_GET,CPBAR_G_0,TMP(I,J,K)) 
            CALL GET_AVERAGE_SPECIFIC_HEAT(ZZ_GET,CPBAR_G_N,RN%CRIT_FLAME_TMP) 
            DYAIR = DYF * (1._EB - Y_FU_0) / Y_O2_0 * O2_F_RATIO
            IF ( (DYF*CPBAR_F_0 + DYAIR*CPBAR_G_0)*TMP(I,J,K) + DYF*RN%HEAT_OF_COMBUSTION < &
                 (DYF*CPBAR_F_N + DYAIR*CPBAR_G_N)*RN%CRIT_FLAME_TMP) CYCLE

         ENDIF IF_SUPPRESSION

         IF (USE_MAX_FILTER_WIDTH) THEN
            DELTA=MAX(DX(I),DY(J),DZ(K))
         ELSE
            IF (.NOT.TWO_D) THEN
               DELTA = (DX(I)*DY(J)*DZ(K))**ONTH
            ELSE
               DELTA = SQRT(DX(I)*DZ(K))
            ENDIF
         ENDIF

         LES_IF: IF (LES) THEN

            TAU_D = SC*RHO(I,J,K)*DELTA**2/MU(I,J,K)   ! diffusive time scale         
            
            ! compute local filtered strain

            DUDX = RDX(I)*(UU(I,J,K)-UU(I-1,J,K))
            DVDY = RDY(J)*(VV(I,J,K)-VV(I,J-1,K))
            DWDZ = RDZ(K)*(WW(I,J,K)-WW(I,J,K-1))
            DUDY = 0.25_EB*RDY(J)*(UU(I,J+1,K)-UU(I,J-1,K)+UU(I-1,J+1,K)-UU(I-1,J-1,K))
            DUDZ = 0.25_EB*RDZ(K)*(UU(I,J,K+1)-UU(I,J,K-1)+UU(I-1,J,K+1)-UU(I-1,J,K-1)) 
            DVDX = 0.25_EB*RDX(I)*(VV(I+1,J,K)-VV(I-1,J,K)+VV(I+1,J-1,K)-VV(I-1,J-1,K))
            DVDZ = 0.25_EB*RDZ(K)*(VV(I,J,K+1)-VV(I,J,K-1)+VV(I,J-1,K+1)-VV(I,J-1,K-1))
            DWDX = 0.25_EB*RDX(I)*(WW(I+1,J,K)-WW(I-1,J,K)+WW(I+1,J,K-1)-WW(I-1,J,K-1))
            DWDY = 0.25_EB*RDY(J)*(WW(I,J+1,K)-WW(I,J-1,K)+WW(I,J+1,K-1)-WW(I,J-1,K-1))
            S12 = 0.5_EB*(DUDY+DVDX)
            S13 = 0.5_EB*(DUDZ+DWDX)
            S23 = 0.5_EB*(DVDZ+DWDY)
            SS2 = 2._EB*(DUDX**2 + DVDY**2 + DWDZ**2 + 2._EB*(S12**2 + S13**2 + S23**2))
            
            ! ke dissipation rate, assumes production=dissipation

            EPSK = MU(I,J,K)*(SS2-TWTH*(DUDX+DVDY+DWDZ)**2)/RHO(I,J,K)

            KSGS = 2.25_EB*(EPSK*DELTA/PI)**TWTH  ! estimate of subgrid ke, from Kolmogorov spectrum

            TAU_U = DELTA/SQRT(2._EB*KSGS+1.E-10_EB)   ! advective time scale
            TAU_G = SQRT(2._EB*DELTA/(GRAV+1.E-10_EB)) ! acceleration time scale

            MIX_TIME(I,J,K)=MAX(TAU_CHEM,MIN(TAU_D,TAU_U,TAU_G,TAU_FLAME)) ! Eq. 7, McDermott, McGrattan, Floyd
         ELSE LES_IF
            ITMP = MIN(4999,NINT(TMP(I,J,K)))
            TAU_D = D_Z(ITMP,I_FUEL)
            TAU_D = DELTA**2/TAU_D
            MIX_TIME(I,J,K)= TAU_D
         ENDIF LES_IF
         
         IF (FIXED_MIX_TIME>0._EB) MIX_TIME(I,J,K)=FIXED_MIX_TIME
         
         Y_LIMITER = MIN(Y_FU_0, Y_O2_0/O2_F_RATIO, BETA_EDC*Y_P_0)
         DYF = Y_LIMITER*(1._EB-EXP(-DT/MIX_TIME(I,J,K)))
         Q_BOUND_1 = DYF*RHO(I,J,K)*RN%HEAT_OF_COMBUSTION/DT
         Q_BOUND_2 = Q_UPPER
         Q_NEW = MIN(Q_BOUND_1,Q_BOUND_2)
         DYF = Q_NEW*DT/(RHO(I,J,K)*RN%HEAT_OF_COMBUSTION)
         
         Q(I,J,K)  = Q_NEW

         DO N=1,N_TRACKED_SPECIES
            ZZ(I,J,K,N) = ZZ(I,J,K,N) + DYF*RN%NU(N)*SPECIES_MIXTURE(N)%MW/SPECIES_MIXTURE(I_FUEL)%MW
         ENDDO

         ! Compute new mixture molecular weight

         ZZ_GET(1:N_TRACKED_SPECIES) = ZZ(I,J,K,1:N_TRACKED_SPECIES)
         CALL GET_SPECIFIC_GAS_CONSTANT(ZZ_GET,RSUM(I,J,K)) 

      ENDDO
   ENDDO
ENDDO
!$OMP END DO

! Set Q in the ghost cell, just for better visualization.

!$OMP DO SCHEDULE(DYNAMIC) &
!$    PRIVATE(IW,II,JJ,KK,IIG,JJG,KKG)
DO IW=1,N_EXTERNAL_WALL_CELLS
   IF (BOUNDARY_TYPE(IW)/=INTERPOLATED_BOUNDARY .AND. BOUNDARY_TYPE(IW)/=OPEN_BOUNDARY) CYCLE
   II  = IJKW(1,IW)
   JJ  = IJKW(2,IW)
   KK  = IJKW(3,IW)
   IIG = IJKW(6,IW)
   JJG = IJKW(7,IW)
   KKG = IJKW(8,IW)
   Q(II,JJ,KK) = Q(IIG,JJG,KKG)
ENDDO
!$OMP END DO NOWAIT

!$OMP END PARALLEL

END SUBROUTINE COMBUSTION_SOLVER



SUBROUTINE GET_REV_fire(MODULE_REV,MODULE_DATE)
INTEGER,INTENT(INOUT) :: MODULE_REV
CHARACTER(255),INTENT(INOUT) :: MODULE_DATE

WRITE(MODULE_DATE,'(A)') firerev(INDEX(firerev,':')+1:LEN_TRIM(firerev)-2)
READ (MODULE_DATE,'(I5)') MODULE_REV
WRITE(MODULE_DATE,'(A)') firedate

END SUBROUTINE GET_REV_fire
 
END MODULE FIRE

