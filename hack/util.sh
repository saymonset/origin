#!/bin/bash

# Provides simple utility functions

# ensure_iptables_or_die tests if the testing machine has iptables available
# and in PATH. Also test whether current user has sudo privileges.
function ensure_iptables_or_die() {
	if [[ -z "$(which iptables)" ]]; then
		echo "IPTables not found - the end-to-end test requires a system with iptables for Kubernetes services."
		exit 1
	fi

	set +e

	iptables --list > /dev/null 2>&1
	if [ $? -ne 0 ]; then
		sudo iptables --list > /dev/null 2>&1
		if [ $? -ne 0 ]; then
			echo "You do not have iptables or sudo privileges. Kubernetes services will not work without iptables access.	See https://github.com/kubernetes/kubernetes/issues/1859.	Try 'sudo hack/test-end-to-end.sh'."
			exit 1
		fi
	fi

	set -e
}
readonly -f ensure_iptables_or_die

# kill_all_processes function will kill all
# all processes created by the test script.
function kill_all_processes() {
	local sudo="${USE_SUDO:+sudo}"

	pids=($(jobs -pr))
	for i in ${pids[@]-}; do
		pgrep -P "${i}" | xargs $sudo kill &> /dev/null
		$sudo kill ${i} &> /dev/null
	done
}
readonly -f kill_all_processes

# time_now return the time since the epoch in millis
function time_now() {
	echo $(date +%s000)
}
readonly -f time_now

# dump_container_logs writes container logs to $LOG_DIR
function dump_container_logs() {
	if ! docker version >/dev/null 2>&1; then
		return
	fi

	mkdir -p ${LOG_DIR}

	echo "[INFO] Dumping container logs to ${LOG_DIR}"
	for container in $(docker ps -aq); do
		container_name=$(docker inspect -f "{{.Name}}" $container)
		# strip off leading /
		container_name=${container_name:1}
		if [[ "$container_name" =~ ^k8s_ ]]; then
			pod_name=$(echo $container_name | awk 'BEGIN { FS="[_.]+" }; { print $4 }')
			container_name=${pod_name}-$(echo $container_name | awk 'BEGIN { FS="[_.]+" }; { print $2 }')
		fi
		docker logs "$container" >&"${LOG_DIR}/container-${container_name}.log"
	done
}
readonly -f dump_container_logs

# delete_empty_logs deletes empty logs
function delete_empty_logs() {
	# Clean up zero byte log files
	find "${ARTIFACT_DIR}" "${LOG_DIR}" -type f -name '*.log' \( -empty \) -delete
}
readonly -f delete_empty_logs

# truncate_large_logs truncates large logs so we only download the last 50MB
function truncate_large_logs() {
	# Clean up large log files so they don't end up on jenkins
	local large_files=$(find "${ARTIFACT_DIR}" "${LOG_DIR}" -type f -name '*.log' \( -size +50M \))
	for file in ${large_files}; do
		mv "${file}" "${file}.tmp"
		echo "LOGFILE TOO LONG ($(du -h "${file}.tmp")), PREVIOUS BYTES TRUNCATED. LAST 50M OF LOGFILE:" > "${file}"
		tail -c 50M "${file}.tmp" >> "${file}"
		rm "${file}.tmp"
	done
}
readonly -f truncate_large_logs

######
# start of common functions for extended test group's run.sh scripts
######

# exit run if ginkgo not installed
function ensure_ginkgo_or_die() {
	which ginkgo &>/dev/null || (echo 'Run: "go get github.com/onsi/ginkgo/ginkgo"' && exit 1)
}
readonly -f ensure_ginkgo_or_die

# cleanup_openshift saves container logs, saves resources, and kills all processes and containers
function cleanup_openshift() {
	LOG_DIR="${LOG_DIR:-${BASETMPDIR}/logs}"
	ARTIFACT_DIR="${ARTIFACT_DIR:-${LOG_DIR}}"
	API_HOST="${API_HOST:-127.0.0.1}"
	API_SCHEME="${API_SCHEME:-https}"
	ETCD_PORT="${ETCD_PORT:-4001}"

	set +e
	dump_container_logs

	# pull information out of the server log so that we can get failure management in jenkins to highlight it and
	# really have it smack people in their logs.  This is a severe correctness problem
	grep -a5 "CACHE.*ALTERED" ${LOG_DIR}/openshift.log

	os::cleanup::dump_etcd

	if [[ -z "${SKIP_TEARDOWN-}" ]]; then
		echo "[INFO] Tearing down test"
		kill_all_processes

		if docker version >/dev/null 2>&1; then
			echo "[INFO] Stopping k8s docker containers"; docker ps | awk 'index($NF,"k8s_")==1 { print $1 }' | xargs -l -r docker stop -t 1 >/dev/null
			if [[ -z "${SKIP_IMAGE_CLEANUP-}" ]]; then
				echo "[INFO] Removing k8s docker containers"; docker ps -a | awk 'index($NF,"k8s_")==1 { print $1 }' | xargs -l -r docker rm -v >/dev/null
			fi
		fi

		echo "[INFO] Pruning etcd data directory..."
		local sudo="${USE_SUDO:+sudo}"
		${sudo} rm -rf "${ETCD_DATA_DIR}"

		set -u
	fi

	if grep -q 'no Docker socket found' "${LOG_DIR}/openshift.log" && command -v journalctl >/dev/null 2>&1; then
		# the Docker daemon crashed, we need the logs
		journalctl --unit docker.service --since -4hours > "${LOG_DIR}/docker.log"
	fi

	delete_empty_logs
	truncate_large_logs

	echo "[INFO] Cleanup complete"
	set -e
}
readonly -f cleanup_openshift

# install the router for the extended tests
function install_router() {
	echo "[INFO] Installing the router"
	oadm policy add-scc-to-user privileged -z router --config="${ADMIN_KUBECONFIG}"
	# Create a TLS certificate for the router
	if [[ -n "${CREATE_ROUTER_CERT:-}" ]]; then
		echo "[INFO] Generating router TLS certificate"
		oadm ca create-server-cert --signer-cert=${MASTER_CONFIG_DIR}/ca.crt \
			--signer-key=${MASTER_CONFIG_DIR}/ca.key \
			--signer-serial=${MASTER_CONFIG_DIR}/ca.serial.txt \
			--hostnames="*.${API_HOST}.xip.io" \
			--cert=${MASTER_CONFIG_DIR}/router.crt --key=${MASTER_CONFIG_DIR}/router.key
		cat ${MASTER_CONFIG_DIR}/router.crt ${MASTER_CONFIG_DIR}/router.key \
			${MASTER_CONFIG_DIR}/ca.crt > ${MASTER_CONFIG_DIR}/router.pem
		ROUTER_DEFAULT_CERT="--default-cert=${MASTER_CONFIG_DIR}/router.pem"
	fi
	openshift admin router --config="${ADMIN_KUBECONFIG}" --images="${USE_IMAGES}" --service-account=router ${ROUTER_DEFAULT_CERT-}

	# Set the SYN eater to make router reloads more robust
	if [[ -n "${DROP_SYN_DURING_RESTART:-}" ]]; then
		# Rewrite the DC for the router to add the environment variable into the pod definition
		echo "[INFO] Changing the router DC to drop SYN packets during a reload"
		oc set env dc/router -c router DROP_SYN_DURING_RESTART=true
	fi
}
readonly -f install_router

# install registry for the extended tests
function install_registry() {
	# The --mount-host option is provided to reuse local storage.
	echo "[INFO] Installing the registry"
	# For testing purposes, ensure the quota objects are always up to date in the registry by
	# disabling project cache.
	openshift admin registry --config="${ADMIN_KUBECONFIG}" --images="${USE_IMAGES}" --enforce-quota -o json | \
		oc env -f - --output json "REGISTRY_MIDDLEWARE_REPOSITORY_OPENSHIFT_PROJECTCACHETTL=0" | \
		oc create -f -
}
readonly -f install_registry

######
# end of common functions for extended test group's run.sh scripts
######

function find_files() {
	find . -not \( \
		\( \
		-wholename './_output' \
		-o -wholename './.*' \
		-o -wholename './pkg/assets/bindata.go' \
		-o -wholename './pkg/assets/*/bindata.go' \
		-o -wholename './pkg/bootstrap/bindata.go' \
		-o -wholename './openshift.local.*' \
		-o -wholename '*/vendor/*' \
		-o -wholename './assets/bower_components/*' \
		\) -prune \
	\) -name '*.go' | sort -u
}
readonly -f find_files

# Asks golang what it thinks the host platform is.  The go tool chain does some
# slightly different things when the target platform matches the host platform.
function os::util::host_platform() {
	echo "$(go env GOHOSTOS)/$(go env GOHOSTARCH)"
}
readonly -f os::util::host_platform
