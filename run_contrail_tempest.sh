#!/usr/bin/env bash

function usage {
  echo "Usage: $0 [OPTION]..."
  echo "Run Tempest unit tests"
  echo ""
  echo "  -V, --virtual-env        Always use virtualenv.  Install automatically if not present"
  echo "  -N, --no-virtual-env     Don't use virtualenv.  Run tests in local environment"
  echo "  -n, --no-site-packages   Isolate the virtualenv from the global Python environment"
  echo "  -f, --force              Force a clean re-build of the virtual environment. Useful when dependencies have been added."
  echo "  -u, --update             Update the virtual environment with any newer package versions"
  echo "  -t, --serial             Run testr serially"
  echo "  -C, --config             Config file location"                                                                          
  echo "  -p, --pep8               Just run pep8"
  echo "  -c, --coverage           Generate coverage report"
  echo "  -h, --help               Print this usage message"
  echo "  -d, --debug              Run tests with testtools instead of testr. This allows you to use PDB"
  echo "  -r, --result-xml         Path of Junitxml report to be generated"
  echo "  -P, --populate-config         Populate config file and init contrail environment"
  echo "  -- [TESTROPTIONS]        After the first '--' you can pass arbitrary arguments to testr "
}

function deprecation_warning {
  cat <<EOF
-------------------------------------------------------------------------
WARNING: run_tests.sh is deprecated and this script will be removed after
the Newton release. All tests should be run through testr/ostestr or tox.

To run style checks:

 tox -e pep8

To run python 2.7 unit tests

 tox -e py27

To run unit tests and generate coverage report

 tox -e cover

To run a subset of any of these tests:

 tox -e py27 someregex

 i.e.: tox -e py27 test_servers

Additional tox targets are available in tox.ini. For more information
see:
http://docs.openstack.org/project-team-guide/project-setup/python.html

NOTE: if you want to use testr to run tests, you can instead use:

 OS_TEST_PATH=./tempest/tests testr run

Documentation on using testr directly can be found at
http://testrepository.readthedocs.org/en/latest/MANUAL.html
-------------------------------------------------------------------------
EOF
}

testrargs=""
just_pep8=0
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
logging=0
logging_config=etc/logging.conf
result_xml="result.xml"
populate_config=0

deprecation_warning

if ! options=$(getopt -o VNnfuctphdC:Pr: -l virtual-env,no-virtual-env,no-site-packages,force,update,serial,coverage,pep8,help,debug,config:,populate-config,result-xml: -- "$@")
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
    -p|--pep8) let just_pep8=1;;
    -P|--populate-config) populate_config=1;;
    -r|--result-xml) result_xml=$2; shift;;
    -c|--coverage) coverage=1;;
    -t|--serial) serial=1;;
    -l|--logging) logging=1;;
    -L|--logging-config) logging_config=$2; shift;;
    --) [ "yes" == "$first_uu" ] || testrargs="$testrargs $1"; first_uu=no  ;;
    *) testrargs+=" $1";;
  esac
  shift
done

if [ -n "$config_file" ]; then
    config_file=`readlink -f "$config_file"`
    export TEMPEST_CONFIG_DIR=`dirname "$config_file"`
    export TEMPEST_CONFIG=`basename "$config_file"`
fi

if [ $logging -eq 1 ]; then
    if [ ! -f "$logging_config" ]; then
        echo "No such logging config file: $logging_config"
        exit 1
    fi
    logging_config=`readlink -f "$logging_config"`
    export TEMPEST_LOG_CONFIG_DIR=`dirname "$logging_config"`
    export TEMPEST_LOG_CONFIG=`basename "$logging_config"`
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

  if [ $coverage -eq 1 ]; then
      ${wrapper} python setup.py test --coverage
      return $?
  fi

  if [ $serial -eq 1 ]; then
      echo Executing $testrargs with $wrapper
      ${wrapper} testr run --subunit $testrargs | ${wrapper} subunit2junitxml -f -o $result_xml
  else
      echo -e "Executing all tests in parallel"
      ${wrapper} testr run --parallel --subunit $testrargs | ${wrapper} subunit2junitxml -f -o $result_xml
  fi
}

function run_pep8 {
  echo "Running flake8 ..."
  if [ $never_venv -eq 1 ]; then
      echo "**WARNING**:" >&2
      echo "Running flake8 without virtual env may miss OpenStack HACKING detection" >&2
  fi
  ${wrapper} flake8
}

function apply_patches {
  git apply contrail/bug_1373245.patch
}

sudo apt-get install -y git sshpass libxml2-dev libxslt-dev python-dev libffi-dev gcc || exit 1

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
      $venv/bin/pip install -U -r requirements.txt -r test-requirements.txt
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
      ${wrapper} pip install -U -r requirements.txt -r test-requirements.txt
    else
      echo -e "No virtual environment found...create one? (Y/n) \c"
      read use_ve
      if [ "x$use_ve" = "xY" -o "x$use_ve" = "x" -o "x$use_ve" = "xy" ]; then
        # Install the virtualenv and run the test suite in it
        virtualenv $installvenvopts $venv
        wrapper=${with_venv}
        ${wrapper} pip install -U -r requirements.txt -r test-requirements.txt
      fi
    fi
  fi
fi

if [ $just_pep8 -eq 1 ]; then
    run_pep8
    exit
fi

if [ $populate_config -eq 1 ]; then
   (unset http_proxy && ./contrail/contrail-tempest-init.sh)
fi

##apply_patches
(unset http_proxy && run_tests)
retval=$?

if [ -z "$testrargs" ]; then
    run_pep8
fi

exit $retval
