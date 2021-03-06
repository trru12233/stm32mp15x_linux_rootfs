#!/usr/bin/env bash
#shellcheck disable=SC2001

# netdata
# real-time performance and health monitoring, done right!
# (C) 2016 Costa Tsaousis <costa@tsaousis.gr>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Script to find a better name for cgroups
#

export PATH="${PATH}:/sbin:/usr/sbin:/usr/local/sbin"
export LC_ALL=C

# -----------------------------------------------------------------------------

PROGRAM_NAME="$(basename "${0}")"

logdate() {
	date "+%Y-%m-%d %H:%M:%S"
}

log() {
	local status="${1}"
	shift

	echo >&2 "$(logdate): ${PROGRAM_NAME}: ${status}: ${*}"

}

warning() {
	log WARNING "${@}"
}

error() {
	log ERROR "${@}"
}

info() {
	log INFO "${@}"
}

fatal() {
	log FATAL "${@}"
	exit 1
}

function docker_get_name_classic() {
	local id="${1}"
	info "Running command: docker ps --filter=id=\"${id}\" --format=\"{{.Names}}\""
	NAME="$(docker ps --filter=id="${id}" --format="{{.Names}}")"
	return 0
}

function docker_get_name_api() {
	local path="/containers/${1}/json"
	if [ -z "${DOCKER_HOST}" ]; then
		warning "No DOCKER_HOST is set"
		return 1
	fi
	if ! command -v jq >/dev/null 2>&1; then
		warning "Can't find jq command line tool. jq is required for netdata to retrieve docker container name using ${DOCKER_HOST} API, falling back to docker ps"
		return 1
	fi
	if [ -S "${DOCKER_HOST}" ]; then
		info "Running API command: curl --unix-socket ${DOCKER_HOST} http://localhost${path}"
		JSON=$(curl -sS --unix-socket "${DOCKER_HOST}" "http://localhost${path}")
	elif [ "${DOCKER_HOST}" == "/var/run/docker.sock" ]; then
		warning "Docker socket was not found at ${DOCKER_HOST}"
		return 1
	else
		info "Running API command: curl ${DOCKER_HOST}${path}"
		JSON=$(curl -sS "${DOCKER_HOST}${path}")
	fi
	NAME=$(echo "$JSON" | jq -r .Name,.Config.Hostname | grep -v null | head -n1 | sed 's|^/||')
	return 0
}

function k8s_get_name() {
	# Take the last part of the delimited path identifier (expecting either _ or / as a delimiter).
	local id="${1##*_}"
	if [ "${id}" == "${1}" ]; then
		id="${1##*/}"
	fi
	KUBE_TOKEN="$(</var/run/secrets/kubernetes.io/serviceaccount/token)"
	if command -v jq >/dev/null 2>&1; then
		NAME="$(
		curl -sSk -H "Authorization: Bearer $KUBE_TOKEN"  "https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_PORT_443_TCP_PORT/api/v1/pods" |
		jq -r '.items[] | "k8s_\(.metadata.namespace)_\(.metadata.name)_\(.metadata.uid)_\(.status.containerStatuses[0].name) \(.status.containerStatuses[0].containerID)"' |
		grep "$id" |
		cut -d' ' -f1
		)"
	else
		warning "jq command not available, k8s_get_name() cannot execute. Please install jq should you wish for k8s to be fully functional"
	fi

	if [ -z "${NAME}" ]; then
		warning "cannot find the name of k8s pod with containerID '${id}'. Setting name to ${id} and disabling it"
		NAME="${id}"
		NAME_NOT_FOUND=3
	else
		info "k8s containerID '${id}' has chart name (namespace_podname_poduid_containername) '${NAME}'"
	fi
}

function docker_get_name() {
	local id="${1}"
	if hash docker 2>/dev/null; then
		docker_get_name_classic "${id}"
	else
		docker_get_name_api "${id}" || docker_get_name_classic "${id}"
	fi
	if [ -z "${NAME}" ]; then
		warning "cannot find the name of docker container '${id}'"
		NAME_NOT_FOUND=2
		NAME="${id:0:12}"
	else
		info "docker container '${id}' is named '${NAME}'"
	fi
}

function docker_validate_id() {
	local id="${1}"
	if [ -n "${id}" ] && { [ ${#id} -eq 64 ] || [ ${#id} -eq 12 ]; }; then
		docker_get_name "${id}"
	else
		error "a docker id cannot be extracted from docker cgroup '${CGROUP}'."
	fi
}


# -----------------------------------------------------------------------------

[ -z "${NETDATA_USER_CONFIG_DIR}" ] && NETDATA_USER_CONFIG_DIR="/etc/netdata"
[ -z "${NETDATA_STOCK_CONFIG_DIR}" ] && NETDATA_STOCK_CONFIG_DIR="/usr/lib/netdata/conf.d"

DOCKER_HOST="${DOCKER_HOST:=/var/run/docker.sock}"
CGROUP="${1}"
NAME_NOT_FOUND=0
NAME=

# -----------------------------------------------------------------------------

if [ -z "${CGROUP}" ]; then
	fatal "called without a cgroup name. Nothing to do."
fi

for CONFIG in "${NETDATA_USER_CONFIG_DIR}/cgroups-names.conf" "${NETDATA_STOCK_CONFIG_DIR}/cgroups-names.conf"; do
	if [ -f "${CONFIG}" ]; then
		NAME="$(grep "^${CGROUP} " "${CONFIG}" | sed 's/[[:space:]]\+/ /g' | cut -d ' ' -f 2)"
		if [ -z "${NAME}" ]; then
			info "cannot find cgroup '${CGROUP}' in '${CONFIG}'."
		else
			break
		fi
	#else
	#   info "configuration file '${CONFIG}' is not available."
	fi
done

if [ -z "${NAME}" ] && [ -n "${KUBERNETES_SERVICE_HOST}" ] && [ -n "${KUBERNETES_PORT_443_TCP_PORT}" ] && [[ ${CGROUP} =~ ^.*kubepods.* ]]; then
	k8s_get_name "${CGROUP}"
fi

if [ -z "${NAME}" ]; then
	if [[ ${CGROUP} =~ ^.*docker[-_/\.][a-fA-F0-9]+[-_\.]?.*$ ]]; then
		# docker containers
		#shellcheck disable=SC1117
		DOCKERID="$(echo "${CGROUP}" | sed "s|^.*docker[-_/]\([a-fA-F0-9]\+\)[-_\.]\?.*$|\1|")"
		docker_validate_id "${DOCKERID}"
	elif [[ ${CGROUP} =~ ^.*ecs[-_/\.][a-fA-F0-9]+[-_\.]?.*$ ]]; then
		# ECS
		#shellcheck disable=SC1117
		DOCKERID="$(echo "${CGROUP}" | sed "s|^.*ecs[-_/].*[-_/]\([a-fA-F0-9]\+\)[-_\.]\?.*$|\1|")"
		docker_validate_id "${DOCKERID}"

	elif [[ ${CGROUP} =~ machine.slice[_/].*\.service ]]; then
		# systemd-nspawn
		NAME="$(echo "${CGROUP}" | sed 's/.*machine.slice[_\/]\(.*\)\.service/\1/g')"

	elif [[ ${CGROUP} =~ machine.slice_machine.*-qemu ]]; then
		# libvirtd / qemu virtual machines
		# NAME="$(echo ${CGROUP} | sed 's/machine.slice_machine.*-qemu//; s/\/x2d//; s/\/x2d/\-/g; s/\.scope//g')"
		NAME="qemu_$(echo "${CGROUP}" | sed 's/machine.slice_machine.*-qemu//; s/\/x2d[[:digit:]]*//; s/\/x2d//g; s/\.scope//g')"

	elif [[ ${CGROUP} =~ machine_.*\.libvirt-qemu ]]; then
		# libvirtd / qemu virtual machines
		NAME="qemu_$(echo "${CGROUP}" | sed 's/^machine_//; s/\.libvirt-qemu$//; s/-/_/;')"

	elif [[ ${CGROUP} =~ qemu.slice_([0-9]+).scope && -d /etc/pve ]]; then
		# Proxmox VMs

		FILENAME="/etc/pve/qemu-server/${BASH_REMATCH[1]}.conf"
		if [[ -f $FILENAME && -r $FILENAME ]]; then
			NAME="qemu_$(grep -e '^name: ' "/etc/pve/qemu-server/${BASH_REMATCH[1]}.conf" | head -1 | sed -rn 's|\s*name\s*:\s*(.*)?$|\1|p')"
		else
			error "proxmox config file missing ${FILENAME} or netdata does not have read access.  Please ensure netdata is a member of www-data group."
		fi
	elif [[ ${CGROUP} =~ lxc_([0-9]+) && -d /etc/pve ]]; then
		# Proxmox Containers (LXC)

		FILENAME="/etc/pve/lxc/${BASH_REMATCH[1]}.conf"
		if [[ -f ${FILENAME} && -r ${FILENAME} ]]; then
			NAME=$(grep -e '^hostname: ' "/etc/pve/lxc/${BASH_REMATCH[1]}.conf" | head -1 | sed -rn 's|\s*hostname\s*:\s*(.*)?$|\1|p')
		else
			error "proxmox config file missing ${FILENAME} or netdata does not have read access.  Please ensure netdata is a member of www-data group."
		fi
	fi

	[ -z "${NAME}" ] && NAME="${CGROUP}"
	[ ${#NAME} -gt 100 ] && NAME="${NAME:0:100}"
fi

info "cgroup '${CGROUP}' is called '${NAME}'"
echo "${NAME}"

exit ${NAME_NOT_FOUND}

