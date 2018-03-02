#!/usr/bin/env bash

TRY_LOOP="20"

: ${RABBITMQ_HOST:="rabbitmq"}
: ${RABBITMQ_CREDS:="airflow:airflow"}
: ${RABBITMQ_PORT:="15672"}
: ${RABBITMQ_BROKER_PORT:="5672"}

: ${MYSQL_HOST:="mysql"}
: ${MYSQL_PORT:="3306"}
: ${MYSQL_USER:="airflow"}
: ${MYSQL_PASSWORD:="airflow"}
: ${MYSQL_DB:="airflow"}

# Defaults and back-compat
: "${AIRFLOW__CORE__FERNET_KEY:=${FERNET_KEY:=$(python -c "from cryptography.fernet import Fernet; FERNET_KEY = Fernet.generate_key().decode(); print(FERNET_KEY)")}}"
: "${AIRFLOW__CORE__EXECUTOR:=${EXECUTOR:-Sequential}Executor}"

export \
  AIRFLOW__CELERY__BROKER_URL \
  AIRFLOW__CELERY__CELERY_RESULT_BACKEND \
  AIRFLOW__CORE__EXECUTOR \
  AIRFLOW__CORE__FERNET_KEY \
  AIRFLOW__CORE__LOAD_EXAMPLES \
  AIRFLOW__CORE__SQL_ALCHEMY_CONN \


# Load DAGs exemples (default: Yes)
if [[ -z "$AIRFLOW__CORE__LOAD_EXAMPLES" && "${LOAD_EX:=n}" == n ]]
then
  AIRFLOW__CORE__LOAD_EXAMPLES=False
fi

# Install custom python package if requirements.txt is present
if [ -e "/requirements.txt" ]; then
    $(which pip) install --user -r /requirements.txt
fi



wait_for_port() {
  local name="$1" host="$2" port="$3"
  local j=0
  while ! nc -z "$host" "$port" >/dev/null 2>&1 < /dev/null; do
    j=$((j+1))
    if [ $j -ge $TRY_LOOP ]; then
      echo >&2 "$(date) - $host:$port still not reachable, giving up"
      exit 1
    fi
    echo "$(date) - waiting for $name... $j/$TRY_LOOP"
    sleep 5
  done
}

wait_for_rabbitmq() {
# Wait for RabbitMQ if we are using it
  if [ "$AIRFLOW__CORE__EXECUTOR" = "CeleryExecutor" ]; then
    j=0
    while ! curl -sI -u $RABBITMQ_CREDS http://$RABBITMQ_HOST:$RABBITMQ_PORT/api/whoami | grep '200 OK'; do
      j=$((j+1))
      if [ $j -ge $TRY_LOOP ]; then
        echo "$(date) - $RABBITMQ_HOST still not reachable, giving up"
        exit 1
      fi
      echo "$(date) - waiting for RabbitMQ... $j/$TRY_LOOP"
      sleep 5
    done
  fi
}

AIRFLOW__CORE__SQL_ALCHEMY_CONN="mysql+mysqldb://$MYSQL_USER:$MYSQL_PASSWORD@$MYSQL_HOST:$MYSQL_PORT/$MYSQL_DB"
AIRFLOW__CELERY__BROKER_URL="amqp://$RABBITMQ_CREDS@$RABBITMQ_HOST:$RABBITMQ_BROKER_PORT/airflow"
AIRFLOW__CELERY__CELERY_RESULT_BACKEND="db+mysql://$MYSQL_USER:$MYSQL_PASSWORD@$MYSQL_HOST:$MYSQL_PORT/$MYSQL_DB"

case "$1" in
  webserver)
    wait_for_port "Mysql" "$MYSQL_HOST" "$MYSQL_PORT"
    wait_for_rabbitmq
    airflow initdb
    if [ "$AIRFLOW__CORE__EXECUTOR" = "LocalExecutor" ];
    then
      # With the "Local" executor it should all run in one container.
      airflow scheduler &
    fi
    exec airflow webserver
    ;;
  worker|scheduler)
    wait_for_port "Mysql" "$MYSQL_HOST" "$MYSQL_PORT"
    wait_for_rabbitmq
    # To give the webserver time to run initdb.
    sleep 10
    exec airflow "$@"
    ;;
  flower)
    wait_for_redis
    exec airflow "$@"
    ;;
  version)
    exec airflow "$@"
    ;;
  *)
    # The command is something like bash, not an airflow subcommand. Just run it in the right environment.
    exec "$@"
    ;;
esac
