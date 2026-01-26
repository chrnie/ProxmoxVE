#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: chrnie
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://icinga.com/

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

DIST=$(awk -F"[)(]+" '/VERSION=/ {print $2}' /etc/os-release)
FQDN=$(hostname -f)

msg_info "Setting up Icinga Repository"
wget -O icinga-archive-keyring.deb "https://packages.icinga.com/icinga-archive-keyring_latest+debian$(
 . /etc/os-release; echo "$VERSION_ID"
).deb" || { msg_error "Failed to download Icinga archive keyring"; exit 1; }
apt install -y ./icinga-archive-keyring.deb || { msg_error "Failed to install Icinga archive keyring"; exit 1; }
echo "deb [signed-by=/usr/share/keyrings/icinga-archive-keyring.gpg] https://packages.icinga.com/debian icinga-${DIST} main" > \
 /etc/apt/sources.list.d/${DIST}-icinga.list || { msg_error "Failed to add Icinga repository"; exit 1; }
msg_ok "Set up Icinga Repository"

msg_info "Adding Netways extras and plugins repository"
wget -O - https://packages.netways.de/netways-repo.asc | gpg --dearmor > /etc/apt/keyrings/netways.gpg || { msg_error "Failed to add Netways GPG key"; exit 1; }

echo "deb [signed-by=/etc/apt/keyrings/netways.gpg] https://packages.netways.de/extras/debian ${DIST} main" > /etc/apt/sources.list.d/netways-extras.list || { msg_error "Failed to add Netways extras repository"; exit 1; }
echo "deb [signed-by=/etc/apt/keyrings/netways.gpg] https://packages.netways.de/plugins/debian ${DIST} main" > /etc/apt/sources.list.d/netways-plugins.list || { msg_error "Failed to add Netways plugins repository"; exit 1; }
msg_ok "Set up Netways Repositories"


msg_info "Adding Linuxfabrik plugins repository"
mkdir -p /etc/apt/keyrings || { msg_error "Failed to create /etc/apt/keyrings directory"; exit 1; }
wget https://repo.linuxfabrik.ch/linuxfabrik.key --output-document=/etc/apt/keyrings/linuxfabrik.asc || { msg_error "Failed to download Linuxfabrik GPG key"; exit 1; }
source /etc/os-release
echo "deb [signed-by=/etc/apt/keyrings/linuxfabrik.asc] https://repo.linuxfabrik.ch/monitoring-plugins/debian/ $VERSION_CODENAME-release main" > /etc/apt/sources.list.d/linuxfabrik-monitoring-plugins.list || { msg_error "Failed to add Linuxfabrik repository"; exit 1; }
msg_ok "Set up Linuxfabrik plugins repository"

msg_info "Installing Icinga"
apt-get update -qq || { msg_error "Failed to update package manager"; exit 1; }
apt-get install -y -qq \
  icinga2 icingaweb2 icingadb icingadb-redis \
  pwgen imagemagick php-imagick \
  apache2 mariadb-server openssh-server \
  icingadb-web icinga-director icinga-businessprocess \
  icinga-cube icinga-notifications-web icinga-notifications icinga-x509 \
  icingaweb2-module-reporting \
  icingaweb2-module-perfdatagraphs-influxdbv1 \
  icingaweb2-module-perfdatagraphs-influxdbv2 \
  icingaweb2-module-perfdatagraphs \
  linuxfabrik-monitoring-plugins \
  vim git redis-tools || { msg_error "Failed to install Icinga packages"; exit 1; }


# Disable Apache default site and redirect / to /icingaweb2
a2dissite 000-default.conf || msg_error "Warning: Failed to disable default Apache site"
cat <<EOF >/etc/apache2/sites-available/icingaweb2-redirect.conf || { msg_error "Failed to create Apache configuration"; exit 1; }
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    DocumentRoot /usr/share/icingaweb2/public
    RedirectMatch ^/$ /icingaweb2/
</VirtualHost>
EOF
a2ensite icingaweb2-redirect.conf || { msg_error "Failed to enable Apache site"; exit 1; }
msg_ok "Installed Apache and configured Icinga Web 2 redirect"
systemctl reload apache2 || { msg_error "Failed to reload Apache"; exit 1; }

# Enable and start services
systemctl enable icinga2 apache2 mariadb --now || { msg_error "Failed to enable and start services"; exit 1; }
msg_ok "Installed Icinga"

msg_info "Configuring Icinga"

# Generate random passwords if not set
ICINGA_DB_PW="${ICINGA_DB_PW:-$(pwgen -s 20 1)}"
ICINGAWEB_DB_PW="${ICINGAWEB_DB_PW:-$(pwgen -s 20 1)}"
NOTIFICATIONS_DB_PW="${NOTIFICATIONS_DB_PW:-$(pwgen -s 20 1)}"
DIRECTOR_DB_PW="${DIRECTOR_DB_PW:-$(pwgen -s 20 1)}"
X509_DB_PW="${X509_DB_PW:-$(pwgen -s 20 1)}"
REPORTING_DB_PW="${REPORTING_DB_PW:-$(pwgen -s 20 1)}"
ICINGAWEB_ADMIN_PW="${ICINGAWEB_ADMIN_PW:-$(pwgen -s 12 1)}"


cat <<EOF | mysql -u root || { msg_error "Failed to create databases"; exit 1; }
CREATE DATABASE IF NOT EXISTS icingadb;
CREATE DATABASE IF NOT EXISTS icingaweb;
CREATE DATABASE IF NOT EXISTS notifications;
CREATE DATABASE IF NOT EXISTS director CHARACTER SET 'utf8';
CREATE DATABASE IF NOT EXISTS x509;
CREATE DATABASE IF NOT EXISTS reporting;
CREATE USER IF NOT EXISTS 'icingadb'@'localhost' IDENTIFIED BY '${ICINGA_DB_PW}';
CREATE USER IF NOT EXISTS 'icingaweb'@'localhost' IDENTIFIED BY '${ICINGAWEB_DB_PW}';
CREATE USER IF NOT EXISTS 'notifications'@'localhost' IDENTIFIED BY '${NOTIFICATIONS_DB_PW}';
CREATE USER IF NOT EXISTS 'director'@'localhost' IDENTIFIED BY '${DIRECTOR_DB_PW}';
CREATE USER IF NOT EXISTS 'x509'@'localhost' IDENTIFIED BY '${X509_DB_PW}';
CREATE USER IF NOT EXISTS 'reporting'@'localhost' IDENTIFIED BY '${REPORTING_DB_PW}';
GRANT ALL PRIVILEGES ON icingadb.* TO 'icingadb'@'localhost';
GRANT ALL PRIVILEGES ON icingaweb.* TO 'icingaweb'@'localhost';
GRANT ALL PRIVILEGES ON notifications.* TO 'notifications'@'localhost';
GRANT ALL PRIVILEGES ON director.* TO 'director'@'localhost';
GRANT ALL PRIVILEGES ON x509.* TO 'x509'@'localhost';
GRANT ALL PRIVILEGES ON reporting.* TO 'reporting'@'localhost';
FLUSH PRIVILEGES;
EOF
msg_ok "Configured MariaDB databases and users"
mysql icingadb </usr/share/icingadb/schema/mysql/schema.sql || { msg_error "Failed to import IcingaDB schema"; exit 1; }
msg_ok "Imported IcingaDB schema"

sed -i "s/password: CHANGEME/password: ${ICINGA_DB_PW}/g" /etc/icingadb/config.yml || { msg_error "Failed to configure IcingaDB password"; exit 1; }
systemctl enable icingadb-redis icingadb --now || { msg_error "Failed to enable IcingaDB services"; exit 1; }
systemctl restart icingadb || { msg_error "Failed to restart IcingaDB"; exit 1; }
msg_ok "Configured IcingaDB daemon connection to mysql database"

icinga2 node setup --master --disable-confd || { msg_error "Failed to setup Icinga2 node"; exit 1; }
icinga2 feature enable icingadb || { msg_error "Failed to enable Icinga2 IcingaDB feature"; exit 1; }
ICINGA_API_ROOT_PW=$(grep 'password' /etc/icinga2/conf.d/api-users.conf | sed 's/.*password = \"//;s/"$//') || { msg_error "Failed to retrieve Icinga API password"; exit 1; }
systemctl restart icinga2 || { msg_error "Failed to restart Icinga2"; exit 1; }
msg_ok "Configured Icinga2 API"

cat <<EOF >/etc/icingaweb2/config.ini
[global]
show_stacktraces = "1"
show_application_state_messages = "1"
config_resource = "icingaweb_db"

[security]
use_strict_csp = "0"

[logging]
log = "syslog"
level = "ERROR"
application = "icingaweb2"
facility = "user"
EOF
msg_ok "Created Icinga Web 2 config.ini"

cat <<EOF >/etc/icingaweb2/authentication.ini
[icingaweb2]
backend = "db"
resource = "icingaweb_db"
EOF

cat <<EOF >/etc/icingaweb2/groups.ini
[icingaweb2]
backend = "db"
resource = "icingaweb_db"
EOF

cat <<EOF >/etc/icingaweb2/roles.ini
[Administrators]
users = "icingaadmin"
permissions = "*"
groups = "Administrators"
EOF
msg_ok "Created Icinga Web 2 authentication, groups, and roles ini files"

cat <<EOF >/etc/icingaweb2/resources.ini
[icingaweb_db]
type = "db"
db = "mysql"
host = "localhost"
dbname = "icingaweb"
username = "icingaweb"
password = "$ICINGAWEB_DB_PW"
use_ssl = "0"

[icingadb]
type = "db"
skip_validation = "0"
db = "mysql"
host = "localhost"
dbname = "icingadb"
username = "icingadb"
password = "$ICINGA_DB_PW"
charset = "utf8mb4"
use_ssl = "0"

[director_db]
type = "db"
db = "mysql"
host = "localhost"
dbname = "director"
username = "director"
password = "$DIRECTOR_DB_PW"
charset = "utf8"
use_ssl = "0"

[notifications]
type = "db"
db = "mysql"
host = "localhost"
dbname = "notifications"
username = "notifications"
password = "$NOTIFICATIONS_DB_PW"
use_ssl = "0"

[reporting_db]
type = "db"
db = "mysql"
host = "localhost"
dbname = "reporting"
username = "reporting"
password = "$REPORTING_DB_PW"
use_ssl = "0"

[x509_db]
type = "db"
db = "mysql"
host = "localhost"
dbname = "x509"
username = "x509"
password = "$X509_DB_PW"
use_ssl = "0"
EOF

chown www-data:icingaweb2 /etc/icingaweb2/*.ini || { msg_error "Failed to set permissions on Icinga Web 2 config files"; exit 1; }
chmod 660 /etc/icingaweb2/*.ini || { msg_error "Failed to set permissions on Icinga Web 2 config files"; exit 1; }
msg_ok "Created Icinga Web 2 resources.ini"

icingacli module enable director || { msg_error "Failed to enable director module"; exit 1; }
mkdir -p /etc/icingaweb2/modules/director || { msg_error "Failed to create director module directory"; exit 1; }
cat <<EOF >/etc/icingaweb2/modules/director/config.ini || { msg_error "Failed to create director config.ini"; exit 1; }
[db]
resource = "director_db"
EOF
cat <<EOF >>/etc/icingaweb2/modules/director/kickstart.ini || { msg_error "Failed to create director kickstart.ini"; exit 1; }
[config]
endpoint = $FQDN
host = 127.0.0.1
port = 5665
username = root
password = $ICINGA_API_ROOT_PW
EOF
chown -R root:icingaweb2 /etc/icingaweb2/modules/director || { msg_error "Failed to set director permissions"; exit 1; }
chmod 660 /etc/icingaweb2/modules/director/*.ini || { msg_error "Failed to set director file permissions"; exit 1; }
icingacli director migration run || { msg_error "Failed to run director migration"; exit 1; }
icingacli director kickstart run || { msg_error "Failed to run director kickstart"; exit 1; }
systemctl reload icinga-director.service || { msg_error "Failed to reload Icinga Director"; exit 1; }
msg_ok "Configured Icinga Director module"

icingacli module enable icingadb || { msg_error "Failed to enable icingadb module"; exit 1; }
mkdir -p /etc/icingaweb2/modules/icingadb || { msg_error "Failed to create icingadb module directory"; exit 1; }
cat <<EOF >>/etc/icingaweb2/modules/icingadb/commandtransports.ini || { msg_error "Failed to create commandtransports.ini"; exit 1; } 
[icinga2]
skip_validation = "0"
transport = "api"
host = "localhost"
port = "5665"
username = "root"
password = "$ICINGA_API_ROOT_PW"
EOF

cat <<EOF >/etc/icingaweb2/modules/icingadb/config.ini
[icingadb]
resource = "icingadb"

[redis]
tls = "0"
EOF
 
cat <<EOF >/etc/icingaweb2/modules/icingadb/redis.ini
[redis1]
host = "localhost"
EOF
chown -R root:icingaweb2 /etc/icingaweb2/modules/icingadb || { msg_error "Failed to set icingadb permissions"; exit 1; }
chmod 660 /etc/icingaweb2/modules/icingadb/*.ini || { msg_error "Failed to set icingadb file permissions"; exit 1; }
msg_ok "Configured IcingaDB module"


mkdir -p /etc/icingaweb2/modules/reporting || { msg_error "Failed to create reporting module directory"; exit 1; }
cat <<EOF > /etc/icingaweb2/modules/reporting/config.ini || { msg_error "Failed to create reporting config"; exit 1; }
[backend]
resource = "reporting_db"
EOF

chown -R root:icingaweb2 /etc/icingaweb2/modules/reporting || { msg_error "Failed to set reporting permissions"; exit 1; }
chmod 660 /etc/icingaweb2/modules/reporting/config.ini || { msg_error "Failed to set reporting file permissions"; exit 1; }
mysql reporting < /usr/share/icingaweb2/modules/reporting/schema/mysql.schema.sql || { msg_error "Failed to import reporting schema"; exit 1; }
mysql x509 < /usr/share/icingaweb2/modules/x509/schema/mysql.schema.sql || { msg_error "Failed to import x509 schema"; exit 1; }
msg_ok "Configured Reporting module"

mkdir -p /etc/icingaweb2/modules/x509 || { msg_error "Failed to create x509 module directory"; exit 1; }
cat <<EOF > /etc/icingaweb2/modules/x509/config.ini || { msg_error "Failed to create x509 config"; exit 1; }
[backend]
resource = "x509_db"
EOF
chown -R root:icingaweb2 /etc/icingaweb2/modules/x509 || { msg_error "Failed to set x509 permissions"; exit 1; }
chmod 660 /etc/icingaweb2/modules/x509/config.ini || { msg_error "Failed to set x509 file permissions"; exit 1; }
icingacli module enable x509 || { msg_error "Failed to enable x509 module"; exit 1; }


# Ask for before adding LAN network job
while true; do
    read -rp "Add a network to the x509 certificate module[Y/n]: " X509_LAN_CIDR
    X509_LAN_CIDR=${X509_LAN_CIDR:-y}
    if [[ "$X509_LAN_CIDR" == "y" ]]; then
        SUGGESTED_CIDR=$(ip r|grep link|grep -Po "^[\S]*"| head -n1)
        while true; do
            read -rp "Network cidr [$SUGGESTED_CIDR]: " X509_LAN_CIDR
            X509_LAN_CIDR=${X509_LAN_CIDR:-$SUGGESTED_CIDR}
            if [[ "$X509_LAN_CIDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
                break
            else
                echo "Error: '$X509_LAN_CIDR' is not a valid CIDR format."
                echo "Error: aaa.bbb.ccc.ddd/xy expected."
            fi
            break
        done

        X509_START_SCHEDULE=$(TZ="Europe/Paris" date -d "+1 minutes" +"%Y-%m-%dT%H:%M:%S.000000") || { msg_error "Failed to calculate X509 start schedule"; exit 1; }
        cat <<EOF > /etc/icingaweb2/modules/x509/jobs.ini || { msg_error "Failed to create x509 jobs.ini"; exit 1; }
[LAN]
cidrs = "$X509_LAN_CIDR"
ports = "443"
schedule = "{\"rrule\":\"FREQ=DAILY\",\"frequency\":\"DAILY\",\"start\":\"${X509_START_SCHEDULE}Europe\\/Paris\"}"
frequencyType = "ipl\\Scheduler\\RRule"
EOF
        chmod 660 /etc/icingaweb2/modules/x509/config.ini || { msg_error "Failed to set x509 jobs.ini permissions"; exit 1; }
        icingacli x509 migrate --author "proxmox init" --verbose || { msg_error "Failed to migrate x509 module"; exit 1; }
        systemctl restart icinga-x509.service
        # Add basket with x509 automations
        icingacli director basket restore <<EOF || { msg_error "Failed to restore x509 basket"; exit 1; }
{
    "ExternalCommand": {
        "icingacli-x509": {
            "arguments": {
                "--allow-self-signed": {
                    "description": "Ignore if a certificate or its issuer has been self-signed",
                    "set_if": "$icingacli_x509_allow_self_signed$"
                },
                "--critical": {
                    "description": "Less remaining time results in state CRITICAL",
                    "value": "$icingacli_x509_critical$"
                },
                "--host": {
                    "description": "A hosts name",
                    "value": "$icingacli_x509_host$"
                },
                "--ip": {
                    "description": "A hosts IP address",
                    "value": "$icingacli_x509_ip$"
                },
                "--port": {
                    "description": "The port to check in particular",
                    "value": "$icingacli_x509_port$"
                },
                "--warning": {
                    "description": "Less remaining time results in state WARNING",
                    "value": "$icingacli_x509_warning$"
                }
            },
            "command": "/usr/bin/icingacli x509 check host",
            "fields": [
                {
                    "datafield_id": 1881,
                    "is_required": "n",
                    "var_filter": null
                }
            ],
            "methods_execute": "PluginCheck",
            "object_name": "icingacli-x509",
            "object_type": "external_object",
            "timeout": 60,
            "uuid": "4c11d751-9a59-4b8c-88d9-3357c64fe57e"
        }
    },
    "ServiceTemplate": {
        "tpl-service-x509-cert": {
            "check_command": "icingacli-x509",
            "fields": [],
            "imports": [
                "tpl-service-generic"
            ],
            "object_name": "tpl-service-x509-cert",
            "object_type": "template",
            "use_agent": false,
            "uuid": "fcf7dad8-091b-4c1d-998d-2f077d97fcf4",
            "vars": {
                "criticality": "B",
                "icingacli_x509_host": "$host.name$"
            }
        }
    },
    "ServiceSet": {
        "Certificate x509 Module": {
            "assign_filter": "\"x509-certs\"=host.vars.tags",
            "description": "checks the certificate state agains the internal database, using icingacli",
            "object_name": "Certificate x509 Module",
            "object_type": "template",
            "services": [
                {
                    "fields": [],
                    "imports": [
                        "tpl-service-x509-cert"
                    ],
                    "object_name": "tpl-service-x509-cert",
                    "object_type": "object",
                    "uuid": "5efa4136-a59c-4c28-9d18-035fb6f9d7c8"
                }
            ],
            "uuid": "03280e01-08fa-45cb-aad6-a035856ec56a"
        }
    },
    "ImportSource": {
        "x509-hosts": {
            "key_column": "host_name",
            "modifiers": [
                {
                    "priority": "1",
                    "property_name": "host_address",
                    "provider_class": "Icinga\\Module\\Director\\PropertyModifier\\PropertyModifierRegexReplace",
                    "settings": {
                        "pattern": "/^.*$/",
                        "replacement": "x509-certs",
                        "string": "*",
                        "when_not_matched": "keep"
                    },
                    "target_property": "tags"
                },
                {
                    "priority": "2",
                    "property_name": "tags",
                    "provider_class": "Icinga\\Module\\Director\\PropertyModifier\\PropertyModifierSplit",
                    "settings": {
                        "delimiter": ",",
                        "when_empty": "empty_array"
                    },
                    "target_property": "tags"
                }
            ],
            "provider_class": "Icinga\\Module\\X509\\ProvidedHook\\HostsImportSource",
            "settings": {},
            "source_name": "x509-hosts"
        }
    },
    "SyncRule": {
        "sync-x509-hosts": {
            "object_type": "host",
            "properties": [
                {
                    "destination_field": "object_name",
                    "filter_expression": null,
                    "merge_policy": "override",
                    "priority": "1",
                    "source": "x509-hosts",
                    "source_expression": "${host_name_or_ip}"
                },
                {
                    "destination_field": "import",
                    "filter_expression": null,
                    "merge_policy": "override",
                    "priority": "2",
                    "source": "x509-hosts",
                    "source_expression": "tpl-host-without-ping"
                },
                {
                    "destination_field": "vars.tags",
                    "filter_expression": null,
                    "merge_policy": "merge",
                    "priority": "3",
                    "source": "x509-hosts",
                    "source_expression": "${tags}"
                }
            ],
            "purge_action": "delete",
            "purge_existing": true,
            "rule_name": "sync-x509-hosts",
            "update_policy": "merge"
        }
    },
    "DirectorJob": {
        "10: Import x509 Hosts": {
            "disabled": "n",
            "job_class": "Icinga\\Module\\Director\\Job\\ImportJob",
            "job_name": "10: Import x509 Hosts",
            "run_interval": "900",
            "settings": {
                "run_import": "y",
                "source": "x509-hosts"
            },
            "timeperiod": "7x24"
        },
        "20: Sync x509 data to Host Objects": {
            "disabled": "n",
            "job_class": "Icinga\\Module\\Director\\Job\\SyncJob",
            "job_name": "20: Sync x509 data to Host Objects",
            "run_interval": "900",
            "settings": {
                "apply_changes": true,
                "rule": "sync-x509-hosts"
            },
            "timeperiod": "7x24"
        },
        "30: Deploy Config": {
            "disabled": "n",
            "job_class": "Icinga\\Module\\Director\\Job\\ConfigJob",
            "job_name": "30: Deploy Config",
            "run_interval": "900",
            "settings": {
                "deploy_when_changed": "y",
                "force_generate": "n",
                "grace_period": "600"
            },
            "timeperiod": "7x24"
        }
    },
    "Datafield": {
        "1881": {
            "uuid": "e89e3cc3-1771-4df0-b492-ff8bd652c236",
            "varname": "icingacli_x509_host",
            "caption": "icingacli_x509_host",
            "description": "A hosts name",
            "datatype": "Icinga\\Module\\Director\\DataType\\DataTypeString",
            "format": null,
            "settings": {},
            "category": null
        }
    }
}
EOF
        break
    elif [[ "$X509_LAN_CIDR" == "n" ]]; then
        break
    fi
done


msg_ok "Configured x509 module"

mysql notifications < /usr/share/icinga-notifications/schema/mysql/schema.sql || { msg_error "Failed to import notifications schema"; exit 1; }
mkdir -p /etc/icingaweb2/modules/notifications || { msg_error "Failed to create notifications module directory"; exit 1; }
cat <<EOF >/etc/icingaweb2/modules/notifications/config.ini || { msg_error "Failed to create notifications config"; exit 1; }
[database]
resource = "notifications"
EOF
chown -R root:icingaweb2 /etc/icingaweb2/modules/notifications || { msg_error "Failed to set notifications permissions"; exit 1; }
chmod 660 /etc/icingaweb2/modules/notifications/config.ini || { msg_error "Failed to set notifications file permissions"; exit 1; }
sed -i "s/password: CHANGEME/password: ${NOTIFICATIONS_DB_PW}/g" /etc/icinga-notifications/config.yml || { msg_error "Failed to configure notifications password"; exit 1; }
sed -i "s/^icingaweb2-url: http.*/icingaweb2-url: http:\/\/${FQDN}\/icingaweb2/g" /etc/icinga-notifications/config.yml || { msg_error "Failed to configure notifications URL"; exit 1; }
systemctl restart icinga-desktop-notifications.service || msg_error "Warning: Failed to restart notifications service"

msg_ok "Configured notifications modules"

ICINGAWEB_ADMIN_PW_HASH=$(php -r "echo password_hash('$ICINGAWEB_ADMIN_PW', PASSWORD_DEFAULT);") || { msg_error "Failed to generate password hash"; exit 1; }
mysql -D icingaweb < /usr/share/icingaweb2/schema/mysql.schema.sql || { msg_error "Failed to import Icinga Web schema"; exit 1; }
mysql icingaweb -e "INSERT INTO icingaweb_user (name, active, password_hash) 
          VALUES ('icingaadmin', 1, '$ICINGAWEB_ADMIN_PW_HASH');" || { msg_error "Failed to create Icinga Web admin user"; exit 1; }

msg_ok "Configured Icingaweb initial user"


git clone https://github.com/Linuxfabrik/monitoring-plugins.git /opt/monitoring-plugins || { msg_error "Failed to clone Linuxfabrik monitoring plugins"; exit 1; }
cd /opt/monitoring-plugins || { msg_error "Failed to change to monitoring plugins directory"; exit 1; }
git checkout v2.2.1 || { msg_error "Failed to checkout monitoring plugins version"; exit 1; }
tools/basket-join || { msg_error "Failed to join basket"; exit 1; }
icingacli director basket restore < icingaweb2-module-director-basket.json || { msg_error "Failed to restore director basket"; exit 1; }
msg_ok "Imported Icinga Director Linuxfabrik monitoring basket"

icingacli director host create "$FQDN" --json "{
    \"address\": \"127.0.0.1\",
    \"imports\": [
        \"tpl-host-linux\"
    ],
    \"object_type\": \"object\",
    \"vars\": {
        \"_override_servicevars\": {
            \"Icinga Top Flapping Services\": {
                \"icinga_topflap_services_password\": \"$ICINGAWEB_ADMIN_PW\",
                \"icinga_topflap_services_url\": \"http://localhost/icingaweb2/icingadb/history?limit=250\",
                \"icinga_topflap_services_username\": \"icingaadmin\"
            },
            \"Redis Status\": {
                \"redis_status_port\": \"6380\"
            },
            \"Systemd Unit - redis.service\": {
                \"systemd_unit_unit\": \"icingadb-redis\"
            }
        },
        \"tags\": [
            \"icinga2\",
            \"mariadb\",
            \"icingadb\",
            \"redis\",
            \"debian13\"
        ]
    }
}" || { msg_error "Failed to create Icinga Director host"; exit 1; }
msg_ok "Created Icinga Director host for local container"
icingacli director config deploy || { msg_error "Failed to deploy Icinga Director configuration"; exit 1; }
msg_ok "Deployed Icinga Director configuration"

msg_info "Installing Icinga Proxmox VE tools"
git clone https://github.com/nbuchwitz/icingaweb2-module-pve /usr/share/icingaweb2/modules/pve || { msg_error "Failed to clone Proxmox VE module"; exit 1; }
wget https://raw.githubusercontent.com/nbuchwitz/check_pve/refs/heads/main/check_pve.py -O /usr/lib64/nagios/plugins/check_pve.py || { msg_error "Failed to download check_pve.py"; exit 1; }
chmod +x /usr/lib64/nagios/plugins/check_pve.py || { msg_error "Failed to set check_pve.py executable"; exit 1; }
mkdir -p /etc/icinga2/zones.d/global-templates || { msg_error "Failed to create Icinga2 templates directory"; exit 1; }
wget https://raw.githubusercontent.com/nbuchwitz/check_pve/refs/heads/main/icinga2/command.conf -O /etc/icinga2/zones.d/global-templates/commands-pve.conf || { msg_error "Failed to download Proxmox VE commands"; exit 1; }
icingacli module enable pve || { msg_error "Failed to enable PVE module"; exit 1; }
systemctl reload icinga2 || { msg_error "Failed to reload Icinga2"; exit 1; }
icingacli director kickstart run || { msg_error "Failed to run director kickstart"; exit 1; }
msg_ok "Installed and enabled nbuchwitz's Proxmox VE module and plugin"

msg_info "Installing Icinga Web 2 map module"
git clone https://github.com/nbuchwitz/icingaweb2-module-map.git /usr/share/icingaweb2/modules/map || { msg_error "Failed to clone Maps module"; exit 1; }
icingacli module enable map || { msg_error "Failed to enable maps module"; exit 1; }
msg_ok "Installed and enabled nbuchwitz's map module"

msg_info "Enabling additional Icinga Web 2 modules"
icingacli module enable businessprocess || msg_error "Warning: Failed to enable businessprocess module"
icingacli module enable cube || msg_error "Warning: Failed to enable cube module"
icingacli module enable incubator || msg_error "Warning: Failed to enable incubator module"
icingacli module enable director || msg_error "Warning: Failed to enable director module"
icingacli module disable setup || msg_error "Warning: Failed to disable setup module"
msg_ok "Enabled additional Icinga Web 2 modules"

## Add influx connection?

echo    
echo "--- InfluxDB connection for PerfData ---"
while true; do
    read -rp "Use remote InfluxDB server? (y/n): " INFLUX_REMOTE
    if [[ "$INFLUX_REMOTE" == "y" || "$INFLUX_REMOTE" == "n" ]]; then break; fi
done
if [[ "$INFLUX_REMOTE" == "y" ]]; then

    while true; do
        read -rp "Which InfluxDB version to use? (1/[2]): " INFLUX_VER
        INFLUX_VER=${INFLUX_VER:-2}
        if [[ "$INFLUX_VER" == "1" || "$INFLUX_VER" == "2" ]]; then break; fi
    done

    while true; do
        read -rp "Remote InfluxDB http procotcol (http/[https]): " INFLUX_PROTO
        INFLUX_PROTO=${INFLUX_PROTO:-https}
        if [[ "$INFLUX_PROTO" == "http" || "$INFLUX_PROTO" == "https" ]]; then break; fi
    done
    if [[ "$INFLUX_PROTO" == "https" ]]; then
        echo "Ensure that your InfluxDB server has a valid SSL certificate!"
        while true; do
            read -rp "Allow insecure SSL connection? (y/N): " INFLUX_SSL_INSECURE
            INFLUX_SSL_INSECURE=${INFLUX_SSL_INSECURE:-n}
            if [[ "$INFLUX_SSL_INSECURE" == "y" || "$INFLUX_SSL_INSECURE" == "n" ]]; then break; fi
        done
        if [[ "$INFLUX_SSL_INSECURE" == "y" ]]; then
            INFLUX_SSL_INSECURE_BOOL="true"
            INFLUX_SSL_INSECURE_NUM="1"
        fi
        INFLUX_SSL_ENABLE="true"
    fi
    read -rp "Remote InfluxDB hostname (e.g. [influxdb]): " INFLUX_HOST
    INFLUX_HOST=${INFLUX_HOST:-influxdb}
    read -rp "Remote InfluxDB port (e.g. [8086]): " INFLUX_PORT
    INFLUX_PORT=${INFLUX_PORT:-8086}
    read -rp "Bucket or database name for Icinga (e.g. [icinga]): " INFLUX_BUCKET
    INFLUX_BUCKET=${INFLUX_BUCKET:-icinga}

    if [[ "$INFLUX_VER" == "1" ]]; then
        read -rp "InfluxDB username: " INFLUX_USER
        read -rsp "InfluxDB password: " INFLUX_PW;
        
        cat <<EOF >/etc/icinga2/features-available/influxdb.conf
object InfluxdbWriter "influxdb" {
host = "$INFLUX_HOST"
port = $INFLUX_PORT
database = "$INFLUX_BUCKET"
username = "$INFLUX_USER"
password = "$INFLUX_PW"
ssl_enable = ${INFLUX_SSL_ENABLE:-false}
ssl_insecure_noverify = ${INFLUX_SSL_INSECURE_BOOL:-false}
flush_threshold = 1024
flush_interval = 10s
host_template = {
    measurement = "\$host.check_command\$"
    tags = {
    hostname = "\$host.name\$"
    }
}
service_template = {
    measurement = "\$service.check_command\$"
    tags = {
    hostname = "\$host.name\$"
    }
}
}
EOF
        mkdir -p /etc/icingaweb2/modules/perfdatagraphsinfluxdbv1
        cat <<EOF >/etc/icingaweb2/modules/perfdatagraphsinfluxdbv1/config.ini
[influx]
api_url = "$INFLUX_PROTO://$INFLUX_HOST:$INFLUX_PORT"
api_database = "$INFLUX_BUCKET"
api_username = "$INFLUX_USER"
api_password = "$INFLUX_PW"
api_tls_insecure = "${INFLUX_SSL_INSECURE_NUM:-0}"
EOF
        chown -R root:icingaweb2 /etc/icingaweb2/modules/perfdatagraphsinfluxdbv1
        chmod 660 /etc/icingaweb2/modules/perfdatagraphsinfluxdbv1/config.ini
        msg_ok "Configured InfluxDB v1 connection for PerfData module"

        icingacli module enable perfdatagraphs
        icingacli module enable perfdatagraphsinfluxdbv1
    else
        read -rp "Organization (org) name [icinga]: " INFLUX_ORG
        INFLUX_ORG=${INFLUX_ORG:-icinga}
        read -rp "InfluxDB token: " INFLUX_TOKEN

        mkdir -p /etc/icingaweb2/modules/perfdatagraphsinfluxdbv2
        cat <<EOF >/etc/icingaweb2/modules/perfdatagraphsinfluxdbv2/config.ini
[influx]
api_url = "$INFLUX_PROTO://$INFLUX_HOST:$INFLUX_PORT"
api_org = "$INFLUX_ORG"
api_bucket = "$INFLUX_BUCKET"
api_token = "$INFLUX_TOKEN"
api_tls_insecure = "${INFLUX_SSL_INSECURE_NUM:-0}"
EOF
        chown -R root:icingaweb2 /etc/icingaweb2/modules/perfdatagraphsinfluxdbv2
        chmod 660 /etc/icingaweb2/modules/perfdatagraphsinfluxdbv2/config.ini
        msg_ok "Configured InfluxDB v2 connection for PerfData module"

        cat <<EOF >/etc/icinga2/features-available/influxdb2.conf
object Influxdb2Writer "influxdb2" {
host = "$INFLUX_HOST"
port = $INFLUX_PORT
organization = "$INFLUX_ORG"
bucket = "$INFLUX_BUCKET"
auth_token = "$INFLUX_TOKEN"
ssl_enable = ${INFLUX_SSL_ENABLE:-false}
ssl_insecure_noverify = ${INFLUX_SSL_INSECURE_BOOL:-false}
flush_threshold = 1024
flush_interval = 10s
host_template = {
    measurement = "\$host.check_command\$"
    tags = {
    hostname = "\$host.name\$"
    }
}
service_template = {
    measurement = "\$service.check_command\$"
    tags = {
    hostname = "\$host.name\$"
    }
}
}
EOF
        icingacli module enable perfdatagraphs
        icingacli module enable perfdatagraphsinfluxdbv2
    fi
    icinga2 feature enable influxdb${INFLUX_VER}
    systemctl restart icinga2
    msg_ok "Configured InfluxDB connection for PerfData module"
fi

cd /usr/share/icingaweb2/public/css/themes
wget https://raw.githubusercontent.com/lazaroblanc/icingaweb2-dark-theme/master/dark-theme.less
git clone https://github.com/Al2Klimov/icingaweb2-theme-apocalypse.git /usr/share/icingaweb2/modules/apocalypse
icingacli module enable apocalypse

msg_ok "Added some extra themes"

msg_info "Icinga2 LXC setup complete."
echo "--- Database credentials ---"
echo "IcingaDB name:    icingadb"
echo "IcingaDB user:     icingadb"
echo "IcingaDB password: $ICINGA_DB_PW"
echo "IcingaWeb2 DB name:    icingaweb"
echo "IcingaWeb2 user:   icingaweb"
echo "IcingaWeb2 password: $ICINGAWEB_DB_PW"
echo "Notifications DB name:    notifications"
echo "Notifications user: notifications"
echo "Notifications password: $NOTIFICATIONS_DB_PW"
echo "Director DB name:    director"
echo "Director user: director"
echo "Director password: $DIRECTOR_DB_PW"
echo "x509 DB name:    x509"
echo "x509 user: x509"
echo "x509 password: $X509_DB_PW"
echo "Reporting DB name:    reporting"
echo "Reporting user: reporting"
echo "Reporting password: $REPORTING_DB_PW"
echo "--- Web credentials ---"
echo "Icingaweb initial user: icingaadmin"
echo "Icingaweb initial password: $ICINGAWEB_ADMIN_PW"

msg_ok "Configured Icinga"

motd_ssh
customize
cleanup_lxc
