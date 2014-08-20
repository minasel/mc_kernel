!=========================================================================================
module source_class

    use global_parameters,               only : sp, dp, pi, deg2rad, rad2deg, verbose, &
                                                lu_out
    use commpi,                          only : pabort
    implicit none

    private
    public   :: src_param_type
    public   :: read_srf

    type src_param_type
        real(kind=dp)   :: mij(6)              ! Mrr Mtt Mpp Mrt Mrp Mtp
        real(kind=dp)   :: mij_voigt(6)        ! Mtt Mpp Mrr Mrp Mrt Mtp
        real(kind=dp)   :: colat, lat, lon     ! in radians
        real(kind=dp)   :: colatd, latd, lond  ! in degrees
        real(kind=dp)   :: x, y, z             ! cartesian coordinates in km
        real(kind=dp)   :: depth, radius       ! in km
        real(kind=dp)   :: shift_time          ! in seconds
        real(kind=dp)   :: shift_time_sample   ! in samples (based on sampling rate of the
                                               ! netcdf file)
        real(kind=dp), allocatable           :: stf(:), stf_resampled(:)
        real(kind=dp)                        :: stf_dt, stf_dt_resampled
        real(kind=dp), dimension(3,3)        :: rot_mat, trans_rot_mat
        contains
           procedure, pass                   :: init
           procedure, pass                   :: init_xyz
           procedure, pass                   :: init_strike_dip_rake
           procedure, pass                   :: read_cmtsolution
           procedure, pass                   :: def_rot_matrix
           procedure, pass                   :: resample_stf
    end type
contains

!-----------------------------------------------------------------------------------------
!> This routine initializes the source object
subroutine init(this, lat, lon, mij, depth)
   class(src_param_type)      :: this

   real(kind=dp), intent(in)  :: lat, lon, mij(6), depth

   this%latd   = lat
   this%lond   = lon
   this%colatd = 90 - this%latd

   this%colat  = this%colatd * deg2rad
   this%lon    = this%lond   * deg2rad
   this%lat    = this%latd   * deg2rad

   this%shift_time = 0

   !TODO hardcoded earth radius for now until I know where to get earth's radius from (MvD)
   this%radius = 6371 - depth

   this%x = dcos(this%lat) * dcos(this%lon) * this%radius
   this%y = dcos(this%lat) * dsin(this%lon) * this%radius
   this%z = dsin(this%lat) * this%radius

   this%mij    = mij
   call this%def_rot_matrix()

end subroutine
!-----------------------------------------------------------------------------------------

!-----------------------------------------------------------------------------------------
!> This routine initializes the source object with cartesian coordinates
subroutine init_xyz(this, x, y, z, mij)
   class(src_param_type)      :: this

   real(kind=dp), intent(in)  :: x, y, z, mij(6)

   this%x = x
   this%y = y
   this%z = z

   this%lat   = datan2(z, dsqrt(x**2 + y**2))
   this%lon   = datan2(y, x)

   this%lond    = this%lon * rad2deg
   this%latd    = this%lat * rad2deg

   this%colatd = 90 - this%latd
   this%colat  = this%colatd * deg2rad

   this%radius = dsqrt(x**2 + y**2 + z**2)
   !TODO hardcoded earth radius for now until I know where to get earth's radius from (MvD)
   this%depth  = 6371 - this%radius

   this%shift_time = 0

   this%mij    = mij
   call this%def_rot_matrix()

end subroutine
!-----------------------------------------------------------------------------------------

!-----------------------------------------------------------------------------------------
!> This routine initializes the source object
subroutine init_strike_dip_rake(this, lat, lon, depth, strike, dip, area, tinit, rake, &
                                slip, mu)
   class(src_param_type)      :: this

   real(kind=dp), intent(in)  :: lat, lon, depth, strike, dip, area, tinit, rake, &
                                 slip, mu ! all in SI units, angles in degree
   real(kind=dp)              :: M0, phi, delta, lambda

   this%latd   = lat
   this%lond   = lon
   this%colatd = 90 - this%latd

   this%colat  = this%colatd * deg2rad
   this%lon    = this%lond   * deg2rad
   this%lat    = this%latd   * deg2rad

   this%shift_time = tinit

   !TODO hardcoded earth radius for now until I know where to get earth's radius from (MvD)
   this%radius = 6371 - depth

   this%x = dcos(this%lat) * dcos(this%lon) * this%radius
   this%y = dcos(this%lat) * dsin(this%lon) * this%radius
   this%z = dsin(this%lat) * this%radius

   M0 = slip * mu * area

   phi    = strike * deg2rad
   delta  = dip    * deg2rad
   lambda = rake   * deg2rad

   ! formulas in Udias (17.24) are in geographic system North, East, Down, which
   ! transforms to the geocentric as:
   ! Mtt =  Mxx, Mpp = Myy, Mrr =  Mzz
   ! Mrp = -Myz, Mrt = Mxz, Mtp = -Mxy
   ! voigt in tpr: Mtt Mpp Mrr Mrp Mrt Mtp

   ! M11
   this%mij_voigt(1) = - dsin(delta) * dcos(lambda) * dsin(2 * phi) &
                       - dsin(2 * delta) * dsin(phi)**2 * dsin(lambda)
   ! M22
   this%mij_voigt(2) =   dsin(delta) * dcos(lambda) * dsin(2 * phi) &
                       - dsin(2 * delta) * dcos(phi)**2 * dsin(lambda)
   ! M33
   this%mij_voigt(3) =   dsin(2 * delta) * dsin(lambda)
   ! -M23
   this%mij_voigt(4) = - dcos(phi) * dsin(lambda) * dcos(2 * delta) &
                       + dcos(delta) * dcos(lambda) * dsin(phi)
   ! M13
   this%mij_voigt(5) = - dsin(lambda) * dsin(phi) * dcos(2 * delta) &
                       - dcos(delta) * dcos(lambda) * dcos(phi)
   ! -M12
   this%mij_voigt(6) = - dsin(delta) * dcos(lambda) * dcos(2 * phi) &
                       - dsin(2 * delta) * dsin(2* phi) * dsin(lambda) / 2

   this%mij_voigt = this%mij_voigt * M0

   call this%def_rot_matrix()

end subroutine
!-----------------------------------------------------------------------------------------

!-----------------------------------------------------------------------------------------
!> This routine initializes the source object
subroutine read_cmtsolution(this, fname)
   class(src_param_type)      :: this

   character(len=*), intent(in), optional :: fname
   integer                    :: lu_cmtsolution, ioerr
   character(len=256)         :: cmtsolution_file, junk

   if (present(fname)) then
      cmtsolution_file = trim(fname)
   else
      cmtsolution_file = 'CMTSOLUTION'
   endif

   open(newunit=lu_cmtsolution, file=trim(cmtsolution_file), status='old', &
        action='read', iostat=ioerr)

   if (ioerr /= 0) then
      print *, 'ERROR: Check input file ''', trim(cmtsolution_file), '''! Is it still there?' 
      call pabort
   end if

   read(lu_cmtsolution,*) junk ! first crap line
   read(lu_cmtsolution,*) junk ! event name
   read(lu_cmtsolution,*) junk, junk, this%shift_time
   read(lu_cmtsolution,*) junk ! half duration
   read(lu_cmtsolution,*) junk, this%latd
   read(lu_cmtsolution,*) junk, this%lond
   read(lu_cmtsolution,*) junk, this%depth

   this%colatd = 90 - this%latd

   this%colat  = this%colatd * deg2rad
   this%lon    = this%lond   * deg2rad
   this%lat    = this%latd   * deg2rad

   !TODO hardcoded earth radius for now until I know where to get earth's radius from (MvD)
   this%radius = 6371 - this%depth

   this%x = dcos(this%lat) * dcos(this%lon) * this%radius
   this%y = dcos(this%lat) * dsin(this%lon) * this%radius
   this%z = dsin(this%lat) * this%radius

   read(lu_cmtsolution,*) junk, this%mij(1)
   read(lu_cmtsolution,*) junk, this%mij(2)
   read(lu_cmtsolution,*) junk, this%mij(3)
   read(lu_cmtsolution,*) junk, this%mij(4)
   read(lu_cmtsolution,*) junk, this%mij(5)
   read(lu_cmtsolution,*) junk, this%mij(6)

   this%mij = this%mij / 1e7 ! dyn cm -> Nm

   ! CMTSOLUTION : Mrr Mtt Mpp Mrt Mrp Mtp
   ! voigt in tpr: Mtt Mpp Mrr Mrp Mrt Mtp
   this%mij_voigt(1) = this%mij(2)
   this%mij_voigt(2) = this%mij(3)
   this%mij_voigt(3) = this%mij(1)
   this%mij_voigt(4) = this%mij(5)
   this%mij_voigt(5) = this%mij(4)
   this%mij_voigt(6) = this%mij(6)

   call this%def_rot_matrix()

   close(lu_cmtsolution)

end subroutine
!-----------------------------------------------------------------------------------------

!-----------------------------------------------------------------------------------------
!>  This function defines the rotation matrix to rotate coordinates to the 
!!  forward source system. Taken from AxiSEM solver.
subroutine def_rot_matrix(this)
   class(src_param_type)          :: this
   real(kind=dp)                  :: srccolat, srclon
   character(len=256)             :: fmtstring

   srccolat = this%colat
   srclon   = this%lon

   fmtstring = '("  Source colatitude: ", F8.3, "; source longitude: ", F8.3)'
  
   if (verbose > 1) write(lu_out,fmtstring) srccolat/deg2rad, srclon/deg2rad
   

   ! This is the rotation matrix of Nissen-Meyer, Dahlen, Fournier, GJI 2007.
   this%rot_mat(1,1) =  dcos(srccolat) * dcos(srclon)
   this%rot_mat(2,1) =  dcos(srccolat) * dsin(srclon)
   this%rot_mat(3,1) = -dsin(srccolat)
   this%rot_mat(1,2) = -dsin(srclon)
   this%rot_mat(2,2) =  dcos(srclon)
   this%rot_mat(3,2) =  0.d0
   this%rot_mat(1,3) =  dsin(srccolat) * dcos(srclon)
   this%rot_mat(2,3) =  dsin(srccolat) * dsin(srclon)
   this%rot_mat(3,3) =  dcos(srccolat)

   this%trans_rot_mat = transpose(this%rot_mat)

   if (verbose > 1) then
      write(lu_out,*)             '  Rotation matrix:'
      write(lu_out,'(3("  ", 3(ES11.3)/))') this%rot_mat
      write(lu_out,*)             '  Rotation matrix, transposed:'
      write(lu_out,'(3("  ", 3(ES11.3)/))') this%trans_rot_mat
   end if

end subroutine def_rot_matrix
!-----------------------------------------------------------------------------------------

!-----------------------------------------------------------------------------------------
subroutine resample_stf(this, dt, nsamp)
   class(src_param_type)          :: this
   real(kind=dp), intent(in)      :: dt
   integer, intent(in)            :: nsamp

   real(kind=dp), allocatable     :: time_orig(:), time_new(:)
   real(kind=dp)                  :: dt_orig
   integer                        :: nsamp_orig
   integer                        :: i, j

   nsamp_orig = size(this%stf)
   dt_orig = this%stf_dt

   allocate(time_orig(nsamp_orig))
   allocate(time_new(nsamp))

   if (allocated(this%stf_resampled)) deallocate(this%stf_resampled)
   allocate(this%stf_resampled(nsamp))

   this%stf_dt_resampled = dt

   do i = 1, nsamp_orig
      time_orig(i) = (i-1) * dt_orig
   enddo

   do i = 1, nsamp
      time_new(i) = (i-1) * dt
   enddo

   this%stf_resampled(:) = 0

   outer: do i = 1, nsamp
      inner: do j = 1, nsamp_orig
         if (time_new(i) <= time_orig(j)) then
            if (j < 2) then
               this%stf_resampled(i) = 0
            else
               this%stf_resampled(i) = &
                       this%stf(j-1) * (time_orig(j) - time_new(i))      / dt_orig &
                     + this%stf(j)   * (time_new(i)  - time_orig(j - 1)) / dt_orig 
            endif

            cycle outer
         endif
      enddo inner
   enddo outer

end subroutine resample_stf
!-----------------------------------------------------------------------------------------

!-----------------------------------------------------------------------------------------
subroutine read_srf(srf_file, sources, npoints, nsources)
   character(len=*), intent(in)                   :: srf_file
   type(src_param_type), allocatable, intent(out) :: sources(:)

   ! optional output for tests
   integer, intent(out), optional :: npoints, nsources

   integer                      :: lu_srf, ioerr, i
   integer                      :: npoints_loc, nsources_loc, isource
   character(len=256)           :: line, junk
   real(kind=dp)                :: lon, lat, dep, stk, dip, area, tinit, dt, &
                                   rake, slip1, slip2, slip3
   real(kind=dp)                :: minlond, maxlond, minlatd, maxlatd, mindep, maxdep
   integer                      :: nt1, nt2, nt3
   real(kind=dp), allocatable   :: sv1(:), sv2(:), sv3(:)

   open(newunit=lu_srf, file=trim(srf_file), status='old', &
        action='read', iostat=ioerr)

   if (ioerr /= 0) then
      print *, 'ERROR: Check input file ''', trim(srf_file), '''! Is it still there?' 
      call pabort
   end if

   minlond =  180
   maxlond = -180
   minlatd =  90
   maxlatd = -90
   mindep = 6371
   maxdep =    0

   ! go to POINTS block
   do
     read(lu_srf,'(a)') line
     if (index(line, 'POINTS') == 1) exit
   enddo

   read(line,*) junk, npoints_loc

   if (present(npoints)) npoints = npoints_loc

   ! count number of sources
   nsources_loc = 0

   do i=1, npoints_loc
      read(lu_srf,*) lon, lat, dep, stk, dip, area, tinit, dt
      read(lu_srf,*) rake, slip1, nt1, slip2, nt2, slip3, nt3

      if (nt1 > 0) then
         nsources_loc = nsources_loc + 1
         allocate(sv1(nt1))
         read(lu_srf,*) sv1
         deallocate(sv1)
      endif

      if (nt2 > 0) then
         nsources_loc = nsources_loc + 1
         allocate(sv2(nt2))
         read(lu_srf,*) sv2
         deallocate(sv2)
      endif

      ! TODO: Not using the u3 direction for now, as I don't now how that defines a
      !       momenttensor (MvD)
      if (nt3 > 0) then
         !nsources_loc = nsources_loc + 1
         allocate(sv3(nt3))
         read(lu_srf,*) sv3
         deallocate(sv3)
      endif
   enddo

   if (present(nsources)) nsources = nsources_loc

   ! now do the actual reading
   allocate(sources(nsources_loc))
   rewind(lu_srf)
   isource = 0

   ! go to POINTS block
   do
     read(lu_srf,'(a)') line
     if (index(line, 'POINTS') == 1) exit
   enddo

   do i=1, npoints_loc
      read(lu_srf,*) lon, lat, dep, stk, dip, area, tinit, dt
      read(lu_srf,*) rake, slip1, nt1, slip2, nt2, slip3, nt3

      ! go to SI units
      area = area * 1d-4    ! cm^2 > m^2
      slip1 = slip1 * 1d-2  ! cm   > m
      slip2 = slip2 * 1d-2  ! cm   > m
      slip3 = slip3 * 1d-2  ! cm   > m

      if (lon < minlond) minlond = lon
      if (lon > maxlond) maxlond = lon
      if (lat < minlatd) minlatd = lat
      if (lat > maxlatd) maxlatd = lat
      if (dep < mindep) mindep = dep
      if (dep > maxdep) maxdep = dep

      if (nt1 > 0) then
         isource = isource + 1

         ! true shear modulus is read later when loading the wavefields
         call sources(isource)%init_strike_dip_rake(lat, lon, dep, stk, dip, area, tinit, &
                                                    rake, slip1, mu=32d9)
         allocate(sources(isource)%stf(nt1))
         read(lu_srf,*) sources(isource)%stf

         sources(isource)%stf_dt = dt
      endif

      if (nt2 > 0) then
         isource = isource + 1

         ! true shear modulus is read later when loading the wavefields
         call sources(isource)%init_strike_dip_rake(lat, lon, dep, stk, dip, area, tinit, &
                                                    rake + 90, slip2, mu=32d9)
         allocate(sources(isource)%stf(nt2))
         read(lu_srf,*) sources(isource)%stf

         sources(isource)%stf_dt = dt
      endif

      if (nt3 > 0) then
         !isource = isource + 1
         allocate(sv3(nt3))
         read(lu_srf,*) sv3
         deallocate(sv3)
         ! TODO: Not using the u3 direction for now, as I don't now how that defines a
         !       momenttensor (MvD)
      endif
   enddo

   close(lu_srf)

   if (verbose > 1) then
      write(6,*) 'minlond', minlond
      write(6,*) 'maxlond', maxlond
      write(6,*) 'minlatd', minlatd
      write(6,*) 'maxlatd', maxlatd
      write(6,*) 'mindep ', mindep
      write(6,*) 'maxdep ', maxdep
   endif

end subroutine
!-----------------------------------------------------------------------------------------

end module
!=========================================================================================
