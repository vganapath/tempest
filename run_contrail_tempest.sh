#!/usr/bin/env bash

function usage {
  echo "Usage: $0 [OPTION]..."
  echo "Run Tempest test suite"
  echo ""
  echo "  -V, --virtual-env        Always use virtualenv.  Install automatically if not present"
  echo "  -N, --no-virtual-env     Don't use virtualenv.  Run tests in local environment"
  echo "  -n, --no-site-packages   Isolate the virtualenv from the global Python environment"
  echo "  -f, --force              Force a clean re-build of the virtual environment. Useful when dependencies have been added."
  echo "  -u, --update             Update the virtual environment with any newer package versions"
  echo "  -s, --smoke              Only run smoke tests"
  echo "  -t, --serial             Run testr serially"
  echo "  -C, --config             Config file location"
  echo "  -h, --help               Print this usage message"
  echo "  -d, --debug              Run tests with testtools instead of testr. This allows you to use PDB"
  echo "  -r, --result-xml         Path of Junitxml report to be generated"
  echo "  -p, --populate-config         Populate config file and init contrail environment"
  echo "  -- [TESTROPTIONS]        After the first '--' you can pass arbitrary arguments to testr "
}

testrargs=""
venv=${VENV:-.venv}
with_venv=tools/with_venv.sh
serial=0
always_venv=0
never_venv=0
no_site_packages=0
debug=0
force=0
coverage=0
wrapper=""
config_file=""
update=0
result_xml="result.xml"
populate_config=0

if ! options=$(getopt -o VNnfusthdC:pr: -l virtual-env,no-virtual-env,no-site-packages,force,update,smoke,serial,help,debug,config:,populate-config,result-xml: -- "$@")
then
    # parse error
    usage
    exit 1
fi

eval set -- $options
first_uu=yes
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit;;
    -V|--virtual-env) always_venv=1; never_venv=0;;
    -N|--no-virtual-env) always_venv=0; never_venv=1;;
    -n|--no-site-packages) no_site_packages=1;;
    -f|--force) force=1;;
    -u|--update) update=1;;
    -d|--debug) debug=1;;
    -C|--config) config_file=$2; shift;;                                                                                          
    -s|--smoke) testrargs+="smoke";;
    -p|--populate-config) populate_config=1;;
    -r|--result-xml) result_xml=$2; shift;;
    -t|--serial) serial=1;;
    --) [ "yes" == "$first_uu" ] || testrargs="$testrargs $1"; first_uu=no  ;;
    *) testrargs="$testrargs $1";;
  esac
  shift
done

if [ -n "$config_file" ]; then
    config_file=`readlink -f "$config_file"`
    export TEMPEST_CONFIG_DIR=`dirname "$config_file"`
    export TEMPEST_CONFIG=`basename "$config_file"`
fi

cd `dirname "$0"`

if [ $no_site_packages -eq 1 ]; then
  installvenvopts="--no-site-packages"
fi

function testr_init {
  if [ ! -d .testrepository ]; then
      ${wrapper} testr init
  fi
}

function run_tests {

  echo -e "Run tests"
  testr_init
  ${wrapper} find . -type f -name "*.pyc" -delete
  export OS_TEST_PATH=./tempest/test_discover
  if [ $debug -eq 1 ]; then
      if [ "$testrargs" = "" ]; then
           testrargs="discover ./tempest/test_discover"
      fi
      ${wrapper} python -m testtools.run $testrargs
      return $?
  fi

  if [ $serial -eq 1 ]; then
      echo Executing $testrargs with $wrapper
      ${wrapper} testr run --subunit $testrargs | ${wrapper} subunit2junitxml -f -o $result_xml
  else
      ${wrapper} testr run --parallel --subunit $testrargs | ${wrapper} subunit2junitxml -f -o $result_xml
  fi
}

if [ $never_venv -eq 0 ]
then
  echo -e "Setting up virtual env"
  # Remove the virtual environment if --force used
  if [ $force -eq 1 ]; then
    echo "Cleaning virtualenv..."
    rm -rf ${venv}
  fi
  if [ $update -eq 1 ]; then
      echo "Updating virtualenv..."
      virtualenv $installvenvopts $venv
      $venv/bin/pip install -U -r requirements.txt
  fi
  if [ -e ${venv} ]; then
    echo -e "env is already available"
    wrapper="${with_venv}"
  else
    if [ $always_venv -eq 1 ]; then
      echo -e "Automatically installing the virtualenv"
      # Automatically install the virtualenv
      virtualenv $installvenvopts $venv
      wrapper="${with_venv}"
      ${wrapper} pip install -U -r requirements.txt
    else
      echo -e "No virtual environment found...create one? (Y/n) \c"
      read use_ve
      if [ "x$use_ve" = "xY" -o "x$use_ve" = "x" -o "x$use_ve" = "xy" ]; then
        # Install the virtualenv and run the test suite in it
        virtualenv $installvenvopts $venv
        wrapper=${with_venv}
        ${wrapper} pip install -U -r requirements.txt
      fi
    fi
  fi
fi

if [ $populate_config -eq 1 ]; then
   (unset http_proxy && ./contrail/contrail-tempest-init.sh)
fi

##apply_patches
(unset http_proxy && run_tests)
retval=$?


exit $retval
