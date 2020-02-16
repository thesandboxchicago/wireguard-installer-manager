# Get the latest ubuntu release
FROM ubuntu:latest

# The name of the maintainer
LABEL maintainer="Prajwal Koirala <www.prajwalkoirala.com>"

# The commands to run for wireguard
RUN apt-get update &&\
    apt-get install wget -y &&\
    wget https://raw.githubusercontent.com/complexorganizations/wireguard-installer-manager/master/wireguard-server.sh -P /etc/wireguard/ &&\
    HEADLESS_INSTALL=y /etc/wireguard/wireguard-server.sh

# The port to export to the outside world for docker
EXPOSE 51820

ENTRYPOINT []

CMD []
