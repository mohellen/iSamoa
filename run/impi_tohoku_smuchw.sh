#!/bin/bash
#@ wall_clock_limit = 24:00:00
#@ job_name = swe26_irmrand_hw20n28t
#@ job_type = MPICH
#@ class = test
#@ output = $(jobid).log
#@ error = $(jobid).err
#@ node = 20
##Sandy Bridge nodes: 16 cores per node
##Haswell      nodes: 28 cores per node
#@ tasks_per_node = 28
#@ node_usage = not_shared
#@ energy_policy_tag = impi_tests
#@ minimize_time_to_solution = yes
#@ island_count = 1
#@ notification = always
#@ notify_user = hellenbr@in.tum.de
#@ queue

source /etc/profile
source /etc/profile.d/modules.sh
### BUG: bashrc NOT loaded!!
source ~/.bashrc

#########################
# BUG: bashrc not loaded
# FIX: need to load modules and paths here!!!
#########################
### Remove defaults
module unload mpi.ibm
module unload mkl
### Needed by applications
module load scons
module load python/2.7.6
### Needed by ASAGI (intel libraries)
module load cmake
module load netcdf
module load intel
### Use GCC
module unload gcc
module load gcc/5
### Set iMPI path
export NFSPATH=$HOME/workspace
#export BASEPATH=$NFSPATH/sbihpcmaster
#export BASEPATH=$NFSPATH/sbihpccurrentnocfg
#export BASEPATH=$NFSPATH/sbihpc2016stable
#export BASEPATH=$NFSPATH/sbihpcno
#export BASEPATH=$NFSPATH/hwihpcmaster
#export BASEPATH=$NFSPATH/hwihpccurrentnocfg
export BASEPATH=$NFSPATH/hwihpc2016stable
#export BASEPATH=$NFSPATH/hwihpcno
export IMPIPATH=$BASEPATH/install
### Load the iMPI paths
export PATH=$IMPIPATH/sbin:$PATH
export PATH=$IMPIPATH/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
export LD_LIBRARY_PATH=$IMPIPATH/lib:$LD_LIBRARY_PATH
export CPATH=$IMPIPATH/include:$CPATH
export CPPPATH=$IMPIPATH/include:$CPPPATH
export SLURM_MPI_TYPE=pmi2
### iMPI source paths
export IRMDIR=$BASEPATH/source/irm
export IMPIDIR=$BASEPATH/source/impi
### Application paths
export EBAYESDIR=$NFSPATH/ebayes
export ESAMOADIR=$NFSPATH/esamoa
export SAMOADATADIR=$NFSPATH/samoa-data


#########################
# SET THIS CORRECTLY
#########################
BATCH_USER=di29zaf2
# Must be consistent with "node" and "tasks_per_node"
NUM_NODES=20
CORES_PER_NODE=28
# Make sure these paths are correct
DATAPATH=$SAMOADATADIR
execname=$IMPIPATH/swe/swe_impi_release

#########################
# Runtime Options
#########################
all=$execname
# iMPI adapt frequency (every N steps)
all=$all' -nimpiadapt 100'
# iMPI host file (effective only if impi nodes output is enabled)
all=$all' -fimpihosts '$PWD/trimmed_unique_hosts
# Grid maximum depth (14)
all=$all' -dmin 8'
# Grid maximum depth (14)
all=$all' -dmax 26'
# Simulation time in sec (default 10800 for 3 hrs, 14400 for 4 hrs, 18000 for 5 hrs)
all=$all' -tmax 10800'
# VTK output frequency in sec (every N seconds)
all=$all' -tout 120'
# Enable/disable VTK output
all=$all' -xmloutput .true.'
# Number of sections per thread/rank
all=$all' -sections 1'
# Allow splitting sections during load balancing (if not, load won't distribute)
all=$all' -lbsplit'
# Number of threads per rank
all=$all' -threads 1'
# The Courant number (keep it 0.95 for SWE)
all=$all' -courant 0.95'
# Data file for displacement
all=$all' -fdispl '$DATAPATH'/tohoku_static/displ.nc'
# Data file for bathymetry
all=$all' -fbath '$DATAPATH'/tohoku_static/bath_2014.nc'
# Points for the point output (must enable point output, otherwise iMPI won't work)
all=$all' -stestpoints "545735.266126 62716.4740303,935356.566012 -817289.628677,1058466.21575 765077.767857"'
# Ouput directory
mkdir -p $PWD/output
all=$all' -output_dir '$PWD/output

#########################
# iMPI Processing for HW
#########################
# Rank range
MIN_RANKS=$CORES_PER_NODE
MAX_RANKS=$(($NUM_NODES * $CORES_PER_NODE))
# Extract the jobid
JOBID=$(echo $LOADL_STEP_ID| cut -d'.' -f 2)

# processing load-leveler host-file
cat $LOADL_HOSTFILE > host_file
echo "processing the Load Leveler provided hostfile "
echo "getting unique entries..."
awk '!a[$0]++' host_file > unique_hosts
cat unique_hosts > $LOADL_HOSTFILE
echo "new ll file:"
cat $LOADL_HOSTFILE 
echo "trimming the -ib part endings..."
rm -rf trimmed_unique_hosts
while read h; do
	echo $h | rev | cut -c 3- | rev >> trimmed_unique_hosts
done <unique_hosts

# generating slurm.conf dynamically
echo "copying initial slurm.conf work file"
cp -a $IMPIPATH/etc/slurm.conf.in slurm.conf.initial
cp -a $IMPIPATH/etc/slurm.conf.in slurm.conf.work
echo "setting up NodeName and PartitionName entries in slurm.conf ..."
while read h; do
	echo "NodeName=$h CPUs=${CORES_PER_NODE} State=UNKNOWN" >> slurm.conf.work
done <trimmed_unique_hosts
Nodes=`sed "N;s/\n/,/" trimmed_unique_hosts`
Nodes=`cat trimmed_unique_hosts | paste -sd "," -`
echo "PartitionName=local Nodes=${Nodes} Default=YES MaxTime=INFINITE State=UP" >> slurm.conf.work
FirstNode=`head -n 1 trimmed_unique_hosts`
echo "ControlMachine=${FirstNode}" >> slurm.conf.work
cp -a slurm.conf.work $IMPIPATH/etc/slurm.conf

# starting the resource manager (slurm)
echo "starting daemons on each given node..."
n=`wc -l <unique_hosts`
autonomous_master.ksh -n $n -c "$IMPIPATH/sbin/munged -Ff > munge_remote_daemon_out 2>&1" &
autonomous_master.ksh -n $n -c "$IMPIPATH/sbin/slurmd -Dc > slurm_remote_daemon_out 2>&1" &
echo "starting the controller..."
irtsched -Dcvvvv > slurm_controller_out 2>&1 &
sleep 5

echo "exporting recommended variable..."
export SLURM_PMI_KVS_NO_DUP_KEYS
export MXM_LOG_LEVEL=error
export SLURM_MPI_TYPE=pmi2

echo "--------------------------------------------------------------------------------"
echo " Starnig the application with srun:"
date

srun -n $MIN_RANKS $all > swe.out

date
echo "--------------------------------------------------------------------------------"
