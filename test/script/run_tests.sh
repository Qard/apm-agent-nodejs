#!/usr/bin/env bash

set -eo pipefail # abort if any of the commands exit badly

number_of_started_containers () {
  echo "$(docker ps --format '{{.ID}}' | wc -l | awk '{$1=$1};1')"
}

number_of_healthy_containers () {
  echo "$(docker ps -f health=healthy --format '{{.ID}}' | wc -l | awk '{$1=$1};1')"
}

wait_for_healthy () {
  local n=1
  local max=99

  until [[ $n -ge $max ]]
  do
    healthy=$(number_of_healthy_containers)
    echo -ne "[check $n of $max] Docker healthcheck status: $healthy of $expected_healthy\033[0K\r"
    test $healthy -eq $expected_healthy && break
    n=$[$n+1]
    sleep 5
  done
  echo

  if [ $n -ge $max ]; then exit 1; fi
}

setup_env () {
  for service in "${service_arr[@]}"
  do
    if [ "$service" == "postgres" ]
    then
      export PGUSER=postgres
    fi
  done
}

run_test_suite () {
  standard
  npm run test:deps
  npm run lint:commit
  
  if [ -n "${JUNIT}" ]
  then
    npm install -g tap-junit
    nyc node test/test.js | tee test-output.tap
    cat test-output.tap | tap-junit --package="Agent Node.js" > junit-node-report.xml
  elif [ -z "$COVERAGE" ]
  then
    node test/test.js
  else
    nyc node test/test.js
  fi

  npm run test:types
  npm run test:babel
  npm run test:esm
}

major_node_version=`node --version | cut -d . -f1 | cut -d v -f2`
minor_node_version=`node --version | cut -d . -f2`

if [[ $major_node_version -eq 8 ]] && [[ $minor_node_version -lt 8 ]]; then
  export NODE_OPTIONS="$NODE_OPTIONS --expose-http2"
fi

if [[ "$CI" || "$1" == "none" ]]
then
  # We're running on a CI server where we expect all dependencies have
  # been set up in advance, or the user specificailly used the "none"
  # command to indicate that they do not want to spin up any
  # dependencies
  run_test_suite
  exit $?
elif [[ "$1" == "all" ]]
then
  # The user used the "all" command which indicates that they want to
  # spin up all dependencies, and build+run the test suite inside of
  # Docker as well
  if [ -z "$2" ]
  then
    node_version=$major_node_version
  else
    node_version=$2
  fi
  ./test/script/docker/run_tests.sh $node_version $3
  exit $?
elif [[ $# -gt 0 ]]
then
  # User have specified a shortlist of dependencies that they want us to
  # spin up inside Docker before running the test sutie
  services=$@
else
  # No arguments was given. Let's just assume that the user wants to
  # spin up all dependencies inside Docker and run the tests locally
  services=$(docker-compose  -f ./test/docker-compose.yml  config --services)
fi

service_arr=( $services )
total_services=${#service_arr[@]}
expected_healthy=$total_services
healthy=$(number_of_healthy_containers)
expected_containers=$total_services
containers=$(number_of_started_containers)

if [[ $healthy -lt $expected_healthy && $containers -eq $expected_containers ]]
then
  wait_for_healthy
elif [[ $healthy -lt $expected_healthy || $containers -lt $expected_containers ]]
then
  finish () {
    docker-compose -f ./test/docker-compose.yml down
  }
  trap finish EXIT

  docker-compose -f ./test/docker-compose.yml up -d $services
  wait_for_healthy
fi

setup_env
run_test_suite
