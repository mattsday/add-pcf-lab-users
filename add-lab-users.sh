#!/bin/bash

if [ ! -f "config.sh" ]; then
	echo Configuration file not found
	echo Copy config-example.sh to config.sh, edit it and re-run
	exit 1
fi

if ! command -v om >/dev/null 2>&1; then
	echo Install om tool from here:
	echo https://github.com/pivotal-cf/om/releases
	exit 1
fi

if ! command -v yq >/dev/null 2>&1; then
	echo Install yq tool
	echo e.g. brew install yq
	exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
	echo Install jq tool
	echo e.g. brew install jq
	exit 1
fi

. config.sh

OPSMAN_UAA="${OPSMAN_URI}/uaa"
CF_COMMAND_FLAGS=""

if [ "${SKIP_SSL_VALIDATION}" = true ]; then
	echo Warning, skipping SSL validation
	CF_COMMAND_FLAGS="--skip-ssl-validation"
fi

echo Attempting opsman login
if ! om -k -u "${OPSMAN_ADMIN_USER}" -p "${OPSMAN_ADMIN_PASS}" -t "${OPSMAN_URI}" installations >/dev/null 2>&1; then
	echo Failed to authenticate to ops manager
	exit 1
fi

if [ "${ENABLE_PAS}" = true ]; then
	# Configure PAS:
	if [ -z "${PAS_SYS}" ]; then
		echo "Getting PAS config (this can take up to 60 seconds)"
		echo "You can set PAS_SYS to speed this up (e.g. PAS_SYS=sys.cf.domain)"
		PAS_CONFIG="$(om -k -u "${OPSMAN_ADMIN_USER}" -p "${OPSMAN_ADMIN_PASS}" -t "${OPSMAN_URI}" staged-config -p cf)"
		PAS_SYS="$(echo "${PAS_CONFIG}" | yq -j r - | jq -r '.["product-properties"] | .[".cloud_controller.system_domain"] | .value')"
	fi
	PAS_API="api.${PAS_SYS}"
	PAS_UAA="login.${PAS_SYS}"
	echo PAS UAA Endpoint = "${PAS_UAA}"
	echo CF API Endpoint = "${PAS_API}"
	echo "Getting PAS credentials from Opsman"
	PAS_CF_CREDENTIALS="$(om --format=json -k -u "${OPSMAN_ADMIN_USER}" -p "${OPSMAN_ADMIN_PASS}" -t "${OPSMAN_URI}" credentials -p cf --credential-reference ".uaa.admin_credentials")"
	PAS_UAA_CREDENTIALS="$(om --format=json -k -u "${OPSMAN_ADMIN_USER}" -p "${OPSMAN_ADMIN_PASS}" -t "${OPSMAN_URI}" credentials -p cf --credential-reference ".uaa.admin_client_credentials")"
	PAS_UAA_ADMIN_NAME=$(echo "${PAS_UAA_CREDENTIALS}" | jq -r '.identity')
	PAS_UAA_ADMIN_PASS=$(echo "${PAS_UAA_CREDENTIALS}" | jq -r '.password')
	PAS_ADMIN_NAME=$(echo "${PAS_CF_CREDENTIALS}" | jq -r '.identity')
	PAS_ADMIN_PASS=$(echo "${PAS_CF_CREDENTIALS}" | jq -r '.password')
fi

if [ "${ENABLE_PKS}" = true ]; then
	# Configure PKS:
	if [ ! -z "${PKS_API}" ]; then
		PKS_UAA="https://${PKS_API}:8443/"
	elif [ -z "${PKS_UAA}" ] || [ -z "${PKS_API}" ]; then
		echo "Getting PKS config (this can take up to 60 seconds)"
		echo "You can set PKS_API to speed this up (e.g. PKS_API=api.pks.cf.domain)"
		PKS_MANIFEST="$(om -k -u "${OPSMAN_ADMIN_USER}" -p "${OPSMAN_ADMIN_PASS}" -t "${OPSMAN_URI}" staged-manifest -p pivotal-container-service)"
		PKS_UAA="$(echo "${PKS_MANIFEST}" | yq -j r - | jq -r '.instance_groups | .[] | .jobs | .[] | select(.name == "uaa") | .properties.uaa.url')"
		PKS_API=${PKS_UAA/https:\/\//}
		PKS_API=${PKS_API/:8443//}
	fi
	echo PKS UAA Endpoint = "$PKS_UAA"
	echo PKS API Endpoint = "${PKS_API}"
	echo "Getting PKS credentials from opsman"
	PKS_UAA_CREDENTIALS="$(om --format=json -k -u "${OPSMAN_ADMIN_USER}" -p "${OPSMAN_ADMIN_PASS}" -t "${OPSMAN_URI}" credentials -p pivotal-container-service --credential-reference ".properties.uaa_admin_secret")"
	PKS_ADMIN_NAME="admin"
	PKS_ADMIN_PASS=$(echo "${PKS_UAA_CREDENTIALS}" | jq -r '.secret')
fi
# Attempt logins
if [ "${ENABLE_PAS}" = true ]; then
	if ! cf login "${CF_COMMAND_FLAGS}" -u "${PAS_ADMIN_NAME}" -p "${PAS_ADMIN_PASS}" -a "${PAS_API}" -o system -s system; then
		Failed to connect to PCF
		exit 1
	fi
	if ! uaac target "${CF_COMMAND_FLAGS}" "${PAS_UAA}"; then
		Failed to connect to PAS UAA
		exit 1
	fi
	if ! uaac token client get "${PAS_UAA_ADMIN_NAME}" -s "${PAS_UAA_ADMIN_PASS}"; then
		echo Failed to auth to PAS UAA
		exit 1
	fi
fi

if [ "${ENABLE_PKS}" = true ]; then
	if ! uaac target "${CF_COMMAND_FLAGS}" "${PKS_UAA}"; then
		echo "Failed to connect to PKS UAA"
		exit 1
	fi
	if ! uaac token client get "${PKS_ADMIN_NAME}" -s "${PKS_ADMIN_PASS}"; then
		echo "Failed to auth to PKS"
		exit 1
	fi
fi
if [ "${ENABLE_OPSMAN}" = true ]; then
	if ! uaac target "${CF_COMMAND_FLAGS}" "${OPSMAN_UAA}"; then
		echo "Failed to connect to opsman UAA"
		exit 1
	fi
	if ! uaac token owner get opsman "${OPSMAN_ADMIN_USER}" -p "${OPSMAN_ADMIN_PASS}" -s ""; then
		echo "Failed to auth to opsman uaa"
		exit 1
	fi
fi

if [ "${ENABLE_PAS}" = true ]; then
	cf create-org "${SHARED_ORG}"
	cf create-space "${SHARED_ORG}" -o "${SHARED_ORG}"
fi

IFS=,
for EMAIL in ${EMAIL_LIST}; do
	PW="$(openssl rand -base64 32 | tr -dc _A-Z-a-z-0-9 | head -c "${1:-12}")"
	NAME="$(echo "${EMAIL}" | awk -F@ '{ print $1 }')"

	echo ========== "${NAME}" ==========
	echo Username: "${NAME}"
	echo Password: "${PW}"
	echo CLI Commands:
	if [ "${ENABLE_PAS}" = true ]; then
		echo cf login "${CF_COMMAND_FLAGS}" -u "${NAME}" -p "${PW}" -a "${PAS_API}" -o "${NAME}" -s "${NAME}"
	fi
	if [ "${ENABLE_PKS}" = true ]; then
		echo pks login -u "${NAME}" -p "${PW}" -a "${PKS_API}" -k
	fi
	echo ====================
	{
	if [ "${ENABLE_PKS}" = true ]; then
		uaac target "${PKS_UAA}"
		uaac token client get "${PKS_ADMIN_NAME}" -s "${PKS_ADMIN_PASS}"
		uaac user add "${NAME}" --emails "${EMAIL}" -p "${PW}"
		uaac member add pks.clusters.admin "${NAME}"
	fi
	if [ "${ENABLE_PAS}" = true ]; then
		cf create-user "${NAME}" "${PW}"
		cf create-org "${NAME}"
		cf create-space "${NAME}" -o "${NAME}"
		cf set-org-role "${NAME}" "${NAME}" OrgManager
		cf set-org-role "${NAME}" "${NAME}" BillingManager
		cf set-org-role "${NAME}" "${NAME}" OrgAuditor
		cf set-space-role "${NAME}" "${NAME}" "${NAME}" SpaceManager
		cf set-space-role "${NAME}" "${NAME}" "${NAME}" SpaceDeveloper
		cf set-org-role "${NAME}" "${SHARED_ORG}" OrgManager
		cf set-org-role "${NAME}" "${SHARED_ORG}" BillingManager
		cf set-org-role "${NAME}" "${SHARED_ORG}" OrgAuditor
		cf set-space-role "${NAME}" "${SHARED_ORG}" "${SHARED_ORG}" SpaceManager
		cf set-space-role "${NAME}" "${SHARED_ORG}" "${SHARED_ORG}" SpaceDeveloper
		uaac target "${PAS_UAA}"
		uaac token client get "${PAS_UAA_ADMIN_NAME}" -s "${PAS_UAA_ADMIN_PASS}"
		uaac member add healthwatch.read "${NAME}"
		uaac member add network.write "${NAME}"
	fi
	if [ "${ENABLE_OPSMAN}" = true ]; then
		uaac target "${OPSMAN_UAA}"
		uaac token owner get opsman "${OPSMAN_ADMIN_USER}" -p "${OPSMAN_ADMIN_PASS}" -s ""
		uaac user add "${NAME}" --emails "${EMAIL}" -p "${PW}"
		uaac member add opsman.restricted_view "${NAME}"
	fi
	}>/dev/null
done
unset IFS
