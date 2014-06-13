! New (updated) library interface, for linking TWIN to AMUSE.
! The main practical design change is that we no longer calculate one timestep "ahead" of where we claim to be.
! This is a useful practice if the top-layer can't handle "backups", but it introduces a lag in the response from
! the evolution code to any proposed changes. This is ok if the stellar evolution mainly talks in one direction to, say, a
! dynamics code, as in the work by Church et al, but it is not so useful in a tightly coupled framework like AMUSE.
! In general, this iteration is much simpler and closer to how TWIN works internally, which should make this (much) simpler in the
! long run at the expense of a (bit of) extra memory
!
! TODO:
!  initialise a new star from a file
!  write a model to a file
!  append a model to a file (are these really different?)
!  join/break binary and relevant query functions
!  Test whether timestepping is done correctly.
#include "assert.h"

module twinlib
   use real_kind
   use indices, only: nvar, nvstar

   type, private :: twin_star_t
      integer :: id        ! ID for this star
      integer :: pid, sid  ! ID for primary/secondary star (in a binary)
      integer :: bid       ! ID for binary that this star is a member of (-1 if none, id for the binary itself)

      ! Some properties
      logical :: nucleosynthesis ! Solve extended nucleosynthesis network for this model

      ! Flag to indicate wether this star still needs some initialisation
      logical :: virgin

      ! Flag that tells whether this star still exists (i.e. it has not been removed)
      logical :: exists

      integer :: number_of_variables
      integer :: number_of_meshpoints

      ! Array of independent variables and increments since last timestep
      real(double), pointer :: h(:,:)
      real(double), pointer :: dh(:,:)
      real(double), pointer :: hpr(:, :)
      real(double), pointer :: ht(:, :)
      real(double), pointer :: Hnucpr(:,:,:)
      real(double), pointer :: Hnuc(:,:,:)
      real(double), pointer :: DHnuc(:,:,:)

      real(double) :: maximum_mass
      real(double) :: zams_mass

      real(double) :: age

      ! Stellar type, as in Hurley & al 2000
      integer :: stellar_type

      ! Iteration control
      integer :: startup_iter
      integer :: normal_iter

      ! Binary parameters; these need to be set because TWIN is a binary code
      real(double) :: bms, per, ecc, p

      ! Timestep parameters
      real(double) :: rlf_prev(2)
      real(double) :: qcnv_prev(2)
      real(double) :: lnuc_prev(2)
      real(double) :: lhe_prev(2)
      real(double) :: lh_prev(2)

      ! Module current_model_properties
      real(double) :: uc(21)
      real(double) :: dt
      integer :: jmod, jnn

      integer :: eqns(130)

      ! Module test_variables
      ! Not all of these matter, but better safe than sorry
      real(double) :: mc(2)      ! Mass scale for the core (for mesh spacing function)
      real(double) :: hspn(2)    ! Spin angular momentum, star 1 and star 2
      real(double) :: rlf(2)     ! Roche lobe filling factor, ln R*/RL
      real(double) :: zet(2)     ! Wind mass loss from the system [1e33g/s]
      real(double) :: xit(2)     ! Mass transfer to companion, by RLOF and wind
      real(double) :: tn(2)      ! Nuclear timescale; set in printb [s]
      real(double) :: be(2)      ! Binding energy of the stellar envelope [erg/(1Mo)]
      real(double) :: be0(2)     ! Binding energy of the stellar envelope: gravity [erg/(1Mo)]
      real(double) :: be1(2)     ! Binding energy of the stellar envelope: internal energy [erg/(1Mo)]
      real(double) :: be2(2)     ! Binding energy of the stellar envelope: recombination energy [erg/(1Mo)]
      real(double) :: be3(2)     ! Binding energy of the stellar envelope: H2 association energy [erg/(1Mo)]
      real(double) :: spsi(2)    ! Scaled surface potential, in -G(M1+M2)/a
      real(double) :: bm         ! Total mass in the binary [1e33 g]
      real(double) :: om         ! Total mass of the secondary [1e33 g]
      real(double) :: bper       ! Binary period [days]
      real(double) :: enc        ! Artificial energy generation rate
      real(double) :: cdd        ! Timestep control parameter
      integer :: jhold           ! If jhold<3, then don't change the timestep
      real(double) :: prev(81), pprev(81)
      integer :: jm2, jm1 


      ! Wind/mass accretion options
      real(double) :: cmi
      real(double) :: cmdot_wind
   end type twin_star_t

   ! Data structure to store a number of stars in memory.
   integer, private :: max_stars = -1        ! Maximum number of stars
   type(twin_star_t), private, allocatable, target :: star_list(:)
   integer, private :: current_star = 0      ! Currently selected star

   logical, private :: initialised = .false.

   ! Print verbose output to stdout yes or no.
   logical, private :: verbose = .false.

   ! Number of models to run before switching to "normal" number of
   ! iterations (from "startup" number of iterations)
   integer, parameter, private :: switch_iterations = 5

   ! Static (local) init.dat options
   integer, private :: wanted_kh, ksv, kt5, jch

   ! Layout of the ZAMS library file
   real(double), private :: mlo, dm, mhi
   integer, private :: kdm

   ! Solver list/equations for single stars and binaries
   integer, private :: eqns_single(130)
   integer, private :: eqns_binary(130)

   ! Temporary storage of amuse parameters, needed by initialise_twin
   character(len = 1000), private :: amuse_ev_path
   integer, private :: amuse_nstars, amuse_nmesh
   logical, private :: amuse_verbose
   real(double), private :: amuse_Z

   ! List private subroutines that should not be called directly
   private initialise_stellar_parameters, allocate_star, swap_in, swap_out, select_star

contains

   ! initialise_twin:
   !  General TWIN initialisation: load physics datafiles and ZAMS libraries.
   !  Input variables:
   !   path   - the path to the stellar evolution code, location of the input data
   !            can be set to '.' if datafiles are in the current directory. Leave blank ('')
   !            to use the default (either from environment variable or from configure option)
   !   nstars - The total number of stars (and binaries) for which we want to
   !            allocate space
   !   Z      - Desired metallicity, in the range 0.0 <= Z <= 0.04
   !   verb   - verbose output (true/false); optional.
   !   nmesh  - maximum number of mesh points (optional)
   !  Returns value:
   !     0 on succes, non zero on failure:
   !    -1 initialised before (not critical)
   !    -2 bad metallicity requested (out-of-range)
   !    -3 bad number of stars requested (<1)
   !    -4 Cannot load init.dat settings file
   integer function initialise_twin(path, nstars, Z, verb, nmesh)
      use real_kind
      use settings
      use constants
      use current_model_properties
      use control
      use settings
      use filenames
      use install_location
      use opacity
      use distortion
      use allocate_arrays
      use mesh, only: ktw, isb, max_nm, id
      use solver_global_variables, only: solver_output_unit
      use polytrope, only: NMP
      implicit none
      character(len=*), intent(in) :: path
      integer, intent(in)          :: nstars
      real(double), intent(in)     :: Z
      logical, intent(in),optional :: verb
      integer, intent(in),optional :: nmesh
      character(len=80)            :: tmpstr
      integer                      :: i, j

      ! Assume success, we'll override when needed
      initialise_twin = 0

      if (present(verb)) verbose = verb

      ! Only initialise once
      if (initialised) then
         initialise_twin = -1
         return
      end if

      ! Test whether requested metallicity is valid
      if (Z < 0.0 .or. Z > 0.04) then
         initialise_twin = -2
         return
      end if

      ! Sensible number of stars?
      if (nstars < 1) then
         initialise_twin = -3
         return
      end if

      ! Initialise path
      if (len(trim(path)) > 0) then
         evpath = trim(path)
      else
         call get_environment_variable("evpath", evpath)
         if (len(trim(evpath)) == 0) evpath = twin_install_path;
      end if

      ! Set metallicity
      czs = Z
      ! Now convert the value of czs to a string
      write(tmpstr, '(f10.7)') czs
      i = 1
      j = len(trim(tmpstr))
      do while (tmpstr(i:i) /= '.')
         i = i+1
      end do
      i = i + 1
      do while (tmpstr(j:j) == '0')
         j = j-1
      end do
      j = max(j,i)
      zstr = tmpstr(i:j)

      if (present(nmesh)) max_nm = max(max_nm, nmesh)
      max_nm = max(max_nm, NMP)

      if (verbose) then
         print *, 'twin initialisation.'
         print *, 'arguments: evpath   = ', trim(evpath)
         print *, '           nstars   = ', nstars
         print *, '           zstr     = ', trim(zstr)
         print *, '           max mesh = ', max_nm
      end if

      ! Read constant data for the run (init.dat)
      ! The first one just sets up the equations for doing a binary run
      inputfilenames(9) = trim(evpath)//'/input/amuse/init_twin.dat'
      initialise_twin = read_initdat_settings(inputfilenames(9))
      if (initialise_twin /= 0) return
      eqns_binary = id

      inputfilenames(9) = trim(evpath)//'/input/amuse/init.dat'
      initialise_twin = read_initdat_settings(inputfilenames(9))
      if (initialise_twin /= 0) return
      eqns_single = id

      ! Allocate memory for global arrays
      call allocate_global_arrays(max_nm)
      assert(allocated(h))

      ! Decide what opacity tables are required and whether ZAMS libraries are required or optional
      ! ZAMS files are *not* required, but if they don't exist we will need to construct a starting model from scratch.
      input_required(3) = -1
      input_required(4) = -1
      if (kop == 4) then
         if (verbose) print *, '*** Warning: CO enhanced tables not recommended/tested under AMUSE'
         input_required(5) = -1
         input_required(11) = 1
      else
         input_required(5) = 0
         input_required(11) = -1
      end if

      ! Input file init.run is *not* required
      input_required(10) = -1

      ! Default names for input files
      if (verbose) print *, 'Set location of input files'
      call set_default_filenames

      ! Check whether all files that are required exist
      if (verbose) print *, 'Checking if input files exist'
      call assert_input_files_exist

      ! Read opacity data and construct splines
      ! KOP (read from init.dat) sets which type of opacity tables
      if (verbose) print *, 'Load opacity table for opacity option ', kop
      call load_opacity(kop, czs)

      ! Initialise remaining data tables
      call setsup
      call initialise_distortion_tables
      call load_nucleosynthesis_rates(inputunits(13), inputunits(14))

      ! Read format of ZAMS library
      if (have_zams_library()) then
         ! Read layout of the ZAMS library
         read (19, *) mlo, dm, mhi, kdm
         rewind (19)
         if (verbose) print *, 'ZAMS library format ', mlo, dm, mhi, kdm
      end if

      ! Initialise number of stars that will be solved concurrently (default: 1)
      ktw = 1
      isb = 1

      ! Redirect output from the solver to a terminal
      solver_output_unit = (/ 6, 6, 6 /)

      ! Reserve some extra space for stars.
      ! This is friendly, because we will need to allocate an extra "star" whenever a binary is created
      max_stars = 2*nstars

      allocate(star_list(1:max_stars))
      do i=1, max_stars
         star_list(i)%exists = .false.
         star_list(i)%nucleosynthesis = .false.
      end do
      if (verbose) print *, 'allocated memory for ',max_stars, 'stars+binaries'
   end function initialise_twin



   ! read_initdat_settings:
   !  read options from a specified init.dat file.
   !  NOTE: some settings are actually overridden below, meaning the configuration file is ignored.
   !  This is mostly for options that will (probably) not work (correctly) anyway.
   integer function read_initdat_settings(filename)
      use filenames
      use settings
      use control
      use init_dat
      implicit none
      character(len=*), intent(in) :: filename
      integer :: ioerror

      read_initdat_settings = 0

      if (verbose) print *, 'Reading settings from ', trim(filename)
      open(unit = inputunits(9), action="read", file=filename, iostat = ioerror)
      if (ioerror /= 0 .or. read_init_dat(inputunits(9), wanted_kh, ksv, kt5, jch) .eqv. .false.) then
         read_initdat_settings = -4
         return
      end if
      rewind (inputunits(9))

      ! Override some settings from init.dat
      ! TODO: some of these we do want to be able to change...
      cmi_mode = 2                        ! Interpret CMI as accretion rate in Msun/year
      cmdot_wind = 1.0d0                  ! Enable stellar winds
      store_changes = .true.              ! We do want to store (predicted) changes when asked to store a file
      use_quadratic_predictions = .false. ! Use linear prediction for variable updates
      jch = 3                             ! Always construct new mesh spacing, safer
   end function read_initdat_settings



   ! Returns true if a zams library file exists (so that we can load models from it)
   logical function have_zams_library()
      use file_exists_module
      use filenames
      implicit none
      
      have_zams_library = file_exists(inputfilenames(3)) .and. file_exists(inputfilenames(4))
   end function have_zams_library



   ! Allocate a star from the list
   integer function allocate_star()
      implicit none
      integer :: i

      allocate_star = 0
      do i = 1, max_stars
         if (.not. star_list(i)%exists) then
            star_list(i)%exists = .true.
            star_list(i)%id = i
            star_list(i)%pid = -1
            star_list(i)%sid = -1
            star_list(i)%bid = -1
            star_list(i)%nucleosynthesis = .false.
            allocate_star = i
            return
         end if
      end do
   end function allocate_star



   subroutine release_star(star_id)
      implicit none
      integer, intent(in) :: star_id
      type(twin_star_t), pointer :: star

      if (star_id < 1) return
      if (star_id > max_stars) return

      if (current_star == star_id) current_star = 0

      star => star_list(star_id)

      ! Free memory used by this star
      star%exists = .false.
      deallocate(star%h)
      deallocate(star%dh)
      deallocate(star%hpr)
      if (star%nucleosynthesis) then
         deallocate(star%ht)
      end if
      star%nucleosynthesis = .false.
   end subroutine
   integer function delete_star(star_id)
      implicit none
      integer, intent(in) :: star_id
      call release_star(star_id)
      delete_star = 0
   end function


   ! Set (initialise) basic stellar variables, like the equation list and timestep
   subroutine initialise_stellar_parameters(star_id)
      use real_kind
      use test_variables, only: dt, age, jhold
      use current_model_properties
      use constants
      use settings
      implicit none
      integer, intent(in)        :: star_id
      type(twin_star_t), pointer :: star
      real(double)               :: tnuc, mass

      star => star_list(star_id)
      current_star = star_id

      mass = star%zams_mass

      star%eqns = eqns_single
      star%startup_iter = kr1
      star%normal_iter = kr2

      star%uc = (/ 1.00E-01, 2.00E+12, 1.00E+02, 0.00E+00, 3.00E+00, 5.30E+00, 1.20E+00, &
                   6.30E+00, 3.00E+02, 0.00E+00, 1.00E-06, 1.00E+06, 1.00E+03, 1.00E+03, &
                   0.00E+00, 0.00E+00, 0.00E+00, 0.00E+00, 0.00E+00, 0.00E+00, 0.00E+00 /)
      star%maximum_mass = -1.0

      rlf_prev = (/0.0, 0.0/)   ! Previous value of Roche-lobe filling factor
      qcnv_prev = (/0.0, 0.0/)  ! Previous value of mass fraction of convective envelope
      lnuc_prev = (/0.0, 0.0/)  ! Previous value of nuclear burning luminosity
      lhe_prev = (/0.0, 0.0/)   ! Previous value of He burning luminosity
      lh_prev = (/0.0, 0.0/)    ! Previous value of H burning luminosity

      star%exists = .true.

      ! Estimate nuclear timescale for this star
      tnuc = 1.0d10 * mass**(-2.8)
      star%dt = ct3*1.0d-3 * tnuc*csy
      if (mass > 1.0 .and. mass < 1.2) star%dt = 1.0d-2*star%dt
      if (verbose) print *, 'setting initial timestep for star',star_id,'to',star%dt/csy,'yr'
      dt = star%dt
      age = star%age

      jhold = 2

      ! ----------------------------------------------------------
      ! Compute quantities
      ! ----------------------------------------------------------
      call compute_output_quantities ( 1 )

      ! -------------------------------------------------------------------
      ! Update quantities that have to be calculated explicitly
      ! -------------------------------------------------------------------
      call update_explicit_quantities( 1 )

      ! -------------------------------------------------------------------
      ! Update the control parameters for the next timestep
      ! -------------------------------------------------------------------
      call update_timestep_parameters( 1 )
   end subroutine initialise_stellar_parameters



   ! new_zams_star:
   !  Create a new ZAMS model for a star
   !  Input variables:
   !   mass       - the initial mass, in solar units
   !   start_age  - the starting age, in years. Only used for reporting the star's age
   !   nmesh      - (optional) the number of gridpoints in the model (default: whatever was read in from init.dat)
   !   wrot       - (optional) the rotation rate for the model (default: no rotation)
   !  Return value:
   !   >0: The stars ID for identifying it in the array of models
   !   =0: No star allocated, out of memory
   !   -1: No star allocated, requested mesh is too large
   integer function new_zams_star(mass, start_age, nmesh, wrot)
      use real_kind
      use mesh, only: nm, h, hpr, dh, kh
      use nucleosynthesis, only: ht_nvar, hnuc
      use constants
      use settings
      use polytrope
      use indices
      use test_variables
      implicit none
      real(double), intent(in)            :: mass, start_age
      integer, optional, intent(in)       :: nmesh
      real(double), optional, intent(in)  :: wrot
      type(twin_star_t), pointer          :: star
      integer                             :: new_kh
      integer                             :: new_id
      real(double)                        :: w
      real(double)                        :: sm1,dty1,age1,per1,bms1,ecc1,p1,enc1, tm, oa
      integer                             :: kh1,kp1,jmod1,jb1,jn1,jf1, im1
      real(double)                        :: hn1(50, nm)

      ! Test if we can actually load a model from disk.
      ! If we cannot, we construct a pre-mainsequence star (that is, a polytrope) instead and evolve it to ZAMS
      if (have_zams_library() .eqv. .false.) then
         ! Construct a pre-mainsequence star
         new_zams_star = new_prems_star(mass, start_age, nmesh, wrot)

         ! Evolve to ZAMS
         ! *TODO*
         if (verbose) print *, 'Evolve to ZAMS'
         return
      end if

      ! Set default value for number of gridpoints and rotation rate
      new_kh = wanted_kh
      if (present(nmesh)) kh1 = nmesh

      w = 0.0d0
      if (present(wrot)) w = wrot

      if (new_kh > NM .or. new_kh < 1) then
         if (verbose) print *, 'Cannot create model at ', new_kh, 'meshpoints. Maximum size is ', NM, 'meshpoints.'
         new_zams_star = -1
         return
      end if

      new_id = allocate_star()
      if (new_id == 0) then
         new_zams_star = 0
         return
      end if
      star => star_list(new_id)

      ! Allocate memory for this star
      star%number_of_variables = NVSTAR
      star%number_of_meshpoints = new_kh
      allocate(star%h(star%number_of_variables, star%number_of_meshpoints))
      allocate(star%dh(star%number_of_variables, star%number_of_meshpoints))
      allocate(star%hpr(star%number_of_variables, star%number_of_meshpoints))

      ! Nucleosynthesis?
      ! *TODO* Make sure we can actually set this per star
      if (star%nucleosynthesis) then
         allocate(star%ht(ht_nvar, star%number_of_meshpoints))
      end if

      call select_star(new_id)

      star%zams_mass = mass
      star%age       = start_age

      ! Load model
      if (star%nucleosynthesis .and. verbose) print *, '*** Warning: ZAMS model+nucleosynthesis is not reliable.'
      if (verbose) print *, 'Load ZAMS model'
      im1 = (log10(mass) - mlo)/dm + 1.501d0
      call load_star_model(16,im1, h, dh, hn1, sm1,dty1,age1,per1,bms1,ecc1,p1,enc1,kh1,kp1,jmod1,jb1,jn1,jf1)

      ! Set desired options, this is a single star (by construction)
      kh = kh1
      tm = cmsn * mass
      bm = cmsn * bms1
      om = bm - tm
      p1 = 2.*cpi / (w * csday + 1.0e-9)
      bper = per1
      oa = cg1*tm*om*(cg2*bper/bm)**c3rd*sqrt(1.0d0 - ecc1*ecc1)
      ! Remesh to desired numer of mesh points
      call remesh ( new_kh, jch, bm, tm, p1, ecc1, oa, 1, 2 )

      hpr = h

      call initialise_stellar_parameters(new_id)

      call swap_out()

      new_zams_star = new_id
   end function new_zams_star



   ! new_prems_star:
   !  Create a new pre-main sequence model for a star
   !  Input variables:
   !   mass       - the initial mass, in solar units
   !   start_age  - the starting age, in years. Only used for reporting the star's age
   !   nmesh      - (optional) the number of gridpoints in the model (default: whatever was read in from init.dat)
   !   wrot       - (optional) the rotation rate for the model (default: no rotation)
   !  Return value:
   !   >0: The stars ID for identifying it in the array of models
   !   =0: No star allocated, out of memory
   !   -1: No star allocated, requested mesh is too large
   integer function new_prems_star(mass, start_age, nmesh, wrot)
      use real_kind
      use mesh, only: nm, h, hpr, dh, kh
      use nucleosynthesis, only: ht_nvar, hnuc
      use constants
      use settings
      use polytrope
      use test_variables
      implicit none
      real(double), intent(in)            :: mass, start_age
      integer, optional, intent(in)       :: nmesh
      real(double), optional, intent(in)  :: wrot
      type(twin_star_t), pointer          :: star
      integer                             :: new_kh
      integer                             :: new_id
      real(double)                        :: w
      real(double)                        :: sm1,dty1,age1,per1,bms1,ecc1,p1,enc1, tm, oa
      integer                             :: kh1,kp1,jmod1,jb1,jn1,jf1
      real(double)                        :: hn1(50, nm)

      new_prems_star = 0

      ! Set default value for number of gridpoints and rotation rate
      new_kh = wanted_kh
      if (present(nmesh)) kh1 = nmesh

      w = 0.0d0
      if (present(wrot)) w = wrot

      if (new_kh > NM .or. new_kh < 1) then
         if (verbose) print *, 'Cannot create model at ', new_kh, 'meshpoints. Maximum size is ', NM, 'meshpoints.'
         new_prems_star = -1
         return
      end if

      new_id = allocate_star()
      if (new_id == 0) then
         return
      end if
      star => star_list(new_id)

      ! Allocate memory for this star
      star%number_of_variables = NVSTAR
      star%number_of_meshpoints = new_kh
      allocate(star%h(star%number_of_variables, star%number_of_meshpoints))
      allocate(star%dh(star%number_of_variables, star%number_of_meshpoints))
      allocate(star%hpr(star%number_of_variables, star%number_of_meshpoints))

      ! Nucleosynthesis?
      ! *TODO* Make sure we can actually set this per star
      if (star%nucleosynthesis) then
         allocate(star%ht(ht_nvar, star%number_of_meshpoints))
      end if

      call select_star(new_id)

      star%zams_mass = mass
      star%age       = start_age

      ! Construct pre-main sequence model
      if (verbose) print *, 'Construct pre-main sequence model'
      call generate_starting_model(mass, h, dh, hn1, sm1,dty1,age1,per1,bms1,ecc1,p1,enc1,kh1,kp1,jmod1,jb1,jn1,jf1)

      ! Set desired options, this is a single star (by construction)
      kh = kh1
      tm = cmsn * mass
      bm = cmsn * bms1
      om = bm - tm
      p1 = 2.*cpi / (w * csday + 1.0e-9)
      if (w == 0.0d0) p1 = 1.0d6
      bper = per1
      oa = cg1*tm*om*(cg2*bper/bm)**c3rd*sqrt(1.0d0 - ecc1*ecc1)
      ecc1 = 0.0
      ! Remesh to desired numer of mesh points
      call remesh ( new_kh, jch, bm, tm, p1, ecc1, oa, 1, 2 )

      hpr = h

      call initialise_stellar_parameters(new_id)

      call swap_out()

      new_prems_star = new_id
   end function new_prems_star

! Create a new particle
   integer function new_particle(star_id, mass)
      implicit none
      integer, intent(out) :: star_id
      real(double), intent(in) :: mass
      real(double) :: start_age
      start_age = 0.0
      star_id = new_zams_star(mass, start_age)
      if (star_id .lt. 1) then
        new_particle = -1
      else
        new_particle = 0
      end if
   end function


   ! new_star_from_file:
   !  Create a new pre-main sequence model for a star
   !  Input variables:
   !   filename   - the name of the file the model is stored in
   !  Return value:
   !   >0: The stars ID for identifying it in the array of models
   !   =0: No star allocated, out of memory
   !   -1: No star allocated, requested mesh is too large
   !   -2: No star allocated, file not found
   integer function new_star_from_file(filename)
      use real_kind
      use mesh, only: nm, h, hpr, dh, kh
      use nucleosynthesis, only: ht_nvar, hnuc, nvar_nuc
      use constants
      use settings
      use polytrope
      use test_variables
      use filenames
      implicit none

      character(len=*), intent(in) :: filename
      type(twin_star_t), pointer   :: star
      integer                      :: new_id
      integer :: ioerror

      integer :: kh1,kp1,jmod1,jb1,jn1,jf1, ip1, tm, oa
      real(double) :: sm1, dty1, age1, per1, bms1, ecc1, p1, enc1

      real(double), allocatable ::  h1(:, :)
      real(double), allocatable :: hn1(:, :)
      real(double), allocatable :: dh1(:, :)

      new_star_from_file = 0

      call swap_out()

      ip1 = get_free_file_unit()
      open(unit = ip1, action="read", file=filename, iostat=ioerror)
      if (ioerror /= 0) then
         if (verbose) print *, 'Cannot load file ', trim(filename), '.'
         new_star_from_file = -2
         return
      end if


      allocate(h1(nvar, nm))
      allocate(dh1(nvar, nm))
      allocate(hn1(nvar_nuc, nm))
      call load_star_model(ip1,1, h1, dh1, hn1, sm1,dty1,age1,per1,bms1,ecc1,p1,enc1,kh1,kp1,jmod1,jb1,jn1,jf1)
      close(ip1)

      if (kh1 > NM) then
         if (verbose) print *, 'Cannot load model with ', kh1, 'meshpoints. Maximum size is ', NM, 'meshpoints.'
         new_star_from_file = -1
         goto 3
      end if

      new_id = allocate_star()
      if (new_id == 0) then
         goto 3
      end if
      star => star_list(new_id)

      ! Allocate memory for this star
      star%number_of_variables = jn1
      star%number_of_meshpoints = kh1
      allocate(star%h(star%number_of_variables, star%number_of_meshpoints))
      allocate(star%dh(star%number_of_variables, star%number_of_meshpoints))
      allocate(star%hpr(star%number_of_variables, star%number_of_meshpoints))

      ! Nucleosynthesis?
      ! *TODO* Make sure we can actually set this per star
      if (star%nucleosynthesis) then
         allocate(star%ht(ht_nvar, star%number_of_meshpoints))
      end if

      call select_star(new_id)

      h(1:jn1, 1:kh1) = h1(1:jn1, 1:kh1)
      dh(1:jn1, 1:kh1) = dh1(1:jn1, 1:kh1)

      star%zams_mass = sm1
      star%age       = age1

      ! Set desired options, this is a single star (by construction)
      kh = kh1
      tm = cmsn * sm1
      bm = cmsn * bms1
      om = bm - tm
      bper = per1
      ecc1 = 0.0
      oa = cg1*tm*om*(cg2*bper/bm)**c3rd*sqrt(1.0d0 - ecc1*ecc1)
      ! Remesh to desired numer of mesh points
      call remesh ( kh, jch, bm, tm, p1, ecc1, oa, 1, 0 )

      hpr = h

      call initialise_stellar_parameters(new_id)

      call swap_out()

      new_star_from_file = new_id

      ! Cleanup
      ! Use a line number because Fortran doesn't allow for labels
3     continue
      if (allocated(h1)) deallocate(h1)
      if (allocated(dh1)) deallocate(dh1)
      if (allocated(hn1)) deallocate(hn1)
   end function new_star_from_file




   ! write_star_to_file:
   !  write the state of star id to a named file, for later retrieval.
   !  The file will be in the format of a TWIN input file
   subroutine write_star_to_file(id, filename)
      use real_kind
      use filenames, only: get_free_file_unit
      
      implicit none
      integer, intent(in) :: id
      character(len=*), intent(in) :: filename
      integer :: ip

      call select_star(id)

      ip = get_free_file_unit()
      open (unit=ip, file=filename, action='write')
      call output(200, ip, 0, 0)
      close (ip);
   end subroutine write_star_to_file




   logical function is_binary_system(star_id)
      implicit none
      integer, intent(in) :: star_id
      is_binary_system = star_list(star_id)%exists .and. star_list(star_id)%bid /= -1
   end function is_binary_system



   logical function is_single_star(star_id)
      implicit none
      integer, intent(in) :: star_id
      is_single_star = star_list(star_id)%exists .and. star_list(star_id)%bid == -1
   end function is_single_star




   ! Select the star with star_id as the "current" star
   subroutine swap_in(star_id)
      use real_kind
      use mesh, only: nm, kh, h, dh, hpr
      use test_variables
      use current_model_properties, only: jmod, jnn, rlf_prev, qcnv_prev, lnuc_prev, lhe_prev, lh_prev
      use nucleosynthesis, only: nucleosynthesis_enabled
      use settings, only: cmi, cmdot_wind
      use solver_global_variables, only: es
      use indices
      implicit none
      integer, intent(in) :: star_id
      type(twin_star_t), pointer :: star, primary, secondary
      if (current_star == star_id) return
      if (star_id > max_stars) return

      star => star_list(star_id)
      if (.not. star%exists) return

      assert(allocated(h))

      kh = star%number_of_meshpoints
      if (is_single_star(star_id)) then
         h(1:star%number_of_variables, 1:kh) = star%h(1:star%number_of_variables, 1:kh)
         dh(1:star%number_of_variables, 1:kh) = star%dh(1:star%number_of_variables, 1:kh)
         hpr(1:star%number_of_variables, 1:kh) = star%hpr(1:star%number_of_variables, 1:kh)
      else
         assert(star%pid > -1)
         assert(star%sid > -1)
         primary => star_list(star%pid)
         secondary => star_list(star%sid)

         ! Primary star
         h(1:primary%number_of_variables, 1:kh)   = primary%h(1:primary%number_of_variables, 1:kh)
         dh(1:primary%number_of_variables, 1:kh)  = primary%dh(1:primary%number_of_variables, 1:kh)
         hpr(1:primary%number_of_variables, 1:kh) = primary%hpr(1:primary%number_of_variables, 1:kh)

         ! Orbital elements
         h(INDEX_ORBIT_VAR_START+1:INDEX_ORBIT_VAR_START+star%number_of_variables, 1:kh)   = &
            star%h(1:star%number_of_variables, 1:kh)
         dh(INDEX_ORBIT_VAR_START+1:INDEX_ORBIT_VAR_START+star%number_of_variables, 1:kh)  = &
            star%dh(1:star%number_of_variables, 1:kh)
         hpr(INDEX_ORBIT_VAR_START+1:INDEX_ORBIT_VAR_START+star%number_of_variables, 1:kh) = &
            star%hpr(1:star%number_of_variables, 1:kh)

         ! Secondary star
         h(INDEX_SECONDARY_START+1:INDEX_SECONDARY_START+secondary%number_of_variables, 1:kh)   = &
            secondary%h(1:secondary%number_of_variables, 1:kh)
         dh(INDEX_SECONDARY_START+1:INDEX_SECONDARY_START+secondary%number_of_variables, 1:kh)  = &
            secondary%dh(1:secondary%number_of_variables, 1:kh)
         hpr(INDEX_SECONDARY_START+1:INDEX_SECONDARY_START+secondary%number_of_variables, 1:kh) = &
            secondary%hpr(1:secondary%number_of_variables, 1:kh)
      end if
      age  = star%age
      dt   = star%dt
      jmod = star%jmod
      jnn  = star%jnn

      mc = star%mc
      hspn = star%hspn
      rlf = star%rlf
      zet = star%zet
      xit = star%xit
      tn = star%tn
      be = star%be
      be0 = star%be0
      be1 = star%be1
      be2 = star%be2
      be3 = star%be3
      spsi = star%spsi
      bm = star%bm
      om = star%om
      bper = star%bper
      enc = star%enc
      cdd = star%cdd
      jhold = star%jhold
      prev = star%prev
      pprev = star%pprev
      jm2 = star%jm2
      jm1  = star%jm1

      ! Correctly set binary mass eigenvalue (not otherwise preserved for single stars, but needed)
      h(VAR_BMASS, 1:kh) = bm

      rlf_prev = star%rlf_prev
      qcnv_prev = star%qcnv_prev
      lnuc_prev = star%lnuc_prev
      lhe_prev = star%lhe_prev
      lh_prev = star%lh_prev

      cmi = star%cmi
      cmdot_wind = star%cmdot_wind

      nucleosynthesis_enabled = star%nucleosynthesis

      ! TODO: we can do better than just setting this to 0 every time (for instance, we could just store it)
      es = 0

      current_star = star_id
   end subroutine swap_in



   ! Backup the properties of the current star
   subroutine swap_out()
      use real_kind
      use mesh, only: nm, kh, h, dh, hpr
      use test_variables
      use current_model_properties, only: jmod, jnn, rlf_prev, qcnv_prev, lnuc_prev, lhe_prev, lh_prev
      use settings, only: cmi, cmdot_wind
      use indices
      implicit none
      type(twin_star_t), pointer :: star, primary, secondary

      if (current_star == 0) return

      star => star_list(current_star)
      if (.not. star%exists) return

      star%number_of_meshpoints = kh
      if (is_single_star(current_star)) then
         star%h(1:star%number_of_variables, 1:kh) = h(1:star%number_of_variables, 1:kh)
         star%dh(1:star%number_of_variables, 1:kh) = dh(1:star%number_of_variables, 1:kh)
         star%hpr(1:star%number_of_variables, 1:kh) = hpr(1:star%number_of_variables, 1:kh)
      else
         assert(star%pid > -1)
         assert(star%sid > -1)
         primary => star_list(star%pid)
         secondary => star_list(star%sid)

         ! Primary star
         primary%h(1:primary%number_of_variables, 1:kh) = h(1:primary%number_of_variables, 1:kh)   
         primary%dh(1:primary%number_of_variables, 1:kh) = dh(1:primary%number_of_variables, 1:kh)  
         primary%hpr(1:primary%number_of_variables, 1:kh) = hpr(1:primary%number_of_variables, 1:kh) 

         ! Orbital elements
         star%h(1:star%number_of_variables, 1:kh) = &
            h(INDEX_ORBIT_VAR_START+1:INDEX_ORBIT_VAR_START+star%number_of_variables, 1:kh)   
         star%dh(1:star%number_of_variables, 1:kh) = &
            dh(INDEX_ORBIT_VAR_START+1:INDEX_ORBIT_VAR_START+star%number_of_variables, 1:kh)  
         star%hpr(1:star%number_of_variables, 1:kh) = &
            hpr(INDEX_ORBIT_VAR_START+1:INDEX_ORBIT_VAR_START+star%number_of_variables, 1:kh) 

         ! Secondary star
         secondary%h(1:secondary%number_of_variables, 1:kh) = &
            h(INDEX_SECONDARY_START+1:INDEX_SECONDARY_START+secondary%number_of_variables, 1:kh)   
         secondary%dh(1:secondary%number_of_variables, 1:kh) = &
            dh(INDEX_SECONDARY_START+1:INDEX_SECONDARY_START+secondary%number_of_variables, 1:kh)  
         secondary%hpr(1:secondary%number_of_variables, 1:kh) = &
            hpr(INDEX_SECONDARY_START+1:INDEX_SECONDARY_START+secondary%number_of_variables, 1:kh) 
      end if
      star%age  = age
      star%dt   = dt
      star%jmod = jmod
      star%jnn  = jnn

      star%mc = mc
      star%hspn = hspn
      star%rlf = rlf
      star%zet = zet
      star%xit = xit
      star%tn = tn
      star%be = be
      star%be0 = be0
      star%be1 = be1
      star%be2 = be2
      star%be3 = be3
      star%spsi = spsi
      star%bm = bm
      star%om = om
      star%bper = bper
      star%enc = enc
      star%cdd = cdd
      star%jhold = jhold
      star%prev = prev
      star%pprev = pprev
      star%jm2 = jm2
      star%jm1  = jm1

      star%rlf_prev = rlf_prev
      star%qcnv_prev = qcnv_prev
      star%lnuc_prev = lnuc_prev
      star%lhe_prev = lhe_prev
      star%lh_prev = lh_prev

      star%cmi = cmi
      star%cmdot_wind = cmdot_wind
   end subroutine swap_out



   ! Swap out the current star, swap in the new star
   subroutine select_star(star_id)
      implicit none
      integer, intent(in) :: star_id

      call swap_out()
      call swap_in(star_id)
   end subroutine select_star




   ! Get global stellar properties:
   ! age (in years)
   real(double) function age_of(star_id)
      implicit none
      integer, intent(in) :: star_id
      integer :: tmp
      tmp = get_age(star_id, age_of)
   end function
   integer function get_age(star_id, age)
      use real_kind
      implicit none
      integer, intent(in) :: star_id
      real(double), intent(out) :: age
      real(double) :: r
      get_age = -1

      age = -1.0

      if (star_id > max_stars) return
      age = star_list(star_id)%age
      get_age = 0
   end function



   ! Get luminosity (in solar units)
   real(double) function luminosity_of(star_id)
      implicit none
      integer, intent(in) :: star_id
      integer :: tmp
      tmp = get_luminosity(star_id, luminosity_of)
   end function
   integer function get_luminosity(star_id, luminosity)
      use real_kind
      use constants
      use indices
      implicit none
      integer, intent(in) :: star_id
      real(double), intent(out) :: luminosity
      real(double) :: r
      get_luminosity = -1

      luminosity = -1.0

      if (star_id > max_stars) return
      luminosity = star_list(star_id)%H(VAR_LUM, 1) / CLSN
      get_luminosity = 0
   end function




   ! Get mass (in solar units)
   real(double) function mass_of(star_id)
      implicit none
      integer, intent(in) :: star_id
      integer :: tmp
      tmp = get_mass(star_id, mass_of)
   end function
   integer function get_mass(star_id, mass)
      use indices
      use constants
      implicit none
      integer, intent(in) :: star_id
      real(double), intent(out) :: mass
      get_mass = -1
      mass = -1.0

      if (star_id > max_stars) return
      mass = star_list(star_id)%H(VAR_MASS, 1) / CMSN
      get_mass = 0
   end function



   ! Get mass (in solar units)
   real(double) function radius_of(star_id)
      implicit none
      integer, intent(in) :: star_id
      integer :: tmp
      tmp = get_radius(star_id, radius_of)
   end function
   integer function get_radius(star_id, radius)
      use indices
      use constants
      use settings, only: ct
      implicit none
      integer, intent(in) :: star_id
      real(double), intent(out) :: radius
      real(double) :: r
      get_radius = -1

      radius = -1.0

      if (star_id > max_stars) return
      r = sqrt(exp(2.*star_list(star_id)%H(VAR_LNR, 1)) - CT(8))
      radius = r / CLSN
      get_radius = 0
   end function



   ! Get effective temperature (in Kelvin)
   real(double) function temperature_of(star_id)
      implicit none
      integer, intent(in) :: star_id
      integer :: tmp
      tmp = get_temperature(star_id, temperature_of)
   end function
   integer function get_temperature(star_id, temperature)
      use real_kind
      use constants
      use indices
      implicit none
      integer, intent(in) :: star_id
      real(double), intent(out) :: temperature
      real(double) :: r
      get_temperature = -1

      temperature = -1.0

      if (star_id > max_stars) return
      temperature = exp(star_list(star_id)%h(VAR_LNT, 1))
      get_temperature = 0
   end function



   ! Get timestep (in yr)
   real(double) function timestep_of(star_id)
      implicit none
      integer, intent(in) :: star_id
      integer :: tmp
      tmp = get_time_step(star_id, timestep_of)
   end function
   integer function get_time_step(star_id, timestep)
      use real_kind
      use constants
      implicit none
      integer, intent(in) :: star_id
      real(double), intent(out) :: timestep
      real(double) :: r
      get_time_step = -1

      timestep = -1.0

      if (star_id > max_stars) return
      timestep = star_list(star_id)%dt / csy
      get_time_step = 0
   end function



   ! Set some evolution options
   ! Maximum mass the star can reach before accretion is turned off (in solar units).
   ! Can be used to increase the mass of the star to a particular point.
   ! Setting it to -1 allows the mass of the star to grow indefinitely (unless the code breaks first)
   subroutine set_maximum_mass_after_accretion(star_id, mmass)
      implicit none
      integer, intent(in) :: star_id
      real(double), intent(in) :: mmass

      if (star_id > max_stars) return
      
      star_list(star_id)%maximum_mass = mmass
   end subroutine set_maximum_mass_after_accretion



   ! Set the accretion rate for this star, in Msun/yr
   subroutine set_accretion_rate(star_id, mdot)
      use constants, only: csy
      use settings, only: cmi
      implicit none
      integer, intent(in) :: star_id
      real(double), intent(in) :: mdot

      if (star_id > max_stars) return
      
      call select_star(star_id)
      cmi = mdot / csy
      star_list(star_id)%cmi = cmi
   end subroutine set_accretion_rate



   ! Stellar wind switch: can be modulated between 0.0 (no wind) and 1.0 (full strength)
   subroutine set_wind_multiplier(star_id, mdot_factor)
      use constants, only: csy
      use settings, only: cmdot_wind
      implicit none
      integer, intent(in) :: star_id
      real(double), intent(in) :: mdot_factor

      if (star_id > max_stars) return
      
      call select_star(star_id)
      cmdot_wind = mdot_factor
      star_list(star_id)%cmdot_wind = mdot_factor
   end subroutine set_wind_multiplier



   ! Set timestep (in yr)
   subroutine set_timestep(star_id, dty)
      use real_kind
      use constants
      use test_variables, only: dt
      implicit none
      integer, intent(in) :: star_id
      real(double), intent(in) :: dty

      if (star_id > max_stars) return

      call select_star(star_id)
      dt = dty * csy
      star_list(star_id)%dt = dt
   end subroutine set_timestep



   ! Return the stellar type of the specified star
   integer function stellar_type_of(star_id)
      implicit none
      integer, intent(in) :: star_id
      integer :: tmp
      tmp = get_stellar_type(star_id, stellar_type_of)
   end function
   integer function get_stellar_type(star_id, stellar_type)
      use real_kind
      implicit none
      integer, intent(in) :: star_id
      integer, intent(out) :: stellar_type
      integer, external :: find_stellar_type
      get_stellar_type = -1
      stellar_type = -1

      if (star_id > max_stars) return
      call select_star(star_id)
      stellar_type = find_stellar_type()
      get_stellar_type = 0
   end function



   integer function evolve_one_timestep(star_id)
      use test_variables, only: dt, age, jhold
      use current_model_properties, only: jmod, jnn, joc, jb
      use stopping_conditions
      use constants, only: csy, cg, cmsn
      use mesh, only: h, ktw, isb
      use settings
      use indices
      implicit none
      integer, intent(in) :: star_id
      type(twin_star_t), pointer :: star
      real(double) :: dty, tdyn
      integer :: iter
      integer :: jo
      integer :: Jstar

      if (star_id > max_stars) then
         evolve_one_timestep = -1
         return
      end if

      evolve_one_timestep = 0
      if (star_id /= current_star) call select_star(star_id)
      assert(current_star > 0)

      star => star_list(star_id)

      ! Clear return code
      jo = 0
      ! Solve for structure, mesh, and major composition variables
      joc = 1

      ! Do star 1 in a binary
      Jstar = 1
      jb = 1
      isb = 1
      ktw = 1

      dty = dt/csy
      if (verbose) print *, 'taking timestep ',dty,'yr for star', current_star

      ! Determine number of allowed iterations before backup
      iter = star%normal_iter
      if (jnn < switch_iterations) iter = star%startup_iter

      ! Set maximum mass the star can reach through accretion, basically infinite
      if (star%maximum_mass < 0.0d0) then
         star%uc(13) = 2.d0 * star%H(VAR_MASS, 1) / cmsn
      else
         star%uc(13) = star%maximum_mass
      end if

      ! Set timestep control/minimum timestep
      tdyn = 1. / (csy*sqrt(cg * h(VAR_MASS, 1) / exp(3.*h(VAR_LNR, 1))))
      star%uc(12) = tdyn * csy
      uc = star%uc

      ! Don't show iteration output, unless we're printing verbose output.
      kt5 = iter
      if (verbose) kt5 = 0

      call smart_solver ( iter, star%eqns, kt5, jo )

      ! Converged if JO == 0
      if ( jo /= 0 ) then
         if (verbose) print *, 'failed to converge on timestep'
         ! If no convergence, restart from 2 steps back, DT decreased substantially
         do while (jo /= 0)
            call backup ( dty, jo )
            if ( jo == 2 ) then
               evolve_one_timestep = jo
               return
            end if
            call nextdt ( dty, jo, 22 )

            if (verbose) print *, 'timestep reduced to', dty,'yr'

            ! If the timestep is (well) below the dynamical timescale for the star, abort
            if (dty < tdyn) then
               evolve_one_timestep = 2
               return
            end if

            if ( jo == 3 ) then
               evolve_one_timestep = jo
               return
            end if
            jnn = jnn + 1
            jo = 0
            call smart_solver ( iter, star%eqns, kt5, jo )
         end do
      end if

      ! If converged, update nucleosynthesis (if wanted)
      ! *TODO*

      ! If not converged, diagnose mode of failure.
      !
      ! If close to the helium flash, try to skip over the problem by "going around"
      ! This is a multi-step process:
      ! 1. Evolve a reference model (3 Msun) until He ignition
      ! 2. Strip the envelope until we are left with a low-mass He star model
      ! 3. Follow the steps of FGB2HB:
      !    Accrete material of the desired surface composition. Allow H to burn.
      !    Stop accretion when the star has reached the desired mass.
      !    Stop evolution when the star has reached the desired core mass.
      !    Fix the composition profile of the envelope, based on the last pre-flash model.
      ! *TODO*
      ! *TODO*: make a switch to enable or disable this behaviour
      ! *TODO*: we can simplify this process by constructing the core directly as a low-mass He star.
      !         Rewrite fgb2hb to work like this.
      !
      ! If stuck on the way to the white dwarf cooling track, eliminate the H shell.


      if (verbose) print *, 'converged on timestep'
      ! ----------------------------------------------------------
      ! Compute quantities
      ! ----------------------------------------------------------
      call compute_output_quantities ( Jstar )

      ! -------------------------------------------------------------------
      ! Update quantities that have to be calculated explicitly
      ! -------------------------------------------------------------------
      call update_explicit_quantities( Jstar )

      ! -------------------------------------------------------------------
      ! Update the control parameters for the next timestep
      ! -------------------------------------------------------------------
      call update_timestep_parameters( Jstar )

      call update ( dty )
      call nextdt ( dty, jo, 22 )
      jnn = jnn + 1

      if (dty < tdyn) dty = tdyn * 1.1
      dt = dty * csy

      ! Synchronise the star-list with the evolution code
      call swap_out()
   end function evolve_one_timestep



   integer function evolve_until_model_time(star_id, time)
      use stopping_conditions, only: uc
      use test_variables, only: dt
      use constants
      implicit none
      integer, intent(in) :: star_id
      real(double), intent(in) :: time
      real(double) :: age, dty, dty_min, dty_max

      if (star_id /= current_star) call select_star(star_id)

      dty_min = uc(12)/csy
      do while (age_of(star_id) < time)
         ! Tweak the timestep when we are close to the target age so that we don't overshoot,
         ! but also don't suddenly change the timestep srastically
         age = age_of(star_id)
         dty = dt / csy
         dty_max = time - age
         if ( age+2*dty < time .and. age+3*dty >= time) then
            ! We expect three more timesteps, start constraining the timestep
            dty = 0.4*max(dty_max, dty_min )
         end if
         if ( age+dty < time .and. age+2*dty >= time) then
            ! We expect maybe two more timesteps, constrain
            dty = 0.6*max(dty_max, dty_min )
         end if
         if ( age+dty >= time .and. age<time) then
            ! This is our final timestep
            dty = min(dty_max, dty )
         end if

         ! Age reached
         if ( dty_max <= dty_min ) then
            evolve_until_model_time = 0
            return
         end if
         dt = dty * csy

         evolve_until_model_time = evolve_one_timestep(star_id)

         ! Abort in case of convergence failure
         if (evolve_until_model_time /= 0) return
      end do
   end function evolve_until_model_time



   integer function synchronise_stars(star_id1, star_id2)
      implicit none
      integer, intent(in) :: star_id1, star_id2

      synchronise_stars = 0
      if (age_of(star_id1) < age_of(star_id2)) then
         synchronise_stars = evolve_until_model_time(star_id1, age_of(star_id2))
      elseif (age_of(star_id2) < age_of(star_id1)) then
         synchronise_stars = evolve_until_model_time(star_id2, age_of(star_id1))
      endif
   end function synchronise_stars



   ! Join the two stars in a binary with the given orbital period (in days) and eccentricity
   integer function join_binary(id1, id2, period, ecc)
      use test_variables, only: dt, age
      use current_model_properties
      use constants
      use indices
      implicit none
      integer, intent(in) :: id1, id2
      real(double), intent(in) :: period, ecc
      type(twin_star_t), pointer :: binary, primary, secondary
      real(double) :: tm, om, bm, oa, bper
      integer :: new_id

      ! Make sure the two single stars are not already part of a binary system
      if (.not. (is_single_star(id1) .and. is_single_star(id2))) then
         join_binary = 0
         return
      end if

      ! Make sure arrays are current
      if (id1 == current_star .or. id2 == current_star) call swap_out()

      new_id = allocate_star()
      if (new_id == 0) then
         join_binary = 0
         return
      end if
      binary => star_list(new_id)

      if (star_list(id1)%zams_mass > star_list(id2)%zams_mass) then
         binary%pid = id1
         binary%sid = id2
      else
         binary%pid = id2
         binary%sid = id1
      end if

      primary => star_list(binary%pid)
      secondary => star_list(binary%sid)

      ! Calculate orbit variables from orbital elements
      tm = cmsn * mass_of(binary%pid)
      om = cmsn * mass_of(binary%sid)
      bm = tm + om
      bper = period
      oa = cg1*tm*om*(cg2*bper/bm)**c3rd*sqrt(1.0d0 - ecc*ecc)

      ! Allocate memory for this star
      binary%number_of_variables = NVBIN
      binary%number_of_meshpoints = primary%number_of_meshpoints
      allocate(binary%h(binary%number_of_variables, binary%number_of_meshpoints))
      allocate(binary%dh(binary%number_of_variables, binary%number_of_meshpoints))
      allocate(binary%hpr(binary%number_of_variables, binary%number_of_meshpoints))

      binary%h(VAR_HORB, :) = oa
      binary%h(VAR_ECC, :) = ecc
      binary%h(VAR_XI, :) = 0.0d0
      binary%h(VAR_BMASS, :) = bm
      binary%h(VAR_PMASS, :) = tm

      binary%hpr(VAR_HORB, :) = oa
      binary%hpr(VAR_ECC, :) = ecc
      binary%hpr(VAR_XI, :) = 0.0d0
      binary%hpr(VAR_BMASS, :) = bm
      binary%hpr(VAR_PMASS, :) = tm

      binary%dh = 0.0d0

      current_star = new_id
      binary%eqns = eqns_binary
      binary%startup_iter = primary%startup_iter
      binary%normal_iter = max(primary%normal_iter, secondary%normal_iter)

      binary%uc = (/ 1.00E-01, 2.00E+12, 1.00E+02, 0.00E+00, 3.00E+00, 5.30E+00, 1.20E+00, &
                     6.30E+00, 3.00E+02, 0.00E+00, 1.00E-06, 1.00E+06, 1.00E+03, 1.00E+03, &
                     0.00E+00, 0.00E+00, 0.00E+00, 0.00E+00, 0.00E+00, 0.00E+00, 0.00E+00 /)
      binary%maximum_mass = -1.0

      rlf_prev = (/0.0, 0.0/)   ! Previous value of Roche-lobe filling factor
      qcnv_prev = (/0.0, 0.0/)  ! Previous value of mass fraction of convective envelope
      lnuc_prev = (/0.0, 0.0/)  ! Previous value of nuclear burning luminosity
      lhe_prev = (/0.0, 0.0/)   ! Previous value of He burning luminosity
      lh_prev = (/0.0, 0.0/)    ! Previous value of H burning luminosity

      binary%exists = .true.

      ! Estimate nuclear timescale for this star
      binary%dt = min(primary%dt, secondary%dt)
      dt = binary%dt
      age = binary%age

      call swap_out()

      join_binary = new_id
   end function join_binary


   integer function set_ev_path(new_ev_path)
      use file_exists_module
      implicit none
      character(len=*), intent(in) :: new_ev_path
      if (.not. file_exists(new_ev_path) ) then
         if (.not. file_exists(trim(new_ev_path)//'/input/amuse/init.dat') ) then
            if (verbose) print *, "Warning: file ",trim(new_ev_path)," for ", trim(amuse_ev_path), " does not exist!"
            set_ev_path = -1
            return
         end if
      end if
      amuse_ev_path = new_ev_path
      set_ev_path = 0
   end function

   ! Does nothing, but part of standard AMUSE interface
   integer function commit_parameters()
      implicit none
      commit_parameters = initialise_twin(amuse_ev_path, amuse_nstars, amuse_Z, &
         amuse_verbose, amuse_nmesh)
   end function
   integer function recommit_parameters()
      implicit none
      recommit_parameters = 0
   end function
   integer function commit_particles()
      implicit none
      commit_particles = 0
   end function
   integer function recommit_particles()
      implicit none
      recommit_particles = 0
   end function




! TODO: need to implement these:


! Return the maximum_number_of_stars parameter
   integer function get_maximum_number_of_stars(value)
      implicit none
      integer, intent(out) :: value
      value = max_stars
      get_maximum_number_of_stars = 0
   end function
   
! Set the maximum_number_of_stars parameter
   integer function set_maximum_number_of_stars(value)
      implicit none
      integer, intent(in) :: value
      set_maximum_number_of_stars = -1
   end function

   integer function get_mixing_length_ratio(value)
      implicit none
      real(double), intent(out) :: value
      get_mixing_length_ratio = -1
   end function
   integer function set_mixing_length_ratio(value)
      implicit none
      real(double), intent(in) :: value
      set_mixing_length_ratio = -1
   end function

   integer function get_min_timestep_stop_condition(value)
      implicit none
      real(double), intent(out) :: value
      get_min_timestep_stop_condition = -1
   end function
   integer function set_min_timestep_stop_condition(value)
      implicit none
      real(double), intent(in) :: value
      set_min_timestep_stop_condition = -1
   end function

   integer function get_max_age_stop_condition(value)
      implicit none
      real(double), intent(out) :: value
      get_max_age_stop_condition = -1
   end function
   integer function set_max_age_stop_condition(value)
      implicit none
      real(double), intent(in) :: value
      set_max_age_stop_condition = -1
   end function

   integer function get_semi_convection_efficiency(value)
      implicit none
      real(double), intent(out) :: value
      get_semi_convection_efficiency = -1
   end function
   integer function set_semi_convection_efficiency(value)
      implicit none
      real(double), intent(in) :: value
      set_semi_convection_efficiency = -1
   end function

   integer function get_metallicity(value)
      implicit none
      real(double), intent(out) :: value
      value = amuse_Z
      get_metallicity = 0
   end function
   integer function set_metallicity(value)
      implicit none
      real(double), intent(in) :: value
      amuse_Z = value
      set_metallicity = 0
   end function

   integer function initialize_code()
      implicit none
      amuse_ev_path = 'src/trunk'
      amuse_nstars = 1000
      amuse_nmesh = 500
      amuse_verbose = .true.
      amuse_Z = 0.02d0
      initialize_code = 0
   end function

   integer function cleanup_code()
      implicit none
      cleanup_code = 0
   end function

   integer function evolve_for(star_id, delta_t)
      implicit none
      integer, intent(in) :: star_id
      real(double), intent(in) :: delta_t
      evolve_for = -1
   end function
   integer function evolve_one_step(star_id)
      implicit none
      integer, intent(in) :: star_id
      evolve_one_step = -1
   end function

   integer function get_wind_mass_loss_rate(star_id, value)
      implicit none
      integer, intent(in) :: star_id
      real(double), intent(out) :: value
      get_wind_mass_loss_rate = -1
   end function

   integer function get_spin(star_id, value)
      implicit none
      integer, intent(in) :: star_id
      real(double), intent(out) :: value
      get_spin = -1
   end function

   integer function get_number_of_particles(value)
      implicit none
      integer, intent(out) :: value
      get_number_of_particles = -1
   end function

end module twinlib
