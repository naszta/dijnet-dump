#!/bin/bash
# dump all dijnet.hu invoices to the actual folder
#
# required dependency:
# - libxml2-utils
# 
# optional dependency:
# - pv (if you want a nice progress bar)

SCRIPT=$(basename $0)
DIJNET_BASE_URL="https://www.dijnet.hu/ekonto"

USER="$1"; PASS="$2"

if [ -z "${USER}" ]; then
  echo "usage: ${SCRIPT} username <password>" >&2
  exit 1
fi
[ -z "${PASS}" ] && read -s -p "password: " PASS

COOKIES=$(mktemp)
trap "rm ${COOKIES}" EXIT
trap 'PREV_COMMAND="${THIS_COMMAND}"; THIS_COMMAND="${BASH_COMMAND}"' DEBUG

die() {
  [ -z "$1" ] && echo "ERROR: exit code not zero of command: ${PREV_COMMAND}" >&2 || echo "ERROR: $1" >&2
  kill $$
  exit 1
}

xpath() {
  xmllint --html --xpath "$1" - 2>/dev/null
}

dijnet() {
  URL_POSTFIX="$1"
  POST_DATA="$2"
  wget \
    --quiet \
    --output-document=- \
    --load-cookies "${COOKIES}" \
    --save-cookies "${COOKIES}" \
    --keep-session-cookies \
    --post-data "${POST_DATA}" \
    ${DIJNET_BASE_URL}/${URL_POSTFIX}
}

progress() {
  if which pv &>/dev/null; then
    pv -N "download \"${PROVIDER}\", total: ${INVOICE_COUNT}, current" -W -b -w 120 -p -l -t -e -s ${INVOICE_COUNT} >/dev/null
  else
    xargs -I{} printf "\033[2K\rdownload \"${PROVIDER}\", total: ${INVOICE_COUNT}, current: {}"
    echo
  fi
}
#Dijnet UI changed in 2017.09 therefore login is different
printf "login... "
dijnet "login/login_check_password" "vfw_form=login_check_password&username=${USER}&password=${PASS}" \
| grep -q "Bejelentkez&eacute;si n&eacute;v: <strong>${USER}" || die "login failed"
echo OK

printf "query service providers... "
PROVIDERS=$(dijnet "control/szamla_search" | xpath '//select[@name="szlaszolgid"]/option[string-length(@value)!=0]')
[ -n "${PROVIDERS}" ] || die "not able to detect service providers"
echo "${PROVIDERS}" | grep -o "value" | wc -w

for ID in $(echo "${PROVIDERS}" | xpath '//option/@value' | sed 's/value="\([^"]*\)"/\1 /g'); do
  PROVIDER=$(echo "${PROVIDERS}" | xpath "//option[@value=${ID}]/text()" | sed 's/&\([a-zA-Z]\)[a-zA-Z]*;/\1/g')
  INVOICES=$(dijnet "control/szamla_search_submit" "vfw_form=szamla_search_submit&vfw_coll=szamla_search_params&szlaszolgid=${ID}" \
           | xpath '//table[contains(@class, "szamla_table")]/tbody/tr/td[1]/a/@href' \
           | sed 's/href="\([^"]*\)"/\1 /g;s/\&amp;/\&/g;s/\/ekonto\/control\///g')
  INVOICE_COUNT=$(echo "${INVOICES}" | wc -w)
  INVOICE_INDEX=1
  for INVOICE in ${INVOICES}; do
    dijnet "control/${INVOICE}" | iconv -f iso8859-2 -t utf-8 | grep -q 'href="szamla_letolt"' || die
    INVOICE_DOWNLOAD=$(dijnet "control/szamla_letolt")
    INVOICE_NUMBER=$(echo "${INVOICE_DOWNLOAD}" | xpath '//label[@class="title_next_s"]/text()' | sed 's/\//_/g;s/ //g')
    TARGET_FOLDER=$(echo "${PROVIDER}/${INVOICE_NUMBER}" | sed 's/ \+/_/g')
    mkdir -p "${TARGET_FOLDER}" || die "not able to create folder: ${TARGET_FOLDER}"
    echo "${INVOICE_INDEX}"
    DOWNLOAD_LINKS=$(echo "${INVOICE_DOWNLOAD}" | xpath '//a[contains(@class, "xt_link__download")]/@href' | sed 's/href="\([^"]*\)"/\1 /g')
    for DOWNLOAD_LINK in ${DOWNLOAD_LINKS}; do
      echo "${DOWNLOAD_LINK}" | egrep -qi "adobe|e-szigno" && continue
      wget --quiet --load-cookies "${COOKIES}" --content-disposition --no-clobber \
           --directory-prefix "${TARGET_FOLDER}" "${DIJNET_BASE_URL}/control/${DOWNLOAD_LINK}"
    done
    dijnet "control/szamla_list" &>/dev/null
    ((INVOICE_INDEX++))
  done | progress
done
