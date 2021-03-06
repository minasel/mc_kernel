!******************************************************************************
!
!    This file is part of:
!    MC Kernel: Calculating seismic sensitivity kernels on unstructured meshes
!    Copyright (C) 2016 Simon Staehler, Martin van Driel, Ludwig Auer
!
!    You can find the latest version of the software at:
!    <https://www.github.com/tomography/mckernel>
!
!    MC Kernel is free software: you can redistribute it and/or modify
!    it under the terms of the GNU General Public License as published by
!    the Free Software Foundation, either version 3 of the License, or
!    (at your option) any later version.
!
!    MC Kernel is distributed in the hope that it will be useful,
!    but WITHOUT ANY WARRANTY; without even the implied warranty of
!    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
!    GNU General Public License for more details.
!
!    You should have received a copy of the GNU General Public License
!    along with MC Kernel. If not, see <http://www.gnu.org/licenses/>.
!
!******************************************************************************

module lanczos
  use iso_c_binding, only: c_double, c_int
  use global_parameters, only: dp, pi
  implicit none
  private
  public :: lanczos_resample
contains

!-----------------------------------------------------------------------------------------
!> Lanczos resampling, see http://en.wikipedia.org/wiki/Lanczos_resampling
!! In contrast to frequency domain sinc resampling it allows for arbitrary
!! sampling rates but due to the finite support of the kernel is a lot faster
!! then sinc resampling in time domain (linear instead of quadratic scaling
!! with the number of samples). For large a, converges towards sinc
!! resampling. If used for downsampling, make sure to apply a lowpass
!! filter first.
!! Parameters:
!! si -- input signal
!! dt_old -- sampling of the input sampling
!! dt_new -- desired sampling
!! a -- width of the kernel
function lanczos_resample(si, dt_old, dt_new, a)
  real(kind=dp), intent(in)       :: si(:)
  real(kind=dp), intent(in)       :: dt_old, dt_new
  integer, intent(in)             :: a
  real(kind=dp), allocatable      :: lanczos_resample(:)

  integer                         :: n_old, n_new
  real(kind=dp)                   :: dt

  n_old = size(si)
  n_new = int(n_old * (dt_old / dt_new))
  dt = dt_new / dt_old

  allocate(lanczos_resample(n_new))

  call lanczos_resamp_core(si    = si,               &
                           n_in  = n_old,            &
                           n_out = n_new,            &
                           dt    = dt,               & 
                           so    = lanczos_resample, &
                           a     = a) 

end function lanczos_resample
!-----------------------------------------------------------------------------------------

!-----------------------------------------------------------------------------------------
pure subroutine lanczos_resamp_core(si, n_in, so, n_out, dt, a) bind(c, name="lanczos_resamp")
  ! lanczos resampling, see http://en.wikipedia.org/wiki/Lanczos_resampling
  integer(c_int), intent(in), value :: n_in
  integer(c_int), intent(in), value :: n_out
  real(c_double), intent(in)        :: si(1:n_in)
  real(c_double), intent(out)       :: so(1:n_out)
  real(c_double), intent(in), value :: dt
  integer(c_int), intent(in), value :: a
  integer(c_int)                    :: i, l, m
  real(c_double)                    :: x, kern
  so = 0
  do l=1, n_out
    x = dt * (l - 1)
    do m=-a, a
      i = floor(x) - m + 1
      if (i < 1 .or. i > n_in) cycle
      call lanczos_kern(x - i + 1, a, kern)
      so(l) = so(l) + si(i) * kern
    enddo
  enddo
end subroutine
!-----------------------------------------------------------------------------------------

!-----------------------------------------------------------------------------------------
pure subroutine lanczos_kern(x, a, kern) bind(c, name="lanczos_kern")
  real(c_double), intent(in), value :: x
  integer(c_int), intent(in), value :: a
  real(c_double), intent(out)       :: kern
  if (x > -a .and. x < a) then
    kern = sinc(x) * sinc(x / a)
  else
    kern = 0
  endif
end subroutine
!-----------------------------------------------------------------------------------------

!-----------------------------------------------------------------------------------------
pure function sinc(x)
  double precision, intent(in) :: x
  double precision :: sinc
  if (abs(x) < 1e-10) then
    sinc = 1
  else
    sinc = sin(pi * x) / (pi * x)
  endif
end function
!-----------------------------------------------------------------------------------------

end module lanczos
!=========================================================================================
