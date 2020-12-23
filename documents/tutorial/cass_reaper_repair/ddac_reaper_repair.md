- [1. Overview](#1-overview)
  - [1.1. Background Introduction](#11-background-introduction)
  - [1.2. Full Repair, Primary-Range Repair, and Sub-Range Repair](#12-full-repair-primary-range-repair-and-sub-range-repair)
- [2. Introduction to Cassandra Reaper (Reaper)](#2-introduction-to-cassandra-reaper-reaper)
  - [2.1. Installation](#21-installation)
  - [2.2. Access](#22-access)
    - [2.2.1. Web UI](#221-web-ui)
    - [2.2.2. CLI and Rest API](#222-cli-and-rest-api)
  - [2.3. Backend Storage](#23-backend-storage)
- [3. DDAC(C*) Cluster Configuration](#3-ddacc-cluster-configuration)
  - [3.1. Cassandra Authentication and Client-to-Server SSL (as both storage cluster and monitored cluster)](#31-cassandra-authentication-and-client-to-server-ssl-as-both-storage-cluster-and-monitored-cluster)
  - [3.2. JMX Authentication and SSL Configuration (as monitored cluster)](#32-jmx-authentication-and-ssl-configuration-as-monitored-cluster)
  - [3.3. DDAC (C*) Connection Verification via "cqlsh" and "nodetool"](#33-ddac-c-connection-verification-via-cqlsh-and-nodetool)
- [4. Configure Reaper with DDAC(C*)](#4-configure-reaper-with-ddacc)
  - [4.1. Main Configuration File : **cassandra-reaper.yaml**](#41-main-configuration-file--cassandra-reaperyaml)
  - [4.2. Create Dedicated C* Keyspace for Reaper](#42-create-dedicated-c-keyspace-for-reaper)
  - [4.3. SSL Configuration for JMX and DDAC(C*) Connection](#43-ssl-configuration-for-jmx-and-ddacc-connection)
  - [4.4. Verify Reaper (Native CQL) Connection to the Backend Storage DDAC(C*) Cluster](#44-verify-reaper-native-cql-connection-to-the-backend-storage-ddacc-cluster)
  - [4.5. Verify Reaper (JMX) Connection to a Monitored DDAC(C*) Cluster](#45-verify-reaper-jmx-connection-to-a-monitored-ddacc-cluster)

# 1. Overview 

## 1.1. Background Introduction

DataStax has announced DDAC (DataStax Distribution of Apache Cassandra) in late 2018 as a "a new subscription offering designed for running a certified version of open source Apache Cassandra (C*) for development and production use cases that do not have the higher enterprise demands better served by [DataStax Enterprise](https://www.datastax.com/products/datastax-enterprise).

Since DDAC is designed as a "supported **OSS** C*", it doesn't have the enterprise features as offered in DSE. It also can't utilize other enterprise-oriented DSE tools like [DataStax OpsCenter](https://www.datastax.com/products/datastax-opscenter). This means that when using DDAC, we can't utilize all features as provided by OpsCenter for cluster operation management, metrics monitoring and dashboarding, advanced services like for backup or repair, and so on. 

Because of this, for DDAC users, they need to fall back to the basic, command-line based features as provided out of the box of OSS C*. For example, if they want to run a repair against the cluster, they have to run "nodetool repair" command somehow on each of the nodes in the cluster. This is a manual process and usually it can take a long time to finish repairing the entire cluster when the data size is not small.

## 1.2. Full Repair, Primary-Range Repair, and Sub-Range Repair

**Full Repair** 

When running "nodetool repair" command, by default it is running a full repair, which means on the node where the command runs, it will repair both primary-range data and secondary-range data. Primary-range data means the data is owned by this node by the calculation of the partitioning hash function. Secondary-range data means the replica data that is replicated from other nodes.

When executing the full repair on each node of the cluster (an entire repair cycle), it means that the same data has been repaired RF times (RF means the replication factor). This makes full repair resource-heavy and time-consuming.

**Primary-Range Repair**

In order to reduce the impact of a full repair, we can run the repair via "nodetool repair -pr" command. The "-pr" option means when doing repair on a node, it is only going to focus on primary-range data, but not on secondary-range data. Because of this, when we execute an entire repair cycle (on each node of the cluster), there is no "duplicate" repair of data; and is therefore faster and less resource consuming as compared to the full repair. 

One thing that needs to pay attention to here is when taking this approach, the primary-range repair command has to be executed on every node of the cluster in order to make sure the entire data set is repaired. 

For full repair, technically speaking, as long as the command is executed on (N - RF + 1) nodes (N is the number of nodes in the cluster and RF is the replication factor), the entire data set is repaired. 

**Sub-Range Repair**

Sub-range repair is achieved by executing "nodetool repair -st <starting_token> -et <ending_token>". Using sub-range repair can further limit the scope of each repair session by providing a smaller range of tokens as compared to the whole (primary) range of data. Concurrent repair on different sub-ranges of data is also possible. Because of this, sub-range repair can be less resource consuming and more flexible. But meanwhile, in order to complete the repair on the entire data set, a schedule needs to be established to divide the data into a complete list of sub-ranges and make sure each sub-range is repaired. 

---

DataStax OpsCenter repair service is based on sub-range repair and handles the sub-range management and scheduling automatically.


# 2. Introduction to Cassandra Reaper (Reaper)

[Cassandra Reaper](http://cassandra-reaper.io/) { GitHub Code [here](https://github.com/thelastpickle/cassandra-reaper) } is an open source effort that tries to simplify and automate C* repair, providing a functionality that is similar to what DataStax OpsCenter repair service offers. It was originally developed by [Spotify](https://www.spotify.com/us/) and is now taken over by [The Last Pickle](https://thelastpickle.com/) for active development and/or maintenance.

Please note that compared with Cassandra Reaper, DataStax OpsCenter is a far more advanced product for many tasks of different purposes such as metrics monitoring, dashboarding, alerting, cluster management and operation like node start/stop, token balance, backup/restore, repair, performance tuning, and so on. 

The sole purpose of Cassandra Reaper is for C* data repair management and automation. Like DataStax OpsCenter repair service, it is also based on sub-range repair. 

## 2.1. Installation

This section describes the method of how to install Reaper (as a service) on Debian based Linux systems like Ubuntu). For other installation methods, please refer to Reaper's official document.

```
echo "deb https://dl.bintray.com/thelastpickle/reaper-deb wheezy main" | sudo tee -a /etc/apt/sources.list
sudo apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 2895100917357435
sudo apt-get update
sudo apt-get install reaper
```

The APT package installation creates a service named **cassandra-reaper** and an OS service user, **reaper**. We can start, stop, or check status of this service using the following commands:

```
sudo service cassandra-reaper [start|stop|status]
```

The Reaper server program is java based and by default it is allocated with 2GB heap size. If it is needed to increase the heap size, we can modify the following JVM options (in particular -Xms and -Xmx options) in file ***/usr/local/bin/cassandra-reaper***.
```
JVM_OPTS=(
    -ea
    -Xms2G
    -Xmx2G
    # Prefer binding to IPv4 network interfaces (when net.ipv6.bindv6only=1). See
    # http://bugs.sun.com/bugdatabase/view_bug.do?bug_id=6342561 (short version:
    # comment out this entry to enable IPv6 support).
    -Djava.net.preferIPv4Stack=true
    )
```

## 2.2. Access

### 2.2.1. Web UI

Once the service is started, we can access Reaper web UI from the following URL:
```
http://<IP_address>:8080/webui/
```

By default, Reaper has authentication enabled. So when we access the above web UI for the first time, the landing page of the  web UI is the login page. A default username/password combination, ***admin/admin*** or ***user/user*** can be used for login purposes.

Please NOTE that Reaper authentication is based on [Apache Shiro](https://shiro.apache.org/). So more advanced security features like LDAP integration, password encryption, and etc. are also possible with Reaper. For production deployment and/or for more advanced security features, we should customize **shiro.ini** file (and put it under folder /etc/cassandra-reaper). A template file can be found from Reaper GitHub repo [here](https://github.com/thelastpickle/cassandra-reaper/blob/master/src/server/src/main/resources/shiro.ini). The detailed discussion of these features, however, is beyond the scope of this document. Please refer to [Shiro's documentation](https://shiro.apache.org/documentation.html) for more info.

### 2.2.2. CLI and Rest API

All functionalities as exposed by Reaper Web UI can also be accessed via a CLI tool, **spreaper** (e.g. /usr/local/bin/spreaper), as provided out of the box of Reaper installation.

**spreaper** utility is a python wrapper program around Reaper's Rest APIs. The detailed description of the APIs can be found [here](http://cassandra-reaper.io/docs/api/).

## 2.3. Backend Storage

The main configuration file for Reaper is file **cassandra-reaper.yaml** (*/etc/cassandra-reaper/cassandra-reaper.yaml*). There are several templates of this file that are provided out of the box (that can be found under folder ***/etc/cassandra-reaper/configs/***). The templates are based on Reaper's backend storage type. 

Reaper can use the following storage types as its backend mechanism:
* In-memory (default)
* H2
* Postgres
* Cassandra

In this document, we'll focus on how to use Cassandra as the backend storage. 


# 3. DDAC(C*) Cluster Configuration

For simplicity purpose, in my test, I'm using the same DDAC (C*) cluster that Reaper is going to manage for repair as Reaper's own backend C* storage cluster. Practically speaking, it is recommended to use a separate DDAC (C*) cluster.

The DDAC(C*) cluster used in my test has the following security features enabled:
* JMX authentication 
* JMX SSL
* C* (internal) authentication
* C* client-to-server SSL encryption

These security features are purposely chosen in order to test the connection between Reaper and DDAC(C*), both as a storage backend storage cluster and a managed cluster.

## 3.1. Cassandra Authentication and Client-to-Server SSL (as both storage cluster and monitored cluster)

The following security features in **cassandra.yaml** file have been enabled for the DDAC (C*) cluster:

```
# Authentication
authenticator: PasswordAuthenticator

# Client-to-Server SSL
client_encryption_options:
    enabled: true
    optional: false
    keystore: <keystore_file_path>
    keystore_password: <keystore_password>
```

When Reaper chooses to use this DDAC(C*) cluster as its backend storage, its connection to the cluster is enforced by the above security settings (esp. Authentication and Client-to-Server SSL)


## 3.2. JMX Authentication and SSL Configuration (as monitored cluster)

Reaper uses JMX to manage DDAC(C*) clusters for repair. Because of this, each DDAC(C*) cluster needs to have remote JMX enabled, which in turn has JMX authentication enabled by default. It is also recommended to have JMX SSL enabled in order to encrypt in-flight JMX communication.

The JMX security settings are enabled in **cassandra-envs.sh** file, as below:

```
### Remote JMX
LOCAL_JMX=no
JVM_OPTS="$JVM_OPTS -Dcassandra.jmx.remote.port=$JMX_PORT"
JVM_OPTS="$JVM_OPTS -Dcom.sun.management.jmxremote.rmi.port=$JMX_PORT"

### JMX Authentication (via C* Auth.)
JVM_OPTS="$JVM_OPTS -Dcom.sun.management.jmxremote.authenticate=true"
JVM_OPTS="$JVM_OPTS -Dcassandra.jmx.remote.login.config=CassandraLogin"
JVM_OPTS="$JVM_OPTS -Djava.security.auth.login.config=$CASSANDRA_HOME/conf/cassandra-jaas.config" 

### JMX SSL
JVM_OPTS="$JVM_OPTS -Dcom.sun.management.jmxremote.ssl=true"
#JVM_OPTS="$JVM_OPTS -Dcom.sun.management.jmxremote.ssl.need.client.auth=true"
#JVM_OPTS="$JVM_OPTS -Dcom.sun.management.jmxremote.ssl.enabled.protocols=<enabled-protocols>"
#JVM_OPTS="$JVM_OPTS -Dcom.sun.management.jmxremote.ssl.enabled.cipher.suites=<enabled-cipher-suites>"
JVM_OPTS="$JVM_OPTS -Djavax.net.ssl.keyStore=<keystore_file_path>"
JVM_OPTS="$JVM_OPTS -Djavax.net.ssl.keyStorePassword=<keystore_password>"
JVM_OPTS="$JVM_OPTS -Djavax.net.ssl.trustStore=<truststore_file_path>"
JVM_OPTS="$JVM_OPTS -Djavax.net.ssl.trustStorePassword=<truststore_password>"
```

Please **NOTE** that the above setting achieves JMX authentication NOT through regular file based JMX authentication; but instead it is through DDAC (C*)'s internal authentication.  

## 3.3. DDAC (C*) Connection Verification via "cqlsh" and "nodetool"

Before using Reaper to connect (and monitor) the DDAC (C*) cluster with the above settings, let's first use **cqlsh** and **nodetool** utilities (against a remote C* node) first for connection verification purposes. 

1) Verify **cqlsh** connection to the DDAC(C*) cluster

First, add the following section in ***~/.cassandra/cqlshrc*** file.
```
[ssl]
certfile = <file_path_of_self_singed_rootca_certificate>
validate = true
```

Then, verify CQLSH connection via the following command. If connected successfully, CQLSH command line will show up, an example of which is as below.
```
$ cqlsh <node_name_or_ip> --ssl -u <C*_user_name> -p <C*_user_password>
Connected to MyTestCluster at node0:9042.
[cqlsh 5.0.1 | Cassandra 3.11.3.5116 | CQL spec 3.4.4 | Native protocol v4]
Use HELP for help.
cassandra@cqlsh>
```

2) Verify **nodetool** connection to the DDAC(C*) cluster

First, create a file **~/.cassandra/nodetool-ssl.properties** with the following content
```
-Djavax.net.ssl.trustStore=<file_path_to_truststore>"
-Djavax.net.ssl.trustStorePassword=<truststore_password>"
```

Then, verify the "nodetool status" command (JMX connection) via the following command. If connected successfully, the proper DDAC(C*) cluster status is returned.
```
$ nodetool -h <node_name_or_ip> --ssl -u <C*_user_name> -pw <C*_user_password> status
```

Please NOTE that in the above command, C* username/password is used. This is because our JMX authentication is delegated to using DDA(C*) authentication.


# 4. Configure Reaper with DDAC(C*)

## 4.1. Main Configuration File : **cassandra-reaper.yaml**

As mentioned earlier, the main Reaper configuration file is **cassandra-reaper.yaml** (e.g. /etc/cassandra-reaper/cassandra-reaper.yaml) and the default one is for using memory as the backend storage type. For our case, since we're using DDAC(C*) as the storage backend with SSL enabled, we should change the main configuration file accordingly. 

1) Copy the configuration template file for C* backend (with SSL)
```
$ cd /etc/cassandra-reaper
$ cp configs/cassandra-reaper-cassandra-ssl.yaml cassandra-reaper.yaml
```

2) Make corresponding changes in the following sections in "cassandra-reaper.yaml"
```
jmxAuth:
  username: <jmx_user_name>
  password: <jmx_user_password>

cassandra:
  clusterName: "<storage_C*_cluster_name>"
  contactPoints: ["<storage_node1_ip>", "<storage_node2_ip>", ....]
  keyspace: reaper_db
  loadBalancingPolicy:
    type: tokenAware
    shuffleReplicas: true
    subPolicy:
      type: dcAwareRoundRobin
      localDC: <local_DC_name>
      usedHostsPerRemoteDC: 0
      allowRemoteDCsForLocalConsistencyLevel: false
  authProvider:
    type: plainText
    username: <C*_user_name>
    password: <C*_user_password>
  ssl:
    type: jdk
```

## 4.2. Create Dedicated C* Keyspace for Reaper

In the above settings, a dedicated C* keyspace, **reapder_db**, has been specified to hold Reaper data in C* tables. In order to make Reaper connecting to DDAC(C*) cluster properly, this keyspace needs to be specified in advance.

Log into the CQLSH command line on any DDAC(C*) node (as Reaper storage backend) and execute a command similar to the below:
```
CREATE KEYSPACE reaper_db WITH replication = {'class': 'NetworkTopologyStrategy', '<DC_name>': '<RF_num>', ...}  AND durable_writes = true;
```

## 4.3. SSL Configuration for JMX and DDAC(C*) Connection

Since the DDAC(C*) cluster has client-to-server SSL and JMX SSL enabled, we also need to specify the keystore/truststore file and password for proper connection. Unfortunately, at the moment, there is no way to specify this information in the main configuration file. They have to be specified as JVM options directly, by modifying  **/usr/local/bin/cassandra-reaper** file and adding the following SSL related JVM options.
```
JVM_OPTS=(
    -ea
    -Xms2G
    -Xmx2G
    # Prefer binding to IPv4 network intefaces (when net.ipv6.bindv6only=1). See
    # http://bugs.sun.com/bugdatabase/view_bug.do?bug_id=6342561 (short version:
    # comment out this entry to enable IPv6 support).
    -Djava.net.preferIPv4Stack=true

    # SSL
    -Dssl.enable=true
    -Djavax.net.ssl.trustStore=<truststore_file_path>
    -Djavax.net.ssl.trustStorePassword=<truststore_password>
    )
```

## 4.4. Verify Reaper (Native CQL) Connection to the Backend Storage DDAC(C*) Cluster

Once the above settings have been made, restart **cassandra-reaper** service and make sure the OS process is indeed started up and running. Please note that if the Reaper connection to the backend DDAC(C*) cluster is somehow NOT successful (e.g. wrong C* username/password), the OS process for **cassandra-reaper** service will not start, and you won't see any error message in Reaper's log file (e.g. /var/log/cassandra-reaper/reaper.log). So a convenient way to check the connection between Reaper and the backend storage DDAC(C*) cluster is to see whether the OS process for Reaper service is up and running via "ps" command.

In order to further verify Reaper connection to the backend storage DDAC(C*) cluster, we can also log in to a DDAC (C*) node and run the following CQLSH command to see if various C* tables are created successfully under **reaper_db** keyspace. If the connection is good, starting Reaper service for the first time will create these tables.
```
DESCRIBE KEYSPACE reaper_db;
```

## 4.5. Verify Reaper (JMX) Connection to a Monitored DDAC(C*) Cluster

In order to verify Reaper (JMX) connection to the managed DDAC(C*) cluster, we can try adding a managed cluster from Reaper WebUI. This is because as I mentioned earlier, Reaper achieves its functionality of cluster management, repair, and etc. through JMX functions as exposed by the managed DDAC(C*) cluster.

The screenshot below shows how to add a managed C* cluster from the Reaper WebUI. If we can successfully add a managed cluster, that means JMX connection is good.

![Adding a Cluster](https://github.com/yabinmeng/dseutilities/blob/master/documents/tutorial/cass_reaper_repair/resources/adding_cluster.png)




