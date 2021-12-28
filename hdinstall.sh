#!/bin/sh

: ${source:="https://s3.amazonaws.com/s3.heimdalldata.com"}
: ${zipfile:="heimdall.zip"}
: ${imagebuild:="false"}  # if set to true, enables certain cleanup operations
: ${debugutils:="false"}  # if tools like the mysqlcli should be installed by default
: ${efs:="false"} # if aws efs is to be used as a centralized configuration store (only installs efs utils)

command_exists() {
	command -v "$@" > /dev/null 2>&1
}

os=$(uname)

case $os in
	Linux)
		if command_exists lsb_release; then
			lsbrel="lsb_release"
			NAME=$($lsbrel -si | tr '[:upper:]' '[:lower:]')
		fi
		if [ -f /etc/os-release ]; then
			. /etc/os-release
                        NAME="$ID"
		fi
		if [ -z "$NAME" ]; then
			if [ -f /etc/debian_version ]; then
				NAME='debian'
			fi
			if [ -f /etc/centos-release ]; then
				NAME='centos'
			fi
			if [ -f /etc/fedora-release ]; then
				NAME='fedora'
			fi
			if [ -f /etc/redhat-release ]; then
				NAME='redhat'
			fi
			if [ -f /etc/oracle-release ]; then
				NAME='oracleserver'
			fi
			if [ -f /etc/alpine-release ]; then
				NAME='alpine'
			fi
		fi
	;;
	*)      echo "This installer is not able to install on this OS (Only Linux for now)"
		exit 1
	;;
esac

if [ -z "$NAME" ]; then
	echo "Script unable to detect base OS type, please make sure lsb_release is available, aborting"
	exit 1
fi

echo "Detected Linux distribution: $NAME"

case $NAME in
	ubuntu|debian) # Ubuntu is prefered and tested the most
		export DEBIAN_FRONTEND=noninteractive
		apt-get -yq -o DPkg::options::="--force-confdef" -o DPkg::options::="--force-confold" update

		# ensure we update as part of image building
		if [ "$imagebuild" = "true" ]; then
			apt-get -yq -o DPkg::options::="--force-confdef" -o DPkg::options::="--force-confold" upgrade
		fi

		# get key stuff to ensure time is synced and random data is available
		apt-get -yq install --no-install-recommends curl unzip ntp haveged

		if [ "$debugutils" = "true" ]; then
			apt-get -yq install --no-install-recommends mysql-client postgresql-client telnet vim tcpdump psmisc traceroute jq
		fi
		if [ "$efs" = "true" ]; then
			apt-get -yq install --no-install-recommends amazon-efs-utils
		fi

		# only install if not available, a customer may have installed oracle java instead or some other variation
		if ! command_exists java; then
			apt-get -yq install --no-install-recommends openjdk-11-jdk-headless
		fi
	;;
	fedora|centos|rhel*|redhat*|oracle*|amzn*|cloudlinux|alinux)
			echo "Installing yum dependencies"
                # install updates if an image build, don't touch if not
		if [ "$imagebuild" = "true" ]; then
			yum -y update
		fi
		
		if [ "$NAME" = "amzn" ]; then
			echo "Installing Amazon specific dependencies"
			if ! command_exists java; then
				# amazon has their own distro of java, use this
				# Version 282 is specified as the next version has a critical TLS issue, so we needed to use an older version.  Adjust when appropriate.
				#amazon-linux-extras enable corretto8 && yum -y install java-1.8.0-amazon-corretto-devel-1.8.0_282.b08-1.amzn2.x86_64 2> /dev/null
				yum -y install java-11-amazon-corretto-headless 2> /dev/null
			fi
			
			cd /etc/pki/ca-trust/source/anchors/
			wget https://s3.amazonaws.com/rds-downloads/rds-combined-ca-bundle.pem
			update-ca-trust
			# add a 1GB swap file to ensure that we don't overflow memory and crash
			dd if=/dev/zero of=/swapfile bs=1024000 count=1024 && chmod 600 /swapfile && mkswap /swapfile
			echo "/swapfile swap swap defaults 0 0" >> /etc/fstab
			
			# this is to allow /opt/heimdall/config to be mounted as a shared location, for configuration persistence
			if [ "$efs" = "true" ]; then
				yum -y install amazon-efs-utils
			fi
			yum -y remove postfix # installed by default, remove for hardening
		fi

		yum -y install curl unzip ntp haveged

		if [ "$debugutils" = "true" ]; then
			yum -y install mysql postgresql telnet vim tcpdump psmisc traceroute net-tools jq
		fi

		if ! command_exists java; then
			yum -y install java-11-openjdk-headless 2> /dev/null
		fi
		yum clean packages
	;;
	sles)
		zypper in -y curl unzip ntp haveged

		if [ "$debugutils" = "true" ]; then
			zypper in -y mysql-client postgresql-client telnet vim tcpdump psmisc traceroute jq
		fi

		if ! command_exists java; then
			zypper in -y java-11-openjdk-headless
		fi
	;;
	alpine)
		apk add curl unzip openntpd haveged

		if [ "$debugutils" = "true" ]; then
			apk add mysql-client postgresql-client vim tcpdump psmisc busybox-extras jq
		fi

		if ! command_exists java; then
			apk add openjdk11
		fi
		cp /opt/heimdall/setup/heimdall.start /etc/local.d/
		rc-update add local default
	;;
			
	*) echo "Unknown OS type for dependency install: $NAME"
	   exit 1;;
esac

if ! command_exists java; then
	echo "Java was not installed--please install manually, aborting"
	exit 1
fi

if [ ! -d /opt/heimdall ]; then
	cd /opt
	if [ ! -f heimdall-new.zip ]; then
		echo "Downloading Heimdall install package from ${source}/${zipfile}"
		curl ${source}/${zipfile} -o heimdall-new.zip
	fi

	unzip heimdall-new.zip
	mv heimdall-new.zip heimdall  # for module configuration
	
	chmod a+x heimdall/*.sh
fi

if [ -d /etc/systemd/system ]; then
	echo "Setting Heimdall up as a systemd service--reboot or manually start the service (if not a container setup)"
	cp /opt/heimdall/setup/heimdall.service /etc/systemd/system/ # to enable heimdall as a service
	systemctl enable heimdall
else
	echo "systemd's system directory not detected, not configuring Heimdall as a systemd service"
fi

if [ "$imagebuild" = "true" ]; then
	# we need to cleanup this stuff to ensure it is safe to use as a template image
	shred -u /etc/ssh/*_key /etc/ssh/*_key.pub ~/.ssh/authorized_keys /home/ec2-user/.ssh/authorized_keys /home/ubuntu/.ssh/authorized_keys /root/.ssh/authorized_keys 2> /dev/null
fi

exit 0

