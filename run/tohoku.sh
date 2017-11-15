#!/bin/bash

export NFSPATH=$HOME/workspace

# The name of the executable
execname=$NFSPATH/esamoa/bin/swe_noomp_impi_gnu_release
# iMPI adapt frequency (every N steps)
nimpiadapt='-nimpiadapt 50'
# Grid minimum depth
dmin='-dmin 8'
# Grid maximum depth
dmax='-dmax 23'
# Simulation time in seconds (normally 3 hrs)
tmax='-tmax 10800'
# VTK output frequency (every N seconds)
tout='-tout 120'
# Enable/disable VTK output
xmlout='-xmloutput .false.'
# Number of sections
sections='-sections 1'
# Allow splitting sections during load balancing
split='-lbsplit'
# Number of threads
threads='-threads 1'
# The Courant number (keep it 0.95)
courant='-courant 0.95'
# Data file for displacement
fdispl='-fdispl '$NFSPATH'/samoa-data/tohoku_static/displ.nc'
# Data file for bathymetry
fbath='-fbath '$NFSPATH'/samoa-data/tohoku_static/bath_2014.nc'
# What is stestpoints
stestpoints='-stestpoints "545735.266126 62716.4740303,935356.566012 -817289.628677,1058466.21575 765077.767857"' 
# Ouput directory
output_dir='-output_dir '$PWD
# Put all options together
all=$execname' '$sections' '$split' '$courant' '$threads' '$tout' '$nimpiadapt' '$dmin' '$dmax' '$tmax' '$fdispl' '$fbath' '$xmlout' '$stestpoints' '$output_dir

# Start iMPI application with minimum resources (1 node)
cpus_per_node=2

srun -n $cpus_per_node $all > console.out