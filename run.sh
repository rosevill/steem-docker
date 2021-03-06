#!/bin/bash
#
# Steem node manager
# Released under GNU AGPL by Someguy123
#

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
DOCKER_DIR="$DIR/dkr"
FULL_DOCKER_DIR="$DIR/dkr_fullnode"
DATADIR="$DIR/data"
#DOCKER_NAME="seed"

BOLD="$(tput bold)"
RED="$(tput setaf 1)"
GREEN="$(tput setaf 2)"
YELLOW="$(tput setaf 3)"
BLUE="$(tput setaf 4)"
MAGENTA="$(tput setaf 5)"
CYAN="$(tput setaf 6)"
WHITE="$(tput setaf 7)"
RESET="$(tput sgr0)"

# Defines the S3 location for the folder of shared memory file
BLOCKCHAIN_BUCKET=
# Defines the S3 locationfor the folder of config.ini and env files
CONFIG_BUCKET=

# default override in .env
PORTS="2001"

if [[ -f .env ]]; then
    source .env
fi

# DOCKER_NAME can be either seed or witness
if [ "$DOCKER_NAME" = "" ]; then
    echo "Environment variable DOCKER_NAME has not defined."
    exit 1
fi

#if [[ ! -f data/witness_node_data_dir/config.ini ]]; then
#    echo "config.ini not found. copying example (seed)";
#    cp data/witness_node_data_dir/config.ini.example data/witness_node_data_dir/config.ini
#fi

IFS=","
DPORTS=""
for i in $PORTS; do
    if [[ $i != "" ]]; then
         if [[ $DPORTS == "" ]]; then
            DPORTS="-p0.0.0.0:$i:$i"
        else
            DPORTS="$DPORTS -p0.0.0.0:$i:$i"
        fi
    fi
done

help() {
    echo "Usage: $0 COMMAND [DATA]"
    echo
    echo "Commands: "
    echo "    start - starts steem container"
    echo "    dlblocks - download and decompress the blockchain to speed up your first start"
    echo "    replay - starts steem container (in replay mode)"
    echo "    shm_size - resizes /dev/shm to size given, e.g. ./run.sh shm_size 10G "
    echo "    stop - stops steem container"
    echo "    status - show status of steem container"
    echo "    restart - restarts steem container"
    echo "    install_docker - install docker"
    echo "    install - pulls latest docker image from server (no compiling)"
    echo "    install_full - pulls latest (FULL NODE FOR RPC) docker image from server (no compiling)"
    echo "    rebuild - builds steem container (from docker file), and then restarts it"
    echo "    build - only builds steem container (from docker file)"
    echo "    logs - show all logs inc. docker logs, and steem logs"
    echo "    wallet - open cli_wallet in the container"
    echo "    remote_wallet - open cli_wallet in the container connecting to a remote seed"
    echo "    enter - enter a bash session in the container"
    echo
    exit
}

optimize() {
    echo    75 | sudo tee /proc/sys/vm/dirty_background_ratio
    echo  1000 | sudo tee /proc/sys/vm/dirty_expire_centisecs
    echo    80 | sudo tee /proc/sys/vm/dirty_ratio
    echo 30000 | sudo tee /proc/sys/vm/dirty_writeback_centisecs
}

build() {
    echo "You may want to use '$0 install' for a binary image instead, it's faster."
    echo $GREEN"Building docker container"$RESET
    cd $DOCKER_DIR
    docker build -t steem .
}

build_full() {
    echo "You may want to use '$0 install_full' for a binary image instead, it's faster."
    echo $GREEN"Building full-node docker container"$RESET
    cd $FULL_DOCKER_DIR
    docker build -t steem .
}

config() {
    if [ ! -e $DIR/config/$DOCKER_NAME.env ]; then
        dlconfig
    fi
    if [ ! -e $DIR/config/$DOCKER_NAME.env ]; then
        echo "Failed to config node"
    fi 
    cp $DIR/config/config.$DOCKER_NAME $DATADIR/witness_node_data_dir/config.ini
    #cp $DIR/config/$DOCKER_NAME.env $DIR/.env
    echo "Node has been configured as [$DOCKER_NAME]"
}

dlconfig() {
    aws s3 sync $CONFIG_BUCKET $DIR/config
}

bootstrap() {
    # Bootstrap a new EC2 instance (Ubuntu 16.04LTS)
    sudo apt-get install awscli
    optimize
    install_docker
    install
    dlconfig
    fastsync
    # TODO: copy config (seed or witness) based on parameters
    #start
}

fastsync() {
    # Download shared memory file from S3 bucket
    if [ "$BLOCKCHAIN_BUCKET $DATADIR" = "" ]; then
        echo "Environment varialbe not exported"
    fi
    aws s3 sync $BLOCKCHAIN_BUCKET $DATADIR/witness_node_data_dir/blockchain
}

dlblocks() {
    if [[ ! -d "$DATADIR/blockchain" ]]; then
        mkdir "$DATADIR/blockchain"
    fi
    echo "Removing old block log"
    sudo rm -f $DATADIR/witness_node_data_dir/blockchain/block_log
    sudo rm -f $DATADIR/witness_node_data_dir/blockchain/block_log.index
    echo "Download @gtg's block logs..."
    if [[ ! $(command -v xz) ]]; then
        echo "XZ not found. Attempting to install..."
        sudo apt update
        sudo apt install -y xz-utils
    fi
    wget https://gtg.steem.house/get/blockchain.xz/block_log.xz -O $DATADIR/witness_node_data_dir/blockchain/block_log.xz
    echo "Decompressing block log... this may take a while..."
    xz -d $DATADIR/witness_node_data_dir/blockchain/block_log.xz
    echo "FINISHED. Blockchain downloaded and decompressed"
    echo "Remember to resize your /dev/shm, and run with replay!"
    echo "$ ./run.sh shm_size SIZE (e.g. 8G)"
    echo "$ ./run.sh replay"
}

install_docker() {
    sudo apt update
    sudo apt install curl git
    curl https://get.docker.com | sh
    if [ "$EUID" -ne 0 ]; then 
        echo "Adding user $(whoami) to docker group"
        sudo usermod -aG docker $(whoami)
        echo "IMPORTANT: Please re-login (or close and re-connect SSH) for docker to function correctly"
    fi
}

install() {
    echo "Loading image from roseville/steem"
    docker pull roseville/steem
    echo "Tagging as steem"
    docker tag roseville/steem steem
    echo "Installation completed. You may now configure or run the server"
}

install_full() {
    echo "Loading image from roseville/steem"
    docker pull roseville/steem:latest-full
    echo "Tagging as steem"
    docker tag roseville/steem:latest-full steem
    echo "Installation completed. You may now configure or run the server"
}
seed_exists() {
    seedcount=$(docker ps -a -f name="^/"$DOCKER_NAME"$" | wc -l)
    if [[ $seedcount -eq 2 ]]; then
        return 0
    else
        return -1
    fi
}

seed_running() {
    seedcount=$(docker ps -f 'status=running' -f name=$DOCKER_NAME | wc -l)
    if [[ $seedcount -eq 2 ]]; then
        return 0
    else
        return -1
    fi
}

debug() {
    echo $GREEN"Starting container..."$RESET
    seed_exists
    if [[ $? == 0 ]]; then
        docker start $DOCKER_NAME
    else
        echo $DATADIR
        docker run $DPORTS -v /dev/shm:/shm -v "$DATADIR":/steem --name $DOCKER_NAME -it steem /bin/bash
    fi
}

start() {
    echo $GREEN"Starting container..."$RESET
    seed_exists
    if [[ $? == 0 ]]; then
        docker start $DOCKER_NAME
    else
        docker run $DPORTS -v /dev/shm:/shm -v "$DATADIR":/steem -d --name $DOCKER_NAME -t steem
    fi
}

replay() {
    echo "Removing old container"
    docker rm $DOCKER_NAME
    echo "Running steem with replay..."
    docker run $DPORTS -v /dev/shm:/shm -v "$DATADIR":/steem -d --name $DOCKER_NAME -t steem steemd --replay
    echo "Started."
}

shm_size() {
    echo "Setting SHM to $1"
    mount -o remount,size=$1 /dev/shm
}

stop() {
    echo $RED"Stopping container..."$RESET
    docker exec -it $DOCKER_NAME pkill steemd
    sleep 10
    docker stop $DOCKER_NAME
    docker rm $DOCKER_NAME
}

enter() {
    docker exec -it $DOCKER_NAME bash
}

wallet() {
    docker exec -it $DOCKER_NAME cli_wallet
}

remote_wallet() {
    docker run -v "$DATADIR":/steem --rm -it steem cli_wallet -s wss://steemd.steemit.com
}

logs() {
    echo $BLUE"DOCKER LOGS: "$RESET
    docker logs --tail=30 $DOCKER_NAME
    #echo $RED"INFO AND DEBUG LOGS: "$RESET
    #tail -n 30 $DATADIR/{info.log,debug.log}
}

status() {
    
    seed_exists
    if [[ $? == 0 ]]; then
        echo "Container exists?: "$GREEN"YES"$RESET
    else
        echo "Container exists?: "$RED"NO (!)"$RESET 
        echo "Container doesn't exist, thus it is NOT running. Run $0 build && $0 start"$RESET
        return
    fi

    seed_running
    if [[ $? == 0 ]]; then
        echo "Container running?: "$GREEN"YES"$RESET
    else
        echo "Container running?: "$RED"NO (!)"$RESET
        echo "Container isn't running. Start it with $0 start"$RESET
        return
    fi
}

if [ "$#" -lt 1 ]; then
    help
fi

type -t $1 | grep function > /dev/null 2>&1
if [ "$?" = "0" ]; then
    eval $1
else
    echo "Invalid command: $1"
fi

# case $1 in
#     build)
#         echo "You may want to use '$0 install' for a binary image instead, it's faster."
#         build
#         ;;
#     build_full)
#         echo "You may want to use '$0 install_full' for a binary image instead, it's faster."
#         build_full
#         ;;
#     install_docker)
#         install_docker
#         ;;
#     install)
#         install
#         ;;
#     install_full)
#         install_full
#         ;;
#     debug)
#         debug
#         ;;
#     start)
#         start
#         ;;
#     replay)
#         replay
#         ;;
#     shm_size)
#         shm_size $2
#         ;;
#     stop)
#         stop
#         ;;
#     restart)
#         stop
#         sleep 5
#         start
#         ;;
#     rebuild)
#         stop
#         sleep 5
#         build
#         start
#         ;;
#     optimize)
#         echo "Applying recommended dirty write settings..."
#         optimize
#         ;;
#     status)
#         status
#         ;;
#     wallet)
#         wallet
#         ;;
#     remote_wallet)
#         remote_wallet
#         ;;
#     dlblocks)
#         dlblocks 
#         ;;
#     config)
#         ec2_config
#         ;;
#     bootstrap)
#         ec2_bootstrap
#         ;;
#     fastsync)
#         ec2_fastsync
#         ;;
#     dlconfig)
#         ec2_dlconfig
#         ;;
#     enter)
#         enter
#         ;;
#     logs)
#         logs
#         ;;
#     *)
#         echo "Invalid cmd"
#         help
#         ;;
# esac
