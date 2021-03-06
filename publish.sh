#!/bin/bash

#
# Publish Asterisk documentation to the wiki
#

PROGNAME=$(basename $0)
TOPDIR=$(cd $(dirname $0) && pwd)

if test -f ~/.asterisk-wiki.conf; then
   . ~/.asterisk-wiki.conf
fi

: ${AWK:=awk}
: ${GREP:=grep}
: ${MAKE:=make}
: ${SVN:=svn}

function fail()
{
    echo "${PROGNAME}: " "$@" >&2
    exit 1
}

function usage()
{
    echo "usage: ${PROGNAME} [--dry-run] branch-name"
}

DRY_RUN=false
while test $# -gt 0; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --)
            shift
            break
            ;;
        *)
            break
            ;;
    esac
done

if test $# -eq 0; then
    usage >&2
    exit 1
fi
BRANCH_NAME="$1"

#
# Check settings from config file
#
if ! test ${CONFLUENCE_URL}; then
    fail "CONFLUENCE_URL not set in ~/.asterisk-wiki.conf"
fi

if ! test ${CONFLUENCE_USER}; then
    fail "CONFLUENCE_USER not set in ~/.asterisk-wiki.conf"
fi

if ! test ${CONFLUENCE_PASSWORD}; then
    fail "CONFLUENCE_PASSWORD not set in ~/.asterisk-wiki.conf"
fi
# needed by publishing scripts. pass via the environment so it doesn't show
# up in the logs.
export CONFLUENCE_PASSWORD

# default space to AST
: ${CONFLUENCE_SPACE:=AST}

#
# Check repository
#
if ! test -f main/asterisk.c; then
    fail "Must run from an Asterisk checkout"
fi

#
# Check current working copy
#
CHANGES=$(${SVN} st --ignore-externals | grep -v '^X' | wc -l)
if test ${CHANGES} -ne 0; then
    fail "Asterisk checkout must be clean"
fi

# Verbose, and exit on any command failure
set -ex

#
# See if we need to build ARI docs
#
unset HAS_REST_API
if test -d doc/rest-api; then
    HAS_REST_API=true
fi

#
# Create a virtualenv to install dependencies
#
mkdir -p ~/virtualenv
if ! test -d ~/virtualenv/ast-publish-docs; then
    virtualenv ~/virtualenv/ast-publish-docs
fi
. ~/virtualenv/ast-publish-docs/bin/activate
pip install -Ur ${TOPDIR}/requirements.txt

if test configure -nt makeopts; then
    # Build into a temporary directory
    AST_DIR=$(mktemp -d /tmp/ast-docs.XXXXXX)
    trap "rm -rf $AST_DIR" EXIT

    ./configure --prefix=${AST_DIR} --enable-dev-mode=noisy
else
    # Dev machine already configured for building
    AST_DIR=$(sed -n "s/^prefix='\([^']*\)'/\1/ p" config.log)
fi

AST_VER=$(export GREP; export AWK; ./build_tools/make_version .)

#
# Check ARI documentation consistency
#
if test ${HAS_REST_API}; then
    # Generate latest ARI documentation
    make ari-stubs

    # Ensure docs are consistent with the implementation
    CHANGES=$(${SVN} st --ignore-externals | grep -v '^X' | wc -l)
    if test ${CHANGES} -ne 0; then
        fail "Asterisk code out of date compared to the model"
    fi

    # make ari-stubs may modify the $Revision$ tags in a file; revert the
    # changes
    svn revert . -R -q
fi

#
# Don't publish docs for trunk. We still want the above validation to ensure
# that REST API docs are kept up to date.
#
if test ${BRANCH_NAME} = 'trunk'; then
    exit 0;
fi

#
# Publish the REST API.
#
if test ${HAS_REST_API}; then
    if ${DRY_RUN}; then
        DRY_RUN_ARG=--dry-run
    else
        DRY_RUN_ARG=
    fi

    ${TOPDIR}/publish-rest-api.py --username="${CONFLUENCE_USER}" \
        ${DRY_RUN_ARG} \
        --verbose \
        --ast-version="${AST_VER}" \
        ${CONFLUENCE_URL} \
        ${CONFLUENCE_SPACE} \
        "Asterisk ${BRANCH_NAME}"
fi

#
# XML docs need a live Asterisk to interact with, so build one
#
case ${BRANCH_NAME} in
    1.8|10*)
        # 10 and earlier only had core docs
        make doc/core-en_US.xml
        mv -f doc/core-en_US.xml ${TOPDIR}/asterisk-docs.xml
        ;;
    11)
        # 11 had full docs
        make doc/full-en_US.xml
        mv -f doc/core-en_US.xml ${TOPDIR}/asterisk-docs.xml
        ;;
    *)
        # 12 and later needs to run Asterisk, so a full build
        # is necessary
        NPROC=1
        if which nproc > /dev/null 2>&1; then
            NPROC=$(nproc)
        fi
        JOBS=$(( ${NPROC} + ${NPROC} / 2 ))
        make -j ${JOBS} full && make install samples

        killall -9 asterisk || true # || true so set -e doesn't kill us
        ${AST_DIR}/sbin/asterisk &
        sleep 1

        rm -f ${TOPDIR}/full-en_US.xml
        ${AST_DIR}/sbin/asterisk -x "core waitfullybooted"
        ${AST_DIR}/sbin/asterisk -x "xmldoc dump ${TOPDIR}/asterisk-docs.xml"

        # Kill Asterisk, and wait for it to die
        AST_PID=$(cat ${AST_DIR}/var/run/asterisk/asterisk.pid)
        killall -9 asterisk || true # || true so set -e doesn't kill us
        while kill -0 ${AST_PID}; do
            sleep 0.1
        done
        ;;
esac

#
# Set the prefix argument for publishing docs
#
if test ${BRANCH_NAME} = 1.8; then
        # Asterisk 1.8 docs don't have a prefix
        PREFIX=""
else
        PREFIX="Asterisk ${BRANCH_NAME}"
fi

#
# Publish XML documentation.
#

if ${DRY_RUN}; then
    DRY_RUN_ARG=--diff
else
    DRY_RUN_ARG=
fi

# Script assumes that it's running from TOPDIR
cd ${TOPDIR}

${TOPDIR}/astxml2wiki.py --username="${CONFLUENCE_USER}" \
    --server=${CONFLUENCE_URL} \
    --prefix="${PREFIX}" \
    --space="${CONFLUENCE_SPACE}" \
    --file=${TOPDIR}/asterisk-docs.xml \
    --ast-version="${AST_VER}" \
    ${DRY_RUN_ARG} \
    -v
