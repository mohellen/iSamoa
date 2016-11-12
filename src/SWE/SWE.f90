! Sam(oa)² - SFCs and Adaptive Meshes for Oceanic And Other Applications
! Copyright (C) 2010 Oliver Meister, Kaveh Rahnema
! This program is licensed under the GPL, for details see the file LICENSE


#include "Compilation_control.f90"

#if defined(_SWE)
	MODULE SWE
		use SFC_edge_traversal
		use SWE_data_types

		use SWE_adapt
		use SWE_initialize_bathymetry
		use SWE_initialize_dofs
		use SWE_displace
		use SWE_output
		use SWE_xml_output
		use SWE_ascii_output
		use SWE_point_output
		use SWE_euler_timestep

		use Samoa_swe

		implicit none

		PRIVATE
		PUBLIC t_swe

		type t_swe
            type(t_swe_init_b_traversal)            :: init_b
            type(t_swe_init_dofs_traversal)         :: init_dofs
            type(t_swe_displace_traversal)          :: displace
            type(t_swe_output_traversal)            :: output
            type(t_swe_xml_output_traversal)        :: xml_output
            type(t_swe_ascii_output_traversal)      :: ascii_output
	        type(t_swe_point_output_traversal)	    :: point_output

            type(t_swe_euler_timestep_traversal)    :: euler
            type(t_swe_adaption_traversal)          :: adaption

            contains

            procedure, pass :: create => swe_create
            procedure, pass :: run => swe_run
            procedure, pass :: destroy => swe_destroy
        end type

#       if defined(_IMPI)
        type t_impi_bcast
            integer (kind=GRID_SI) :: i_stats_phase    ! MPI_INTEGER4
            integer (kind=GRID_SI) :: i_initial_step
            integer (kind=GRID_SI) :: i_time_step
!            integer (kind=GRID_SI) :: i_output_iteration
            real (kind=GRID_SR)    :: r_time_next_output  ! MPI_DOUBLE_PRECISION
            real (kind=GRID_SR)    :: r_time
            real (kind=GRID_SR)    :: r_dt
            real (kind=GRID_SR)    :: r_dt_new
            logical                :: is_forward    ! MPI_LOGICAL
        end type t_impi_bcast
#       endif

		contains

		!> Creates all required runtime objects for the scenario
		subroutine swe_create(swe, grid, l_log, i_asagi_mode)
            class(t_swe), intent(inout)                                 :: swe
			type(t_grid), intent(inout)									:: grid
			logical, intent(in)						                    :: l_log
			integer, intent(in)											:: i_asagi_mode

			!local variables
			character(len=64)											:: s_date, s_time
			character(len=256)                                          :: s_log_name
			integer                                                     :: i_error

			call date_and_time(s_date, s_time)

#           if defined(_MPI)
            call mpi_bcast(s_date, len(s_date), MPI_CHARACTER, 0, MPI_COMM_WORLD, i_error); assert_eq(i_error, 0)
            call mpi_bcast(s_time, len(s_time), MPI_CHARACTER, 0, MPI_COMM_WORLD, i_error); assert_eq(i_error, 0)
#           endif

            swe%output%s_file_stamp = trim(cfg%output_dir) // "/swe_" // trim(s_date) // "_" // trim(s_time)
			swe%xml_output%s_file_stamp = trim(cfg%output_dir) // "/swe_" // trim(s_date) // "_" // trim(s_time)
            swe%point_output%s_file_stamp = trim(cfg%output_dir) // "/swe_" // trim(s_date) // "_" // trim(s_time)
			s_log_name = trim(swe%xml_output%s_file_stamp) // ".log"

# if defined(_IMPI)
            ! At this point, JOINING ranks do not have the right file name yet
            ! prevent them from creating a wrong file
            if (status_MPI .ne. MPI_ADAPT_STATUS_JOINING) then
# endif
                if (l_log) then
                    _log_open_file(s_log_name)
                end if
# if defined(_IMPI)
            end if
# endif

			call load_scenario(grid)

			call swe%init_b%create()
			call swe%init_dofs%create()
            call swe%displace%create()
            call swe%output%create()
            call swe%xml_output%create()
            call swe%ascii_output%create()
            call swe%euler%create()
            call swe%adaption%create()
		end subroutine

		subroutine load_scenario(grid)
			type(t_grid), intent(inout)             :: grid

			integer                                 :: i_error

#			if defined(_ASAGI)
                cfg%afh_bathymetry = asagi_grid_create(ASAGI_FLOAT)
                cfg%afh_displacement = asagi_grid_create(ASAGI_FLOAT)

#               if defined(_MPI)
                    call asagi_grid_set_comm(cfg%afh_bathymetry, MPI_COMM_WORLD)
                    call asagi_grid_set_comm(cfg%afh_displacement, MPI_COMM_WORLD)
#               endif

                call asagi_grid_set_threads(cfg%afh_bathymetry, cfg%i_threads)
                call asagi_grid_set_threads(cfg%afh_displacement, cfg%i_threads)

                !convert ASAGI mode to ASAGI parameters

                select case(cfg%i_asagi_mode)
                    case (0)
                        !i_asagi_hints = GRID_NO_HINT
                    case (1)
                        !i_asagi_hints = ieor(GRID_NOMPI, GRID_PASSTHROUGH)
                        call asagi_grid_set_param(cfg%afh_bathymetry, "grid", "pass_through")
                        call asagi_grid_set_param(cfg%afh_displacement, "grid", "pass_through")
                    case (2)
                        !i_asagi_hints = GRID_NOMPI
                    case (3)
                        !i_asagi_hints = ieor(GRID_NOMPI, SMALL_CACHE)
                    case (4)
                        !i_asagi_hints = GRID_LARGE_GRID
                        call asagi_grid_set_param(cfg%afh_bathymetry, "grid", "cache")
                        call asagi_grid_set_param(cfg%afh_displacement, "grid", "cache")
                    case default
                        try(.false., "Invalid asagi mode, must be in range 0 to 4")
                end select

                !$omp parallel private(i_error), copyin(cfg)
                    i_error = asagi_grid_open(cfg%afh_bathymetry,  trim(cfg%s_bathymetry_file), 0); assert_eq(i_error, ASAGI_SUCCESS)
                    i_error = asagi_grid_open(cfg%afh_displacement, trim(cfg%s_displacement_file), 0); assert_eq(i_error, ASAGI_SUCCESS)
                !$omp end parallel

                associate(afh_d => cfg%afh_displacement, afh_b => cfg%afh_bathymetry)
                    cfg%scaling = max(asagi_grid_max(afh_b, 0) - asagi_grid_min(afh_b, 0), asagi_grid_max(afh_b, 1) - asagi_grid_min(afh_b, 1))

                    cfg%offset = [0.5_GRID_SR * (asagi_grid_min(afh_d, 0) + asagi_grid_max(afh_d, 0)), 0.5_GRID_SR * (asagi_grid_min(afh_d, 1) + asagi_grid_max(afh_d, 1))] - 0.5_GRID_SR * cfg%scaling
                    cfg%offset = min(max(cfg%offset, [asagi_grid_min(afh_b, 0), asagi_grid_min(afh_b, 1)]), [asagi_grid_max(afh_b, 0), asagi_grid_max(afh_b, 1)] - cfg%scaling)

                    if (asagi_grid_dimensions(afh_d) > 2) then
                        cfg%dt_eq = asagi_grid_delta(afh_d, 2)
                        cfg%t_min_eq = asagi_grid_min(afh_d, 2)
                        cfg%t_max_eq = asagi_grid_max(afh_d, 2)
                    else
                        cfg%dt_eq = 0.0_SR
                        cfg%t_min_eq = 0.0_SR
                        cfg%t_max_eq = 0.0_SR
                    end if

                    if (rank_MPI == 0) then
                        _log_write(1, '(" SWE: loaded ", A, ", domain: [", F0.2, ", ", F0.2, "] x [", F0.2, ", ", F0.2, "]")') &
                            trim(cfg%s_bathymetry_file), asagi_grid_min(afh_b, 0), asagi_grid_max(afh_b, 0),  asagi_grid_min(afh_b, 1), asagi_grid_max(afh_b, 1)
                        _log_write(1, '(" SWE:  dx: ", F0.2, " dy: ", F0.2)') asagi_grid_delta(afh_b, 0), asagi_grid_delta(afh_b, 1)

                        !if the data file has more than two dimensions, we assume that it contains time-dependent displacements
                        if (asagi_grid_dimensions(afh_d) > 2) then
                            _log_write(1, '(" SWE: loaded ", A, ", domain: [", F0.2, ", ", F0.2, "] x [", F0.2, ", ", F0.2, "], time: [", F0.2, ", ", F0.2, "]")') &
                            trim(cfg%s_displacement_file), asagi_grid_min(afh_d, 0), asagi_grid_max(afh_d, 0),  asagi_grid_min(afh_d, 1), asagi_grid_max(afh_d, 1), asagi_grid_min(afh_d, 2), asagi_grid_max(afh_d, 2)
                            _log_write(1, '(" SWE:  dx: ", F0.2, " dy: ", F0.2, " dt: ", F0.2)') asagi_grid_delta(afh_d, 0), asagi_grid_delta(afh_d, 1), asagi_grid_delta(afh_d, 2)
                        else
                            _log_write(1, '(" SWE: loaded ", A, ", domain: [", F0.2, ", ", F0.2, "] x [", F0.2, ", ", F0.2, "]")') &
                            trim(cfg%s_displacement_file), asagi_grid_min(afh_d, 0), asagi_grid_max(afh_d, 0),  asagi_grid_min(afh_d, 1), asagi_grid_max(afh_d, 1)
                            _log_write(1, '(" SWE:  dx: ", F0.2, " dy: ", F0.2)') asagi_grid_delta(afh_d, 0), asagi_grid_delta(afh_d, 1)
                        end if

                        _log_write(1, '(" SWE: computational domain: [", F0.2, ", ", F0.2, "] x [", F0.2, ", ", F0.2, "]")'), cfg%offset(1), cfg%offset(1) + cfg%scaling, cfg%offset(2), cfg%offset(2) + cfg%scaling
                    end if
               end associate
#           else
                cfg%scaling = 10.0_GRID_SR
                cfg%offset = cfg%scaling * [-0.5_GRID_SR, -0.5_GRID_SR]
#			endif
		end subroutine

		!> Destroys all required runtime objects for the scenario
		subroutine swe_destroy(swe, grid, l_log)
            class(t_swe), intent(inout)     :: swe
			type(t_grid), intent(inout)     :: grid
			logical, intent(in)		        :: l_log

			call swe%init_b%destroy()
			call swe%init_dofs%destroy()
            call swe%displace%destroy()
            call swe%output%destroy()
            call swe%xml_output%destroy()
            call swe%ascii_output%destroy()
            call swe%point_output%destroy()
            call swe%euler%destroy()
            call swe%adaption%destroy()

#			if defined(_ASAGI)
				call asagi_grid_close(cfg%afh_displacement)
				call asagi_grid_close(cfg%afh_bathymetry)
#			endif

			if (l_log) then
				_log_close_file()
			endif
		end subroutine

		!*********************************
		! run()-method
		!*********************************

		!> Sets the initial values of the SWE and runs the time steps
		subroutine swe_run(swe, grid)
            class(t_swe), intent(inout) :: swe
			type(t_grid), intent(inout)	:: grid

			real (kind = GRID_SR)		:: r_time_next_output
			type(t_grid_info)           :: grid_info, grid_info_max
			integer (kind = GRID_SI)    :: i_initial_step, i_time_step
			integer  (kind = GRID_SI)   :: i_stats_phase, err

#           if defined(_IMPI)
            real (kind = GRID_SR)  :: tic, toc
            integer                :: IMPI_BCAST_TYPE
            call create_impi_bcast_type(IMPI_BCAST_TYPE)
#           endif

#           if defined(_IMPI)
            !Only the NON-joining procs do initialization
			if (status_MPI /= MPI_ADAPT_STATUS_JOINING) then
#           endif

                !init parameters
                r_time_next_output = 0.0_GRID_SR

                if (rank_MPI == 0) then
                    !$omp master
                    _log_write(0, *) "SWE: setting initial values and a priori refinement.."
                    _log_write(0, *) ""
                    !$omp end master
                end if

                call update_stats(swe, grid)
                i_stats_phase = 0

                i_initial_step = 0

                !initialize the bathymetry
                call swe%init_b%traverse(grid)

                do
                    !initialize dofs and set refinement conditions
                    call swe%init_dofs%traverse(grid)

                    if (rank_MPI == 0) then
                        grid_info%i_cells = grid%get_cells(MPI_SUM, .false.)

                        !$omp master
                        _log_write(1, "(A, I0, A, I0, A)") " SWE: ", i_initial_step, " adaptions, ", grid_info%i_cells, " cells"
                        !$omp end master
                    end if

                    grid_info%i_cells = grid%get_cells(MPI_SUM, .true.)
                    if (swe%init_dofs%i_refinements_issued .le. 0) then
                        exit
                    endif

                    call swe%adaption%traverse(grid)

                    !output grids during initial phase if and only if t_out is 0
                    if (cfg%r_output_time_step == 0.0_GRID_SR) then
                        if (cfg%l_ascii_output) then
                            call swe%ascii_output%traverse(grid)
                        end if

                        if(cfg%l_gridoutput) then
                            call swe%xml_output%traverse(grid)
                        end if

                        if (cfg%l_pointoutput) then
                            call swe%point_output%traverse(grid)
                        end if

                        r_time_next_output = r_time_next_output + cfg%r_output_time_step
                    end if

                    i_initial_step = i_initial_step + 1
                end do

                grid_info = grid%get_info(MPI_SUM, .true.)

                if (rank_MPI == 0) then
                    !$omp master
                    _log_write(0, *) "SWE: done."
                    _log_write(0, *) ""

                    call grid_info%print()
                    !$omp end master
                end if

! Grid output 0
                !output initial grid
                if (cfg%i_output_time_steps > 0 .or. cfg%r_output_time_step >= 0.0_GRID_SR) then
                    if (cfg%l_ascii_output) then
                        call swe%ascii_output%traverse(grid)
                    end if

                    if(cfg%l_gridoutput) then
                        call swe%xml_output%traverse(grid)
                    end if

                    if (cfg%l_pointoutput) then
                        call swe%point_output%traverse(grid)
                    end if

                    r_time_next_output = r_time_next_output + cfg%r_output_time_step
                end if

                !print initial stats
                if (cfg%i_stats_phases >= 0) then
                    call update_stats(swe, grid)

                    i_stats_phase = i_stats_phase + 1
                end if

                !$omp master
                call swe%init_dofs%reduce_stats(MPI_SUM, .true.)
                call swe%adaption%reduce_stats(MPI_SUM, .true.)
                call grid%reduce_stats(MPI_SUM, .true.)

                if (rank_MPI == 0) then
                    _log_write(0, *) "SWE: running time steps.."
                    _log_write(0, *) ""
                end if
                !$omp end master

                i_time_step = 0

#               if defined(_ASAGI)
                ! during the earthquake, do small time steps that include a displacement
                do
                    if ((cfg%r_max_time >= 0.0 .and. grid%r_time >= cfg%r_max_time) .or. (cfg%i_max_time_steps >= 0 .and. i_time_step >= cfg%i_max_time_steps)) then
                        exit
                    end if

                    if (grid%r_time > cfg%t_max_eq) then
                        exit
                    end if

                    i_time_step = i_time_step + 1

                    if (cfg%i_adapt_time_steps > 0 .and. mod(i_time_step, cfg%i_adapt_time_steps) == 0) then
                        !refine grid
                        call swe%adaption%traverse(grid)
                    end if

                    !do an euler time step
                    call swe%euler%traverse(grid)

                    !displace time-dependent bathymetry
                    call swe%displace%traverse(grid)

                    if (rank_MPI == 0) then
                        grid_info%i_cells = grid%get_cells(MPI_SUM, .false.)
                        !$omp master
                        _log_write(1, '(" SWE: EQ time step: ", I0, ", sim. time:", A, ", dt:", A, ", cells: ", I0)') &
                                i_time_step, trim(time_to_hrt(grid%r_time)), trim(time_to_hrt(grid%r_dt)), grid_info%i_cells
                        !$omp end master
                    end if

                    !output grid
                    if ((cfg%i_output_time_steps > 0 .and. mod(i_time_step, cfg%i_output_time_steps) == 0) .or. &
                        (cfg%r_output_time_step >= 0.0_GRID_SR .and. grid%r_time >= r_time_next_output)) then

                        if (cfg%l_ascii_output) then
                            call swe%ascii_output%traverse(grid)
                        end if

                        if(cfg%l_gridoutput) then
                            call swe%xml_output%traverse(grid)
                        end if

                        if (cfg%l_pointoutput) then
                            call swe%point_output%traverse(grid)
                        end if

                        r_time_next_output = r_time_next_output + cfg%r_output_time_step
                    end if
                end do

                !print EQ phase stats
                if (cfg%i_stats_phases >= 0) then
                    call update_stats(swe, grid)
                end if
#               endif

#           if defined(_IMPI)
            ! JOINING ranks call impi_adapt immediately,
            ! avoiding initialization and earthquake phase
            else
                call impi_adapt(swe, grid, i_stats_phase, i_initial_step, i_time_step, r_time_next_output, IMPI_BCAST_TYPE)
            end if

            tic = mpi_wtime()
#           endif

            !regular tsunami time steps begin after the earthquake is over

			do
			    !check for loop termination
				if ((cfg%r_max_time >= 0.0 .and. grid%r_time >= cfg%r_max_time) .or. &
				        (cfg%i_max_time_steps >= 0 .and. i_time_step >= cfg%i_max_time_steps)) then
					exit
				end if

                !increment time step
				i_time_step = i_time_step + 1

			    !refine grid
                if (cfg%i_adapt_time_steps > 0 .and. mod(i_time_step, cfg%i_adapt_time_steps) == 0) then
                    call swe%adaption%traverse(grid)
                end if

				!do a time step
				call swe%euler%traverse(grid)

                !master print screen
                if (rank_MPI == 0) then
                    grid_info%i_cells = grid%get_cells(MPI_SUM, .false.)
                    !$omp master
#                   if defined(_IMPI)
                    _log_write(1, '(" SWE: time step: ", I0, ", sim. time:", A, ", dt:", A, ", cells: ", I0, ", ranks: ", I0)') &
                            i_time_step, trim(time_to_hrt(grid%r_time)), trim(time_to_hrt(grid%r_dt)), grid_info%i_cells, size_MPI
#                   else
                    _log_write(1, '(" SWE: time step: ", I0, ", sim. time:", A, ", dt:", A, ", cells: ", I0)') &
                            i_time_step, trim(time_to_hrt(grid%r_time)), trim(time_to_hrt(grid%r_dt)), grid_info%i_cells
#                   endif
                    !$omp end master
                end if

				!output grid
				if ((cfg%i_output_time_steps > 0 .and. mod(i_time_step, cfg%i_output_time_steps) == 0) .or. &
				    (cfg%r_output_time_step >= 0.0_GRID_SR .and. grid%r_time >= r_time_next_output)) then

                    if (cfg%l_ascii_output) then
             	       call swe%ascii_output%traverse(grid)
               	    end if

                    if(cfg%l_gridoutput) then
                        call swe%xml_output%traverse(grid)
                    end if

                    if (cfg%l_pointoutput) then
                        call swe%point_output%traverse(grid)
                    end if

					r_time_next_output = r_time_next_output + cfg%r_output_time_step
				end if

                !print stats
                if ((cfg%r_max_time >= 0.0d0 .and. grid%r_time * cfg%i_stats_phases >= i_stats_phase * cfg%r_max_time) .or. &
                    (cfg%i_max_time_steps >= 0 .and. i_time_step * cfg%i_stats_phases >= i_stats_phase * cfg%i_max_time_steps)) then
                    call update_stats(swe, grid)

                    i_stats_phase = i_stats_phase + 1
                end if

#               if defined(_IMPI)
                !Existing ranks call impi_adapt
                toc = mpi_wtime() - tic
                call mpi_bcast(toc, 1, MPI_DOUBLE_PRECISION, 0, MPI_COMM_WORLD, err); assert_eq(err, 0)
                if (toc > 30) then
                    call impi_adapt(swe, grid, i_stats_phase, i_initial_step, i_time_step, r_time_next_output, IMPI_BCAST_TYPE)
                    tic = mpi_wtime()
                end if
#               endif
			end do

            grid_info = grid%get_info(MPI_SUM, .true.)
            grid_info_max = grid%get_info(MPI_MAX, .true.)

            !$omp master
            if (rank_MPI == 0) then
                _log_write(0, '(" SWE: done.")')
                _log_write(0, '()')
                _log_write(0, '("  Cells: avg: ", I0, " max: ", I0)') &
                        grid_info%i_cells / (omp_get_max_threads() * size_MPI), grid_info_max%i_cells
                _log_write(0, '()')

                call grid_info%print()
            end if
            !$omp end master
		end subroutine

        subroutine update_stats(swe, grid)
            class(t_swe), intent(inout)   :: swe
 			type(t_grid), intent(inout)     :: grid

 			double precision, save          :: t_phase = huge(1.0d0)

			!$omp master
                !Initially, just start the timer and don't print anything
                if (t_phase < huge(1.0d0)) then
                    t_phase = t_phase + get_wtime()

                    call swe%init_dofs%reduce_stats(MPI_SUM, .true.)
                    call swe%displace%reduce_stats(MPI_SUM, .true.)
                    call swe%euler%reduce_stats(MPI_SUM, .true.)
                    call swe%adaption%reduce_stats(MPI_SUM, .true.)
                    call grid%reduce_stats(MPI_SUM, .true.)

                    if (rank_MPI == 0) then
                        _log_write(0, *) ""
                        _log_write(0, *) "Phase statistics:"
                        _log_write(0, *) ""
                        _log_write(0, '(A, T34, A)') " Init: ", trim(swe%init_dofs%stats%to_string())
                        _log_write(0, '(A, T34, A)') " Displace: ", trim(swe%displace%stats%to_string())
                        _log_write(0, '(A, T34, A)') " Time steps: ", trim(swe%euler%stats%to_string())
                        _log_write(0, '(A, T34, A)') " Adaptions: ", trim(swe%adaption%stats%to_string())
                        _log_write(0, '(A, T34, A)') " Grid: ", trim(grid%stats%to_string())
                        _log_write(0, '(A, T34, F12.4, A)') " Element throughput: ", 1.0d-6 * dble(grid%stats%get_counter(traversed_cells)) / t_phase, " M/s"
                        _log_write(0, '(A, T34, F12.4, A)') " Memory throughput: ", dble(grid%stats%get_counter(traversed_memory)) / ((1024 * 1024 * 1024) * t_phase), " GB/s"
                        _log_write(0, '(A, T34, F12.4, A)') " Cell update throughput: ", 1.0d-6 * dble(swe%euler%stats%get_counter(traversed_cells)) / t_phase, " M/s"
                        _log_write(0, '(A, T34, F12.4, A)') " Flux solver throughput: ", 1.0d-6 * dble(swe%euler%stats%get_counter(traversed_edges)) / t_phase, " M/s"
                        _log_write(0, '(A, T34, F12.4, A)') " Asagi time:", grid%stats%get_time(asagi_time), " s"
                        _log_write(0, '(A, T34, F12.4, A)') " Phase time:", t_phase, " s"
                        _log_write(0, *) ""
                    end if
                end if

                call swe%init_dofs%clear_stats()
                call swe%displace%clear_stats()
                call swe%euler%clear_stats()
                call swe%adaption%clear_stats()
                call grid%clear_stats()

                t_phase = -get_wtime()
            !$omp end master
        end subroutine

        subroutine impi_adapt(swe, grid, i_stats_phase, i_initial_step, i_time_step, r_time_next_output, IMPI_BCAST_TYPE)
            class(t_swe), intent(inout)           :: swe
            type(t_grid), intent(inout)           :: grid
            integer (kind=GRID_SI), intent(inout) :: i_stats_phase, i_initial_step, i_time_step
            real (kind=GRID_SR), intent(inout)    :: r_time_next_output
            integer, intent(in)                   :: IMPI_BCAST_TYPE

#           if defined(_IMPI)
            integer :: adapt_flag, NEW_COMM, INTER_COMM
            integer :: staying_count, leaving_count, joining_count
            integer :: info, status, err
            real (kind=GRID_SR) :: tic, toc, tic1, toc1
            type(t_impi_bcast) :: bcast_packet
            character(len=256) :: s_log_name

            tic = mpi_wtime()
            call mpi_probe_adapt(adapt_flag, status_MPI, info, err)
            toc = mpi_wtime() - tic

            _log_write(1, '("Rank ", I0, " (", I0, "): probe_adapt", E10.2, " sec")') &
                    rank_MPI, status_MPI, toc

            if (adapt_flag == MPI_ADAPT_TRUE) then
                tic1 = mpi_wtime()

                tic = mpi_wtime()
                call mpi_comm_adapt_begin(INTER_COMM, NEW_COMM, &
                        staying_count, leaving_count, joining_count, err); assert_eq(err, 0)
                toc = MPI_Wtime() - tic

                _log_write(1, '("Rank ", I0, " (", I0, "): adapt_begin ", E10.2, " sec, staying ", I0, ", leaving ", I0, ", joining ", I0)') &
                        rank_MPI, status_MPI, toc, staying_count, leaving_count, joining_count

                !************************ ADAPT WINDOW ****************************
                !(1) LEAVING ranks dump data to STAYING ranks
                if (leaving_count > 0) then
                    call distribute_load_for_resource_shrinkage(grid, size_MPI, leaving_count, rank_MPI)
                end if

                !(2) JOINING ranks get necessary data from MASTER
                !    The use of NEW_COMM must exclude LEAVING ranks, because they have NEW_COMM == MPI_COMM_NULL
                if ((joining_count > 0) .and. (status_MPI .ne. MPI_ADAPT_STATUS_LEAVING)) then
                    bcast_packet = t_impi_bcast(i_stats_phase, i_initial_step, i_time_step, &!swe%output%i_output_iteration, &
                            r_time_next_output, grid%r_time, grid%r_dt, grid%r_dt_new, grid%sections%is_forward())
                    call mpi_bcast(bcast_packet, 1, IMPI_BCAST_TYPE, 0, NEW_COMM, err); assert_eq(err, 0)
                    call mpi_bcast(swe%output%s_file_stamp, len(swe%output%s_file_stamp), MPI_CHARACTER, 0, NEW_COMM, err); assert_eq(err, 0)
                    ! TODO: combine it
                    call mpi_bcast(swe%output%i_output_iteration, 1, MPI_INTEGER4, 0, NEW_COMM, err); assert_eq(err, 0)
                end if

                !(3) JOINING ranks initialize
                if (status_MPI .eq. MPI_ADAPT_STATUS_JOINING) then
                    call grid%destroy()
                    call grid%sections%resize(0)
                    call grid%threads%resize(omp_get_max_threads())

                    i_stats_phase      = bcast_packet%i_stats_phase
                    i_initial_step     = bcast_packet%i_initial_step
                    i_time_step        = bcast_packet%i_time_step
                    r_time_next_output = bcast_packet%r_time_next_output
                    grid%r_time        = bcast_packet%r_time
                    grid%r_dt          = bcast_packet%r_dt
                    grid%r_dt_new      = bcast_packet%r_dt_new

!                    swe%output%i_output_iteration = bcast_packet%i_output_iteration
!                    swe%xml_output%i_output_iteration = bcast_packet%i_output_iteration
!                    swe%point_output%i_output_iteration = bcast_packet%i_output_iteration

                    swe%xml_output%i_output_iteration = swe%output%i_output_iteration
                    swe%point_output%i_output_iteration = swe%output%i_output_iteration

                    swe%xml_output%s_file_stamp = swe%output%s_file_stamp
                    swe%point_output%s_file_stamp = swe%output%s_file_stamp
                    s_log_name = trim(swe%output%s_file_stamp) // ".log"
                    if (cfg%l_log) then
                        _log_open_file(s_log_name)
                    end if

                    !reverse grid if it is the case (for JOINING procs only)
                    if (.not. bcast_packet%is_forward) then
                        call grid%reverse()  !this will set the grid%sections%forward flag properly
                    end if
                end if

                !(4) LEAVING ranks clean up: deallocate, close files, etc.
                if (status_MPI .eq. MPI_ADAPT_STATUS_LEAVING) then
                    call grid%destroy()
                    call swe%destroy(grid, cfg%l_log)
                end if
                !************************ ADAPT WINDOW ****************************

                tic = mpi_wtime();
                call mpi_comm_adapt_commit(err); assert_eq(err, 0)
                toc = mpi_wtime() - tic;

                _log_write(1, '("Rank ", I0, " (", I0, "): adapt_commit ", E10.2, " sec")') &
                        rank_MPI, status_MPI, toc

                _log_write(1, '("Rank ", I0, " (", I0, "): s_file_stamp = ", A)') &
                        rank_MPI, status_MPI, trim(swe%output%s_file_stamp)

                ! Update status, size, rank after commit
                status_MPI = MPI_ADAPT_STATUS_STAYING;
                call mpi_comm_size(MPI_COMM_WORLD, size_MPI, err); assert_eq(err, 0)
                call mpi_comm_rank(MPI_COMM_WORLD, rank_MPI, err); assert_eq(err, 0)

                toc1 = mpi_wtime() - tic1;
                _log_write(1, '("Rank ", I0, " (", I0, "): Total adaption time = ", E10.2, " sec")') &
                        rank_MPI, status_MPI, toc1
            end if
#           endif
        end subroutine impi_adapt

        subroutine create_impi_bcast_type(impi_bcast_type)
            integer, intent(out) :: impi_bcast_type

            !Construct an MPI type for the following object
            !************************
            !type t_impi_bcast
            !    integer (kind=GRID_SI) :: i_stats_phase    ! MPI_INTEGER4 x4
            !    integer (kind=GRID_SI) :: i_initial_step
            !    integer (kind=GRID_SI) :: i_time_step
            !    integer (kind=GRID_SI) :: i_output_iteration
            !    real (kind=GRID_SR)    :: r_time_next_output  ! MPI_DOUBLE_PRECISION x4
            !    real (kind=GRID_SR)    :: r_time
            !    real (kind=GRID_SR)    :: r_dt
            !    real (kind=GRID_SR)    :: r_dt_new
            !    logical                :: is_forward    ! MPI_LOGICAL x1
            !end type t_impi_bcast
            !************************

#           if defined(_IMPI)
            integer :: lens(3), types(3), disps(3), err
            integer (kind = GRID_SI)    :: i_sample
            real (kind = GRID_SR)       :: r_sample

            lens(1) = 3
            lens(2) = 4
            lens(3) = 1

            disps(1) = 0
            disps(2) = disps(1) + lens(1) * sizeof(i_sample)
            disps(3) = disps(2) + lens(2) * sizeof(r_sample)

            types(1) = MPI_INTEGER4
            types(2) = MPI_DOUBLE_PRECISION
            types(3) = MPI_LOGICAL

            call MPI_Type_struct(3, lens, disps, types, impi_bcast_type, err); assert_eq(err, 0)
            call MPI_Type_commit(impi_bcast_type, err); assert_eq(err, 0)
#           endif
        end subroutine

	END MODULE SWE
#endif
