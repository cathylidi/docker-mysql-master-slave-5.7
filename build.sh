## Dependency check
# Maven
command -v mvn &> /dev/null || ( echo "Error: mvn not found" && exit 1 )
# Docker
command -v docker &> /dev/null || ( echo "Error: docker not found" && exit 1 )
# Docker Compose
command -v docker-compose &> /dev/null || ( echo "Error: docker-compose not found" && exit 1 )
## Var check
[[ -z "$GRAPH_CLIENT_ID" || -z "$GRAPH_CLIENT_SECRET" || -z "$GRAPH_TENANT_ID" ]] && echo "Error: GRAPH variables are not set. See Wiki." && exit 1

# Args/options parsing
[[ $1 = 'db' ]] && FULL_DEPLOY=0 || FULL_DEPLOY=1

## Build WAR file
cd ../dbv2/
mvn clean install -P local
[ $? -ne 0 ] && echo "Error: Maven build failed" && exit 1

## db Docker image
cd ../Local_Deployment
rm -vrf .Docker_local
cp -vr ../Docker/ .Docker_local

db_DB_TMPSECRETKEY_LOCAL=$(tr -cd A-Za-z0-9 < /dev/urandom | dd bs=25 count=1 2>/dev/null)
sed -i "s/placeholder.db.tmpsecretkey/$db_DB_TMPSECRETKEY_LOCAL/g" .Docker_local/serverInfo/serverinfo.properties
unset db_DB_TMPSECRETKEY_LOCAL

cp -v .Docker_local/server-local.xml .Docker_local/server.xml
cp -v ../dbv2_FE/target/dbv2_FE-0.1.war .Docker_local/db.war

# Replace the FROM ... to the version of the DockerHub
sed -i "s=gticloudopscontainerregistry.azurecr.io/tomcat:9-jdk=tomcat:9-jdk8=g" .Docker_local/Dockerfile

# Generate a self-signed SSL cert:
#echo "RUN keytool -genkey -alias local -keyalg RSA -keystore keystore.jks -keypass 'WMEhQ38qJj' -storepass 'WMEhQ38qJj' -noprompt -dname 'CN=my.server.com, OU=EastCoast, O=MyComp Ltd, L=New York, ST=, C=US'" >> .Docker_local/Dockerfile
# Keystore with our self-signed SSL cert is in /trustedcerts/keystore-local.jks already copied in the Dockerfile. Just move it to be the main keystore:
echo "RUN cp -v trustedcerts/keystore-local.jks keystore.jks" >> .Docker_local/Dockerfile

# Add line in the local Dockerfile to download the MS GraphAPI cert...
echo "RUN echo -n | openssl s_client -connect graph.microsoft.com:443 | sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' > trustedcerts/graphAPI.cert" >> .Docker_local/Dockerfile
# ... and add it to the keystore
echo "RUN keytool -import -keystore \$JAVA_HOME/jre/lib/security/cacerts -storepass 'changeit' -alias ms-graphapi -file trustedcerts/graphAPI.cert -noprompt" >> .Docker_local/Dockerfile

# For java debugging purpose.
echo "ENV JAVA_TOOL_OPTIONS -agentlib:jdwp=transport=dt_socket,address=8002,server=y,suspend=n" >> .Docker_local/Dockerfile

## MySQL Docker image'
rm -rf .MySQL_local && mkdir .MySQL_local

cp --verbose mysql.Dockerfile .MySQL_local/Dockerfile
cp --verbose mysql.Dockerfile .MySQL_local/Dockerfile-reader
cp --verbose ../sql/dbv2.sql .MySQL_local/dbv2.sql
cp --verbose ../sql/dbv2-triggers.sql .MySQL_local/dbv2-triggers.sql
cp --verbose ../sql/settings-local.sql .MySQL_local/settings-local.sql

## Docker compose: build & run
docker-compose build --no-cache mysql-db mysql-db-reader db mail-db
[ $? -ne 0 ] && echo "Error: Docker compose build failed" && exit 1

# If FULL_DEPLOY=0: redeploy only db and exit
[ $FULL_DEPLOY -eq 0 ] && docker-compose up -d --no-deps --build db \
                       && echo "db container build: SUCCESS" \
                       && notify-send "db container build finished successfully." \
                       && exit 0

# Else: deploy all containers
docker-compose up -d --force-recreate
[ $? -ne 0 ] && echo "Error: Docker compose up failed" && exit 1

echo "Deleting unused Docker images"
docker image prune -f

## MySQL setup

echo "Step1: SUCCESS"

until docker exec -it mysql-db bash -c 'mysql -u root -pPassword123 -e ";"'
do
    echo "Waiting for mysql-db database connection..."
    sleep 4
done

docker exec -it mysql-db bash -c "export MYSQL_PWD=Password123;mysql -u root <<-EOSQL
GRANT REPLICATION SLAVE ON *.* TO mydb_slave_user IDENTIFIED BY 'mydb_slave_pwd';
FLUSH PRIVILEGES;
EOSQL"
MS_STATUS=$(docker exec -it mysql-db bash -c 'export MYSQL_PWD=Password123;mysql -u root -e "SHOW MASTER STATUS"')
echo "$MS_STATUS"
CURRENT_LOG=$(echo "$MS_STATUS" | awk '/mysql/ {print $2}')
CURRENT_POS=$(echo "$MS_STATUS" | awk '/mysql/ {print $4}')

until docker exec -it mysql-db-reader bash -c 'mysql -u root -pPassword123 -e ";"'
do
    echo "Waiting for mysql-db-reader database connection..."
    sleep 4
done

docker-ip() {
    docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$@"
}
dbIP=$(echo $(docker-ip mysql-db))
change="MASTER_HOST='$dbIP',MASTER_USER='mydb_slave_user',MASTER_PASSWORD='mydb_slave_pwd',MASTER_LOG_FILE='$CURRENT_LOG',MASTER_LOG_POS=$CURRENT_POS"
echo $change

docker exec -it mysql-db-reader bash -c "export MYSQL_PWD=Password123;mysql -u root <<-EOSQL
CHANGE MASTER TO $change;
START SLAVE;
EOSQL"
docker exec -it mysql-db-reader bash -c 'export MYSQL_PWD=Password123;mysql -u root -e \"SHOW SLAVE STATUS\G;\"'

echo "Step2: SUCCESS"

echo "Importing database structure..."
docker exec mysql-db bash -c "mysql -pPassword123 -e 'drop database IF EXISTS myDB; create database myDB;'"
while [ $? -ne 0 ]
do
echo "Waiting for Mysql pod"
sleep 1
docker exec mysql-db bash -c "mysql -pPassword123 -e 'drop database IF EXISTS myDB; create database myDB;'"
done
docker exec mysql-db-reader bash -c "mysql -pPassword123 -e 'use myDB; SET GLOBAL log_bin_trust_function_creators = 1;'"
while [ $? -ne 0 ]
do
echo "Waiting for Mysql pod"
sleep 1
docker exec mysql-db-reader bash -c "mysql -pPassword123 -e 'use myDB; SET GLOBAL log_bin_trust_function_creators = 1;'"
done
docker exec mysql-db bash -c "mysql -pPassword123 -e 'use myDB; SET GLOBAL log_bin_trust_function_creators = 1;'"
while [ $? -ne 0 ]
do
echo "Waiting for Mysql pod"
sleep 1
docker exec mysql-db bash -c "mysql -pPassword123 -e 'use myDB; SET GLOBAL log_bin_trust_function_creators = 1;'"
done
docker exec mysql-db bash -c "mysql -pPassword123 < /dbv2/dbv2.sql"
while [ $? -ne 0 ]
do
echo "Waiting for Mysql pod"
sleep 1
docker exec mysql-db bash -c "mysql -pPassword123 < /dbv2/dbv2.sql"
done
docker exec mysql-db bash -c "mysql -pPassword123 < /dbv2/dbv2-triggers.sql"
while [ $? -ne 0 ]
do
echo "Waiting for Mysql pod"
sleep 1
docker exec mysql-db bash -c "mysql -pPassword123 < /dbv2/dbv2-triggers.sql"
done
echo "Importing data..."
docker exec mysql-db bash -c "mysql -pPassword123 < /dbv2/settings-local.sql"
while [ $? -ne 0 ]
do
echo "Waiting for Mysql pod"
sleep 1
docker exec mysql-db bash -c "mysql -pPassword123 < /dbv2/settings-local.sql"
done
echo "Local build: SUCCESS"
notify-send "Local build finished successfully."
