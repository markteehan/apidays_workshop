# Introduction
This repository is used to test a local Confluent Platform cluster integrating with a Confluent Cloud cluster. It was used as the basis of a demonstration during the APIdays workshop, and is provided for participants to try out the scripted process.

This more advanced demo showcases an on-prem Kafka cluster and [Confluent Cloud](https://www.confluent.io/confluent-cloud/?utm_source=github&utm_medium=demo&utm_campaign=ch.examples_type.community_content.top) cluster, and data copied between them with Confluent Replicator <br><img src="examples-5.5.1-post/ccloud/docs/images/services-in-cloud.jpg" width="450">

The completed script will:

* Create a new service account on Confluent Cloud
* Generate a local configuration file to use the service account
* Create a new environment on Confluent Cloud
* Create a new managed cluster on Confluent Cloud
* Create a new ksqlDB service on Confluent Cloud
* Start a local Confluent Platform cluster
* Start a local Confluent Control Centre attached to Confluent Cloud and local Confluent Platform
* Create topics in the local cluster
* Create a data generator in the local Confluent Platform for users and pageviews
* Start a local Connect cluster that connects to Confluent Cloud
* Create ACLs to secure the Confluent Cloud cluster
* Start replicator to move date from the local Confluent Platform to Confluent Cloud
* Create a ksqlDB streaming application in Confluent Cloud

# Before you start
This script will setup a cluster on Confluent Cloud. This account will be **incurring costs**, so don't leave the account up and running longer than required.

If you want to try out Confluent Cloud you can receive $200 credit per month for three months by visting https://www.confluent.io/confluent-cloud/ and clicking the "Try Free" button.

Also note that this repository is designed to demonstrate approaches to scriptable depoyments suitable for CI/CD pipelines, but you may need to adapt to your specific use cases.

Additionally, the script uses your Confluent Cloud username and password, which is simple for the demonstration, but **not suitable for being shared across a team**. Use API keys and service accounts if you plan on operationalising these scripts.

# Getting started

1. Clone the repository
2. Copy `.apidays.default` to `.apidays`. 
3. Replace the `<USER_EMAIL>` and `<PASSWORD>` fields in the `.apidays` file with your Confluent Cloud credentials. This file will be ignored by git.
4. Run the script appropriate to your choice of cloud provider. Eg: `./runme-aws`


# Going further
Confluent have a large number of examples available online. Visit https://github.com/confluentinc/examples