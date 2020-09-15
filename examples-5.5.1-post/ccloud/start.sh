#!/bin/bash

# Source library
source ../utils/helper.sh
source ../utils/ccloud_library.sh

NAME=`basename "$0"`

Time()
{
export DT=`date +"%H:%M:%S"`
}


Time
echo ${DT} ====== Verifying prerequisites
validate_version_confluent_cli_v2 \
  && print_pass "confluent CLI version ok" \
  || exit 1
check_env \
  && print_pass "Confluent Platform installed" \
  || exit 1
check_cp \
  || exit_with_error -c $? -n $NAME -l $LINENO -m "This demo uses Confluent Replicator which requires Confluent Platform, however this host is running Confluent Community Software"
check_running_cp ${CONFLUENT} \
  && print_pass "Confluent Platform version ${CONFLUENT} ok" \
  || exit 1
check_jq \
  && print_pass "jq installed" \
  || exit 1
ccloud::validate_version_ccloud_cli 1.7.0 \
  && print_pass "ccloud version ok" \
  || exit 1
ccloud::validate_logged_in_ccloud_cli \
  && print_pass "logged into ccloud CLI" \
  || exit 1

Time
echo;echo;
echo ${DT} ====== Create new Confluent Cloud stack
ccloud::prompt_continue_ccloud_demo || exit 1
ccloud::create_ccloud_stack true
echo;echo
echo "${DT} ========(1/5) create a new service account on Confluent Cloud"
SERVICE_ACCOUNT_ID=$(ccloud kafka cluster list -o json | jq -r '.[0].name' | awk -F'-' '{print $4;}')
if [[ "$SERVICE_ACCOUNT_ID" == "" ]]; then
  echo "ERROR: Could not determine SERVICE_ACCOUNT_ID from 'ccloud kafka cluster list'. Please troubleshoot, destroy stack, and try again to create the stack."
  exit 1
fi
CONFIG_FILE=stack-configs/java-service-account-$SERVICE_ACCOUNT_ID.config
export CONFIG_FILE=$CONFIG_FILE
ccloud::validate_ccloud_config $CONFIG_FILE \
  && print_pass "$CONFIG_FILE ok" \
  || exit 1

Time
echo "${DT} ========(2/5) auto-Generate Confluent Cloud configuration file using the new service account"
./ccloud-generate-cp-configs.sh $CONFIG_FILE

DELTA_CONFIGS_DIR=delta_configs
source $DELTA_CONFIGS_DIR/env.delta
printf "\n"

# Pre-flight check of Confluent Cloud credentials specified in $CONFIG_FILE
Time
MAX_WAIT=720
echo "${DT} ========(3/5) create a new environment benchmark-env-$SERVICE_ACCOUNT_ID"
echo "${DT} ========(4/5) create a new managed kafka cluster on ${CLUSTER_CLOUD} in region ${CLUSTER_REGION}"
echo "${DT} ========(5/5) create a new ksqlDB stream processing service"
echo "${DT} Waiting up to $MAX_WAIT seconds for Confluent Cloud cluster components to be UP"
retry $MAX_WAIT ccloud::validate_ccloud_ksqldb_endpoint_ready $KSQLDB_ENDPOINT || exit 1
ccloud::validate_ccloud_stack_up $CLOUD_KEY $CONFIG_FILE || exit 1

Time
echo;echo
echo "${DT} ====== On-prem: Creating On-prem stack to stream to Confluent Cloud"
confluent-hub install --no-prompt confluentinc/kafka-connect-datagen:$KAFKA_CONNECT_DATAGEN_VERSION
printf "\n"

Time
echo "${DT} ====== On-prem: (1/9) Starting local ZooKeeper, Kafka Broker, Schema Registry, Connect"
confluent local start zookeeper
sleep 2

# Start local Kafka with Confluent Metrics Reporter configured for Confluent Cloud
CONFLUENT_CURRENT=`confluent local current 2>&1 | tail -1`
mkdir -p $CONFLUENT_CURRENT/kafka
KAFKA_CONFIG=$CONFLUENT_CURRENT/kafka/server.properties
cp $CONFLUENT_HOME/etc/kafka/server.properties $KAFKA_CONFIG
cat $DELTA_CONFIGS_DIR/metrics-reporter.delta >> $KAFKA_CONFIG
kafka-server-start $KAFKA_CONFIG > $CONFLUENT_CURRENT/kafka/server.stdout 2>&1 &
echo $! > $CONFLUENT_CURRENT/kafka/kafka.pid
Time
echo "${DT} ====== On-prem: (2/9) Waiting 30s for the local Kafka broker to be UP"
sleep 30

confluent local start connect
printf "\n"

Time
echo "${DT} ====== On-prem: (3/9) Specify a target environment and cluster for Confluent Cloud "
# Set Kafka cluster and service account
ccloud::set_kafka_cluster_use $CLOUD_KEY $CONFIG_FILE || exit 1
serviceAccount=$(ccloud::get_service_account $CLOUD_KEY $CONFIG_FILE) || exit 1
printf "\n"

Time
echo "${DT} ====== On-prem: (4/9) Validate Schema Registry credentials (on Confluent Cloud)"
# Validate credentials to Confluent Cloud Schema Registry
ccloud::validate_schema_registry_up $SCHEMA_REGISTRY_BASIC_AUTH_USER_INFO $SCHEMA_REGISTRY_URL || exit 1
printf "Done\n\n"

Time
echo "${DT} ====== On-prem: (5/9) Start local Confluent Control Center to monitor Cloud and local clusters"
# For the Connect cluster backed to Confluent Cloud, set the REST port, instead of the default 8083 which is already in use by the local connect cluster
CONNECT_REST_PORT=8087

ccloud::create_acls_control_center $serviceAccount
if check_cp; then
  mkdir -p $CONFLUENT_CURRENT/control-center
  C3_CONFIG=$CONFLUENT_CURRENT/control-center/control-center-ccloud.properties
  cp $CONFLUENT_HOME/etc/confluent-control-center/control-center-production.properties $C3_CONFIG
  # Stop the Control Center that starts with Confluent CLI to run Control Center to Confluent Cloud
  jps | grep ControlCenter | awk '{print $1;}' | xargs kill -9
  cat $DELTA_CONFIGS_DIR/control-center-ccloud.delta >> $C3_CONFIG

cat <<EOF >> $C3_CONFIG
# Kafka clusters
confluent.controlcenter.kafka.local.bootstrap.servers=localhost:9092
confluent.controlcenter.kafka.cloud.bootstrap.servers=$BOOTSTRAP_SERVERS
confluent.controlcenter.kafka.cloud.ssl.endpoint.identification.algorithm=https
confluent.controlcenter.kafka.cloud.sasl.mechanism=PLAIN
confluent.controlcenter.kafka.cloud.security.protocol=SASL_SSL
confluent.controlcenter.kafka.cloud.sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=\"$CLOUD_KEY\" password=\"$CLOUD_SECRET\";

# Connect clusters
confluent.controlcenter.connect.local.cluster=http://localhost:8083
confluent.controlcenter.connect.cloud.cluster=http://localhost:$CONNECT_REST_PORT

confluent.controlcenter.data.dir=$CONFLUENT_CURRENT/control-center/data-ccloud
# Workaround for MMA-3564
confluent.metrics.topic.max.message.bytes=8388608
EOF

  ccloud kafka acl create --allow --service-account $serviceAccount --operation WRITE --topic _confluent-controlcenter --prefix
  ccloud kafka acl create --allow --service-account $serviceAccount --operation READ --topic _confluent-controlcenter --prefix
  control-center-start $C3_CONFIG > $CONFLUENT_CURRENT/control-center/control-center-ccloud.stdout 2>&1 &
fi
printf "\n"

Time
echo "${DT} ====== On-prem: (6/9) Create topic "pageviews" in local cluster"
kafka-topics --bootstrap-server localhost:9092 --create --topic pageviews --partitions 6 --replication-factor 1
sleep 20
printf "\n"

Time
echo "${DT} ====== On-prem: (7/9) Deploying kafka-connect-datagen to aut-generate messages into topic pageviews"
source ./connectors/submit_datagen_pageviews_config.sh
printf "\n\n"

Time
echo "${DT} ====== On-prem: (8/9) Start Kafka Connect cluster that connects to Confluent Cloud Kafka cluster"
mkdir -p $CONFLUENT_CURRENT/connect
CONNECT_CONFIG=$CONFLUENT_CURRENT/connect/connect-ccloud.properties
cp $CONFLUENT_CURRENT/connect/connect.properties $CONNECT_CONFIG
cat $DELTA_CONFIGS_DIR/connect-ccloud.delta >> $CONNECT_CONFIG
cat <<EOF >> $CONNECT_CONFIG
rest.port=$CONNECT_REST_PORT
rest.advertised.name=connect-cloud
rest.hostname=connect-cloud
group.id=connect-cloud
config.storage.topic=connect-demo-configs
offset.storage.topic=connect-demo-offsets
status.storage.topic=connect-demo-statuses
EOF
ccloud::create_acls_connect_topics $serviceAccount
export CLASSPATH=$(find ${CONFLUENT_HOME}/share/java/kafka-connect-replicator/replicator-rest-extension-*)
connect-distributed $CONNECT_CONFIG > $CONFLUENT_CURRENT/connect/connect-ccloud.stdout 2>&1 &
MAX_WAIT=420
Time
echo "${DT} ====== On-prem: (9/9) Waiting up to $MAX_WAIT seconds for the connect worker that connects to Confluent Cloud to start"
retry $MAX_WAIT check_connect_up_logFile $CONFLUENT_CURRENT/connect/connect-ccloud.stdout || exit 1
printf "\n\n"

Time
echo "${DT} ====== Cloud: (1/8) Create topic "users" and set ACLs in Confluent Cloud cluster"
ccloud kafka topic create users
ccloud kafka acl create --allow --service-account $serviceAccount --operation WRITE --topic users
printf "\n"

Time
echo "${DT} ====== Cloud: (2/8) Deploying kafka-connect-datagen for users"
source ./connectors/submit_datagen_users_config.sh
printf "\n"

Time
echo "${DT} ====== Cloud: (3/8) Replicate local topic 'pageviews' to Confluent Cloud topic 'pageviews'"
# No need to pre-create topic pageviews in Confluent Cloud because Replicator will do this automatically
ccloud::create_acls_replicator $serviceAccount pageviews
printf "\n"

Time
echo "${DT} ====== Cloud: (4/8) Starting Replicator to replicate topic 'pageviews' from on-prem Kafka Cluster to Cloud Kafka Cluster"
source ./connectors/submit_replicator_config.sh
MAX_WAIT=60
printf "\n${DT} ====== Cloud: (5/8) Waiting up to $MAX_WAIT seconds for the topic 'pageviews' to be created in Confluent Cloud"
retry $MAX_WAIT ccloud::validate_topic_exists pageviews || exit 1
printf "\n${DT} ====== Cloud: (6/8) Waiting up to $MAX_WAIT seconds for the subject 'pageviews-value' to be created in Confluent Cloud Schema Registry"
retry $MAX_WAIT ccloud::validate_subject_exists "pageviews-value" $SCHEMA_REGISTRY_URL $SCHEMA_REGISTRY_BASIC_AUTH_USER_INFO || exit 1
printf "\n\n"

Time
echo;echo;echo
echo "${DT} ====== Cloud: (7/8) Benchmark system is (half!) running. Data pipeline running from on-prem to Confluent Cloud"
Time

echo;echo;echo
echo "${DT} ====== Cloud: (8/8) About to Create stream processing application using managed ksqlDB"
echo "Enter go to proceed"
hello=nogo
while [ "$hello" = "nogo" ]
do
  read hello
done
echo "Continuing the build ...."
sleep 2


Time
echo "${DT} ====== ksqlDB: Creating stream processing application using managed ksqlDB"
./create_ksqldb_app.sh || exit 1
printf "\n"

Time
printf "\n ${DT} DONE! Connect to your Confluent Cloud UI at https://confluent.cloud/ or Confluent Control Center at http://localhost:9021\n"
echo
echo
echo "To stop this demo and destroy Confluent Cloud resources run ->"
echo "    ./stop.sh $CONFIG_FILE"
echo

echo
ENVIRONMENT=$(ccloud environment list | grep benchmark-env-$SERVICE_ACCOUNT_ID | tr -d '\*' | awk '{print $1;}')
echo "Tip: 'ccloud' CLI has been set to the new environment $ENVIRONMENT"
