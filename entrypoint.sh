#!/bin/sh

if ! [ -f /var/www/html/version ] || ! diff /hubzilla/version /var/www/html/version;then
	cp -Rapf /hubzilla/* /hubzilla/.htaccess /var/www/html/
	FORCE_CONFIG=1
fi

if [ "${1:-"failed"}" != "crond" ];then # Do no configuration for crond

# Check for database
CNT=0
case "${DB_TYPE}" in
mysqli|mysql|mariadb|0|"")
srv() {	mysql -u "${DB_USER:="hubzilla"}" "-p${DB_PASSWORD:="hubzilla"}" -h "${DB_HOST:="mariadb"}" -P "${DB_PORT:=3306}" "$@" 2>/dev/null ; }
db()  { srv -D "${DB_NAME:="hub"}" "$@" ; }
sql() { db -e "$@" ; }
	# Warning mysql is largely untested
	while ! srv -e "status" >/dev/null;do
		echo "Waiting for mysql to be ready ($((CNT+=1)))"
		sleep 2
	done
	if ! sql 'SELECT count(*) FROM pconfig;' >/dev/null;then
		echo "Database doesnt contain the 'pconfig' table... Installing database schema"
		db < install/schema_mysql.sql
		if [ $? -ne 0 ];then
			echo "***** Installing schema generated errors *****"
			echo "***** Even if this sound very bad, continuing *****"
		fi
		FORCE_CONFIG=1
	fi
	DB_TYPE=0;;
pgsql|postgres|1)
db() {  PGPASSWORD="${DB_PASSWORD:="hubzilla"}" psql -h "${DB_HOST:="postgres"}" -p "${DB_PORT:=5432}" -U "${DB_USER:="hubzilla"}" -d "${DB_NAME:="hub"}" -wt "$@" 2>/dev/null ; }
sql() {	db -c "$@" ; }
	while ! sql 'SELECT * FROM pg_settings WHERE 0=1;' >/dev/null;do
		echo "Waiting for postgres to be ready ($((CNT+=1)))"
		sleep 2
	done
	if ! sql 'SELECT count(*) FROM pconfig;' >/dev/null;then
		echo "Database doesnt contain the 'pconfig' table... Installing database schema"
		db < install/schema_postgres.sql
		if [ $? -ne 0 ];then
			echo "***** Installing schema generated errors *****"
			echo "***** Even if this sound very bad, continuing *****"
		fi
		FORCE_CONFIG=1
	fi
	DB_TYPE=1;;
*)	echo "***** Unknown DB_TYPE=$DB_TYPE ******"
	echo "***** Skipping database check/setup ******"
	echo "***** YOU ARE on your OWN now ******"
	FORCE_CONFIG=0;;
esac



cat > /etc/ssmtp/ssmtp.conf <<END
mailhub=${SMTP_HOST}:${SMTP_PORT}
UseSTARTTLS=${SMTP_USE_STARTTLS}
root=${SMTP_USER}@${SMTP_DOMAIN}
rewriteDomain=${SMTP_DOMAIN}
FromLineOverride=YES
END
if [ ${SMTP_PASS:-"nope"} != "nope" ];then
	cat >> /etc/ssmtp/ssmtp.conf <<END
AuthUser=${SMTP_USER}
AuthPass=${SMTP_PASS}
END
fi
echo "root:${SMTP_USER}@${SMTP_DOMAIN}">/etc/ssmtp/revaliases
echo "www-data:${SMTP_USER}@${SMTP_DOMAIN}">>/etc/ssmtp/revaliases

chown -R www-data:www-data "store"
chown www-data:www-data .

if [ ${FORCE_CONFIG:-"0"} -eq 1 ];then
db() {  PGPASSWORD="${DB_PASSWORD:="hubzilla"}" psql -h "${DB_HOST:="postgres"}" -p "${DB_PORT:=5432}" -U "${DB_USER:="hubzilla"}" -d "${DB_NAME:="hub"}" -wt "$@" 2>/dev/null ; }
	if ! [ -f .htconfig.php ];then
		random_string() {	tr -dc '0-9a-f' </dev/urandom | head -c ${1:-64} ; }
		cat >.htconfig.php <<ENDCONF
<?php
\$db_host = '${DB_HOST}';
\$db_port =  ${DB_PORT};
\$db_user = '${DB_USER}';
\$db_pass = '${DB_PASSWORD}';
\$db_data = '${DB_NAME}';
\$db_type =  ${DB_TYPE};

// The following configuration maybe configured later in the Admin interface
// They can also be set by 'util/pconfig'
App::\$config['system']['timezone'] = 'America/Los_Angeles';
App::\$config['system']['baseurl'] = 'https://$HUBZILLA_DOMAIN';
App::\$config['system']['sitename'] = 'Hubzilla';
App::\$config['system']['location_hash'] = '$(random_string)';
App::\$config['system']['transport_security_header'] = 1;
App::\$config['system']['content_security_policy'] = 1;
App::\$config['system']['register_policy'] = REGISTER_OPEN;
App::\$config['system']['register_text'] = '';
App::\$config['system']['admin_email'] = '$HUBZILLA_ADMIN';
App::\$config['system']['max_import_size'] = 200000;
App::\$config['system']['maximagesize'] = 8000000;
App::\$config['system']['directory_mode']  = DIRECTORY_MODE_NORMAL;
App::\$config['system']['theme'] = 'redbasic';

// error_reporting(E_ERROR | E_WARNING | E_PARSE ); 
// ini_set('error_log','/tmp/php.out'); 
// ini_set('log_errors','1'); 
// ini_set('display_errors', '0');
ENDCONF
	fi
	if [ ${REDIS_PATH:-"nope"} != "nope" ];then
		util/config system session_save_handler redis
		util/config system session_save_path ${REDIS_PATH}
		util/config system session_custom true
	fi

	echo "Install addons"
	for a in ${ADDON_LIST:-nsfw superblock diaspora pubcrawl};do 
		util/addons install $a
		case "$a" in
		diaspora)	util/config system.diaspora_allowed 1;;
		gnusoc)		util/config system.gnusoc_allowed 1;;
		# even if jappixmini doesnt seems to work... at least if enabled it will be legal easily :P
		jappixmini)	curl -sL https://framagit.org/hubzilla/addons/raw/cf4c65b4c61804fb586e8ac4b3a3af085bd0396f/jappixmini.tgz >addon/jappixmini.tgz
				util/config jappixmini bosh_address "https://$HUBZILLA_DOMAIN/http-bind";;
		xmpp)		util/config xmpp bosh_proxy "https://$HUBZILLA_DOMAIN/http-bind";;
		ldapauth)	util/config ldapauth ldap_server ldap://$LDAP_SERVER
				util/config ldapauth ldap_binddn $LDAP_ROOT_DN
				util/config ldapauth ldap_bindpw $LDAP_ADMIN_PASSWORD
				util/config ldapauth ldap_searchdn $LDAP_BASE
				util/config ldapauth ldap_userattr uid
				util/config ldapauth create_account;;
		esac
	done
	util/service_class system default_service_class firstclass
	util/config system disable_email_validation 1
	util/config system ignore_imagick true
fi

fi
echo "Starting $@"
exec "$@"
