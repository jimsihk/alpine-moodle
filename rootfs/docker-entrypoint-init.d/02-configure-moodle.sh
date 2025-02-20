#!/bin/sh
#
# Moodle configuration script
#
set -eo pipefail

if [ -n "$SKIP_MOODLE_CONFIG" ] && [ "$SKIP_MOODLE_CONFIG" = 'true' ]; then
  echo "Skipped Moodle configuration"
  exit 0
fi

# Check that the database is available
echo "Waiting for $DB_HOST:$DB_PORT to be ready"
while ! nc -w 1 "$DB_HOST" "$DB_PORT"; do
    # Show some progress
    echo -n '.';
    sleep 1;
done
echo "$DB_HOST is ready"

# Check that the database replica is available
if [ -n "$DB_HOST_REPLICA" ]; then
  if [ -n "$DB_PORT_REPLICA" ]; then
    echo "Waiting for $DB_HOST_REPLICA:$DB_PORT_REPLICA to be ready"
    while ! nc -w 1 "$DB_HOST_REPLICA" "$DB_PORT_REPLICA"; do
        # Show some progress
        echo -n '.';
        sleep 1;
    done
  else
    echo "Waiting for $DB_HOST_REPLICA:$DB_PORT to be ready"
    while ! nc -w 1 "$DB_HOST_REPLICA" "$DB_PORT"; do
        # Show some progress
        echo -n '.';
        sleep 1;
    done
  fi
  echo "$DB_HOST_REPLICA is ready"
fi
# Give it another 3 seconds.
sleep 3;

# Verify the source code integrity
# - Check if new volume is mounted that Moodle code directory will be empty
# - Download the Moodle source code in the same way as specified in DockerFile
# shellcheck disable=SC2010
if [ -z "$(ls -A "${WEB_PATH}" | grep -v 'config.php')" ]; then
  echo "Downloading Moodle source codes..."
  /usr/libexec/moodle/download-moodle-code
fi
if [ ! -f "${WEB_PATH}"/admin/cli/isinstalled.php ]; then
  echo "Copying isinstalled.php..."
  cp -p /usr/libexec/moodle/isinstalled.php "${WEB_PATH}"/admin/cli/
fi

# Check if the config.php file exists
if [ ! -f "${WEB_PATH}"/config.php ]; then

    echo "Generating config.php file..."
    ENV_VAR='var' php -d max_input_vars=10000 "${WEB_PATH}"/admin/cli/install.php \
        --lang="$MOODLE_LANGUAGE" \
        --wwwroot="$SITE_URL" \
        --dataroot=/var/www/moodledata/ \
        --dbtype="$DB_TYPE" \
        --dbhost="$DB_HOST" \
        --dbname="$DB_NAME" \
        --dbuser="$DB_USER" \
        --dbpass="$DB_PASS" \
        --dbport="$DB_PORT" \
        --prefix="$DB_PREFIX" \
        --fullname="$MOODLE_SITENAME" \
        --shortname="$MOODLE_SHORTNAME" \
        --adminuser="$MOODLE_USERNAME" \
        --adminpass="$MOODLE_PASSWORD" \
        --adminemail="$MOODLE_EMAIL" \
        --non-interactive \
        --agree-license \
        --skip-database \
        --allow-unstable
        
    # Set extra database settings
    if [ -n "$DB_FETCHBUFFERSIZE" ]; then
      # shellcheck disable=SC2016
      sed -i "/\$CFG->dboptions/a \ \ "\''fetchbuffersize'\'" => $DB_FETCHBUFFERSIZE," "${WEB_PATH}"/config.php
    fi
    if [ "$DB_DBHANDLEOPTIONS" = 'true' ]; then
      # shellcheck disable=SC2016
      sed -i "/\$CFG->dboptions/a \ \ "\''dbhandlesoptions'\'" => true," "${WEB_PATH}"/config.php
    fi
    if [ -n "$DB_HOST_REPLICA" ]; then
      if [ -n "$DB_USER_REPLICA" ] && [ -n "$DB_PASS_REPLICA" ] && [ -n "$DB_PORT_REPLICA" ]; then
        # shellcheck disable=SC2016
        sed -i "/\$CFG->dboptions/a \ \ "\''readonly'\'" => [ \'instance\' => [ \'dbhost\' => \'$DB_HOST_REPLICA\', \'dbport\' => \'$DB_PORT_REPLICA\', \'dbuser\' => \'$DB_USER_REPLICA\', \'dbpass\' => \'$DB_PASS_REPLICA\' ] ]," "${WEB_PATH}"/config.php
      else
        # shellcheck disable=SC2016
        sed -i "/\$CFG->dboptions/a \ \ "\''readonly'\'" => [ \'instance\' => [ \'$DB_HOST_REPLICA\' ] ]," "${WEB_PATH}"/config.php
      fi
    fi
    #'readonly' => [ 'instance' => ['dbhost' => 'slave.dbhost', 'dbport' => '', 'dbuser' => '', 'dbpass' => '']]

    # Offload the file serving from PHP process
    # shellcheck disable=SC2016
    sed -i '/require_once/i $CFG->xsendfile = '\''X-Accel-Redirect'\'';' "${WEB_PATH}"/config.php
    # shellcheck disable=SC2016
    sed -i '/require_once/i $CFG->xsendfilealiases = array(' "${WEB_PATH}"/config.php
    # shellcheck disable=SC2016
    sed -i "/\$CFG->xsendfilealiases/a );" "${WEB_PATH}"/config.php
    # shellcheck disable=SC2016
    sed -i "/\$CFG->xsendfilealiases/a \ \ "\''/dataroot/'\'" => \$CFG->dataroot," "${WEB_PATH}"/config.php
    
    if [ -n "$LOCAL_CACHE_DIRECTORY" ]; then
      if [ ! -d "$LOCAL_CACHE_DIRECTORY" ]; then
        echo "Creating $LOCAL_CACHE_DIRECTORY for localcachedir..."
        mkdir -p "$LOCAL_CACHE_DIRECTORY"
      fi
      # shellcheck disable=SC2016
      sed -i "/require_once/i \$CFG->localcachedir = \'$LOCAL_CACHE_DIRECTORY\';" "${WEB_PATH}"/config.php
      # shellcheck disable=SC2016
      sed -i "/\$CFG->xsendfilealiases/a \ \ "\''/localcachedir/'\'" => \'$LOCAL_CACHE_DIRECTORY\'," "${WEB_PATH}"/config.php
      cat << EOL >> /etc/nginx/conf.d/default/server/moodle.conf
    location ~ ^/localcachedir/(.*)$ {
        internal;
        alias $LOCAL_CACHE_DIRECTORY/\$1;
    }
EOL
      echo "Set $LOCAL_CACHE_DIRECTORY as localcachedir"
    fi

    if [ "$SSLPROXY" = 'true' ]; then
        # shellcheck disable=SC2016
        sed -i '/require_once/i $CFG->sslproxy = true;' "${WEB_PATH}"/config.php
    fi

    # Avoid cron failure by forcing to use database as lock factory
    # https://moodle.org/mod/forum/discuss.php?d=328300#p1320902
    # shellcheck disable=SC2016
    sed -i '/require_once/i $CFG->lock_factory = '\''\\\\core\\\\lock\\\\db_record_lock_factory'\'';' ${WEB_PATH}/config.php

    # Avoid allowing executable paths to be set via the Admin GUI
    echo "\$CFG->preventexecpath = true;" >> "${WEB_PATH}"/config.php

fi

# Check if the database is already installed
if php -d max_input_vars=10000 "${WEB_PATH}"/admin/cli/isinstalled.php ; then

    echo "Installing database..."
    php -d max_input_vars=10000 "${WEB_PATH}"/admin/cli/install_database.php \
        --lang="$MOODLE_LANGUAGE" \
        --adminuser="$MOODLE_USERNAME" \
        --adminpass="$MOODLE_PASSWORD" \
        --adminemail="$MOODLE_EMAIL" \
        --fullname="$MOODLE_SITENAME" \
        --shortname="$MOODLE_SHORTNAME" \
        --agree-license

    echo "Configuring settings..."

    # php -d max_input_vars=10000 "${WEB_PATH}"/admin/cli/cfg.php --name=slasharguments --set=0
    php -d max_input_vars=10000 "${WEB_PATH}"/admin/cli/cfg.php --name=pathtophp --set=/usr/bin/php
    php -d max_input_vars=10000 "${WEB_PATH}"/admin/cli/cfg.php --name=pathtodu --set=/usr/bin/du
    # php -d max_input_vars=10000 "${WEB_PATH}"/admin/cli/cfg.php --name=aspellpath --set=/usr/bin/aspell
    # php -d max_input_vars=10000 "${WEB_PATH}"/admin/cli/cfg.php --name=pathtodot --set=/usr/bin/dot
    # php -d max_input_vars=10000 "${WEB_PATH}"/admin/cli/cfg.php --name=pathtogs --set=/usr/bin/gs
    # php -d max_input_vars=10000 "${WEB_PATH}"/admin/cli/cfg.php --name=pathtopython --set=/usr/bin/python3
    php -d max_input_vars=10000 "${WEB_PATH}"/admin/cli/cfg.php --name=enableblogs --set=0

    php -d max_input_vars=10000 "${WEB_PATH}"/admin/cli/cfg.php --name=smtphosts --set="$SMTP_HOST":"$SMTP_PORT"
    php -d max_input_vars=10000 "${WEB_PATH}"/admin/cli/cfg.php --name=smtpuser --set="$SMTP_USER"
    php -d max_input_vars=10000 "${WEB_PATH}"/admin/cli/cfg.php --name=smtppass --set="$SMTP_PASSWORD"
    php -d max_input_vars=10000 "${WEB_PATH}"/admin/cli/cfg.php --name=smtpsecure --set="$SMTP_PROTOCOL"
    php -d max_input_vars=10000 "${WEB_PATH}"/admin/cli/cfg.php --name=noreplyaddress --set="$MOODLE_MAIL_NOREPLY_ADDRESS"
    php -d max_input_vars=10000 "${WEB_PATH}"/admin/cli/cfg.php --name=emailsubjectprefix --set="$MOODLE_MAIL_PREFIX"
fi

# Post installation setup

# Function to change session caching settings
config_session_cache() {
  if [ -z "$SESSION_CACHE_TYPE" ]; then
    echo "Using default file session store"
  else
    echo "Using $SESSION_CACHE_TYPE as session store"
    case $SESSION_CACHE_TYPE in
        memcached)
            # Check that the cache store is available
            echo "Waiting for $SESSION_CACHE_HOST:$SESSION_CACHE_PORT to be ready..."
            while ! nc -w 1 "$SESSION_CACHE_HOST" "$SESSION_CACHE_PORT"; do
                # Show some progress
                echo -n '.';
                sleep 1;
            done
            echo "$SESSION_CACHE_HOST is ready"
            # Give it another 3 seconds.
            sleep 3;
            if [ -n "$SESSION_CACHE_HOST" ] && [ -n "$SESSION_CACHE_PORT" ] ; then
                php -d max_input_vars=10000 "${WEB_PATH}"/admin/cli/cfg.php --name=session_handler_class --set='\core\session\memcached'
                php -d max_input_vars=10000 "${WEB_PATH}"/admin/cli/cfg.php --name=session_memcached_save_path --set="$SESSION_CACHE_HOST:$SESSION_CACHE_PORT"
                php -d max_input_vars=10000 "${WEB_PATH}"/admin/cli/cfg.php --name=session_memcached_prefix --set="$SESSION_CACHE_PREFIX.memc.sess.key."
                php -d max_input_vars=10000 "${WEB_PATH}"/admin/cli/cfg.php --name=session_memcached_acquire_lock_timeout --set=120
                php -d max_input_vars=10000 "${WEB_PATH}"/admin/cli/cfg.php --name=session_memcached_lock_expire --set=7200
            fi
            ;;
        redis)
            # Check that the cache store is available
            echo "Waiting for $SESSION_CACHE_HOST:$SESSION_CACHE_PORT to be ready..."
            while ! nc -w 1 "$SESSION_CACHE_HOST" "$SESSION_CACHE_PORT"; do
                # Show some progress
                echo -n '.';
                sleep 1;
            done
            echo "$SESSION_CACHE_HOST is ready"
            # Give it another 3 seconds.
            sleep 3;
            if [ -n "$SESSION_CACHE_HOST" ] && [ -n "$SESSION_CACHE_PORT" ] ; then
                php -d max_input_vars=10000 "${WEB_PATH}"/admin/cli/cfg.php --name=session_handler_class --set='\core\session\redis'
                php -d max_input_vars=10000 "${WEB_PATH}"/admin/cli/cfg.php --name=session_redis_host --set="$SESSION_CACHE_HOST"
                php -d max_input_vars=10000 "${WEB_PATH}"/admin/cli/cfg.php --name=session_redis_port --set="$SESSION_CACHE_PORT"
                if [ -n "$SESSION_CACHE_AUTH" ] ; then
                    php -d max_input_vars=10000 "${WEB_PATH}"/admin/cli/cfg.php --name=session_redis_auth --set="$SESSION_CACHE_AUTH"
                fi
                php -d max_input_vars=10000 "${WEB_PATH}"/admin/cli/cfg.php --name=session_redis_prefix --set="$SESSION_CACHE_PREFIX"
                php -d max_input_vars=10000 "${WEB_PATH}"/admin/cli/cfg.php --name=session_redis_acquire_lock_timeout --set=120
                php -d max_input_vars=10000 "${WEB_PATH}"/admin/cli/cfg.php --name=session_redis_lock_expire --set=7200
                php -d max_input_vars=10000 "${WEB_PATH}"/admin/cli/cfg.php --name=session_redis_serializer_use_igbinary --set='true'
            fi
            ;;
        database)
            php -d max_input_vars=10000 "${WEB_PATH}"/admin/cli/cfg.php --name=session_handler_class --set='\core\session\database'
            php -d max_input_vars=10000 "${WEB_PATH}"/admin/cli/cfg.php --name=session_database_acquire_lock_timeout --set=120
            ;;
    esac
  fi
}
# Set session cache store
config_session_cache

# Remove .swf (flash) plugin for security reasons DISABLED BECAUSE IS REQUIRED
#php -d max_input_vars=10000 ${WEB_PATH}/admin/cli/uninstall_plugins.php --plugins=media_swf --run

# Disable plugin installation via the Admin GUI
if [ "$DISABLE_WEB_INSTALL_PLUGIN" = 'true' ]; then
  php -d max_input_vars=10000 "${WEB_PATH}"/admin/cli/cfg.php --name=disableupdateautodeploy --set=1
else
  php -d max_input_vars=10000 "${WEB_PATH}"/admin/cli/cfg.php --name=disableupdateautodeploy --set=0
fi

# Avoid writing the config file
chmod 440 "${WEB_PATH}"/config.php

# Fix publicpaths check to point to the internal container on port 8080
patch_publicpaths() {
  PUBLICPATHS_FILE="${WEB_PATH}"/lib/classes/check/environment/publicpaths.php
  if [ -n "$1" ]; then
    echo "Reverting publicpaths.php"
    sed -i 's/wwwroot\ \. \"\:8080\"/wwwroot/g' "$PUBLICPATHS_FILE"
  else
    set +eo pipefail
    grep "wwwroot\ \. \"\:8080\"" "$PUBLICPATHS_FILE" > /dev/null
    GREPRESULT=$?
    set -eo pipefail
    if [ "$GREPRESULT" -eq 1 ]; then
      echo "Patching publicpaths.php"
      sed -i 's/wwwroot/wwwroot\ \. \"\:8080\"/g' "$PUBLICPATHS_FILE"
    else
      echo "Skipped patching publicpaths.php"
    fi
  fi
}
#patch_publicpaths

# Update Moodle
if [ -z "$AUTO_UPDATE_MOODLE" ] || [ "$AUTO_UPDATE_MOODLE" = true ]; then
  # Check current moodle maintenance status and keep in maintenance mode in case of manual enablement of it
  # This is also useful when deploying multiple moodle instances in a cluster using shared storage,
  # in order to avoid interruption to users while moodle restart
  echo "Checking maintenance status..."
  START_IN_MAINT_MODE=false
  MAINT_STATUS=$(php -d max_input_vars=10000 "${WEB_PATH}"/admin/cli/maintenance.php | sed 's/^==.*==//g' | sed '/^$/d')
  if [ "$MAINT_STATUS" = "$MAINT_STATUS_KEYWORD" ]; then
      echo "Maintenance mode will be kept enabled"
      START_IN_MAINT_MODE=true
  fi
  echo "Upgrading moodle..."
  php -d max_input_vars=10000 "${WEB_PATH}"/admin/cli/maintenance.php --enable
  if [ "${ENABLE_GIT_CLONE}" = 'true' ]; then
    if [ -z "$UPDATE_MOODLE_CODE" ] || [ "$UPDATE_MOODLE_CODE" = true ]; then
      echo "Checking moodle code version..."
      patch_publicpaths 'revert'
      GIT_TRACE=1
      git -C "${WEB_PATH}" fetch origin "$MODOLE_GIT_BRANCH" --depth=1 && git -C "${WEB_PATH}" checkout FETCH_HEAD -B "$MODOLE_GIT_BRANCH"
      GIT_TRACE=0
      /usr/libexec/moodle/clean-moodle-code "${WEB_PATH}"
      patch_publicpaths
    fi
  fi
  php -d max_input_vars=10000 "${WEB_PATH}"/admin/cli/upgrade.php --non-interactive --allow-unstable
  if [ $START_IN_MAINT_MODE = false ]; then
      php -d max_input_vars=10000 "${WEB_PATH}"/admin/cli/maintenance.php --disable
  else
      echo "Started in maintenance mode, requires manual disable the maintenance mode"
  fi
else
  echo "Skipped auto update of Moodle"
fi
