#!/bin/sh
#
# Moodle configuration script
#
set -eo pipefail

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


# Check if the config.php file exists
if [ ! -f /var/www/html/config.php ]; then

    echo "Generating config.php file..."
    ENV_VAR='var' php -d max_input_vars=10000 /var/www/html/admin/cli/install.php \
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
      sed -i "/\$CFG->dboptions/a \ \ "\''fetchbuffersize'\'" => $DB_FETCHBUFFERSIZE," /var/www/html/config.php
    fi
    if [ "$DB_DBHANDLEOPTIONS" = 'true' ]; then
      # shellcheck disable=SC2016
      sed -i "/\$CFG->dboptions/a \ \ "\''dbhandlesoptions'\'" => true," /var/www/html/config.php
    fi
    if [ -n "$DB_HOST_REPLICA" ]; then
      if [ -n "$DB_USER_REPLICA" ] && [ -n "$DB_PASS_REPLICA" ] && [ -n "$DB_PORT_REPLICA" ]; then
        # shellcheck disable=SC2016
        sed -i "/\$CFG->dboptions/a \ \ "\''readonly'\'" => [ \'instance\' => [ \'dbhost\' => \'$DB_HOST_REPLICA\', \'dbport\' => \'$DB_PORT_REPLICA\', \'dbuser\' => \'$DB_USER_REPLICA\', \'dbpass\' => \'$DB_PASS_REPLICA\' ] ]," /var/www/html/config.php
      else
        # shellcheck disable=SC2016
        sed -i "/\$CFG->dboptions/a \ \ "\''readonly'\'" => [ \'instance\' => [ \'$DB_HOST_REPLICA\' ] ]," /var/www/html/config.php
      fi
    fi
    #'readonly' => [ 'instance' => ['dbhost' => 'slave.dbhost', 'dbport' => '', 'dbuser' => '', 'dbpass' => '']]

    # Offload the file serving from PHP process
    # shellcheck disable=SC2016
    sed -i '/require_once/i $CFG->xsendfile = '\''X-Accel-Redirect'\'';' /var/www/html/config.php
    # shellcheck disable=SC2016
    sed -i '/require_once/i $CFG->xsendfilealiases = array('\''\/dataroot\/'\'' => $CFG->dataroot);' /var/www/html/config.php

    if [ "$SSLPROXY" = 'true' ]; then
        # shellcheck disable=SC2016
        sed -i '/require_once/i $CFG->sslproxy = true;' /var/www/html/config.php
    fi

    # Avoid cron failure by forcing to use database as lock factory
    # https://moodle.org/mod/forum/discuss.php?d=328300#p1320902
    # shellcheck disable=SC2016
    sed -i '/require_once/i $CFG->lock_factory = '\''\\\\core\\\\lock\\\\db_record_lock_factory'\'';' /var/www/html/config.php

    # Avoid allowing executable paths to be set via the Admin GUI
    echo "\$CFG->preventexecpath = true;" >> /var/www/html/config.php

fi

# Check if the database is already installed
if php -d max_input_vars=10000 /var/www/html/admin/cli/isinstalled.php ; then

    echo "Installing database..."
    php -d max_input_vars=10000 /var/www/html/admin/cli/install_database.php \
        --lang="$MOODLE_LANGUAGE" \
        --adminuser="$MOODLE_USERNAME" \
        --adminpass="$MOODLE_PASSWORD" \
        --adminemail="$MOODLE_EMAIL" \
        --fullname="$MOODLE_SITENAME" \
        --shortname="$MOODLE_SHORTNAME" \
        --agree-license

    echo "Configuring settings..."

    # php -d max_input_vars=10000 /var/www/html/admin/cli/cfg.php --name=slasharguments --set=0
    php -d max_input_vars=10000 /var/www/html/admin/cli/cfg.php --name=pathtophp --set=/usr/bin/php
    php -d max_input_vars=10000 /var/www/html/admin/cli/cfg.php --name=pathtodu --set=/usr/bin/du
    # php -d max_input_vars=10000 /var/www/html/admin/cli/cfg.php --name=aspellpath --set=/usr/bin/aspell
    # php -d max_input_vars=10000 /var/www/html/admin/cli/cfg.php --name=pathtodot --set=/usr/bin/dot
    # php -d max_input_vars=10000 /var/www/html/admin/cli/cfg.php --name=pathtogs --set=/usr/bin/gs
    # php -d max_input_vars=10000 /var/www/html/admin/cli/cfg.php --name=pathtopython --set=/usr/bin/python3
    php -d max_input_vars=10000 /var/www/html/admin/cli/cfg.php --name=enableblogs --set=0

    php -d max_input_vars=10000 /var/www/html/admin/cli/cfg.php --name=smtphosts --set="$SMTP_HOST":"$SMTP_PORT"
    php -d max_input_vars=10000 /var/www/html/admin/cli/cfg.php --name=smtpuser --set="$SMTP_USER"
    php -d max_input_vars=10000 /var/www/html/admin/cli/cfg.php --name=smtppass --set="$SMTP_PASSWORD"
    php -d max_input_vars=10000 /var/www/html/admin/cli/cfg.php --name=smtpsecure --set="$SMTP_PROTOCOL"
    php -d max_input_vars=10000 /var/www/html/admin/cli/cfg.php --name=noreplyaddress --set="$MOODLE_MAIL_NOREPLY_ADDRESS"
    php -d max_input_vars=10000 /var/www/html/admin/cli/cfg.php --name=emailsubjectprefix --set="$MOODLE_MAIL_PREFIX"
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
                php -d max_input_vars=10000 /var/www/html/admin/cli/cfg.php --name=session_handler_class --set='\core\session\memcached'
                php -d max_input_vars=10000 /var/www/html/admin/cli/cfg.php --name=session_memcached_save_path --set="$SESSION_CACHE_HOST:$SESSION_CACHE_PORT"
                php -d max_input_vars=10000 /var/www/html/admin/cli/cfg.php --name=session_memcached_prefix --set="$SESSION_CACHE_PREFIX.memc.sess.key."
                php -d max_input_vars=10000 /var/www/html/admin/cli/cfg.php --name=session_memcached_acquire_lock_timeout --set=120
                php -d max_input_vars=10000 /var/www/html/admin/cli/cfg.php --name=session_memcached_lock_expire --set=7200
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
                php -d max_input_vars=10000 /var/www/html/admin/cli/cfg.php --name=session_handler_class --set='\core\session\redis'
                php -d max_input_vars=10000 /var/www/html/admin/cli/cfg.php --name=session_redis_host --set="$SESSION_CACHE_HOST"
                php -d max_input_vars=10000 /var/www/html/admin/cli/cfg.php --name=session_redis_port --set="$SESSION_CACHE_PORT"
                if [ -n "$SESSION_CACHE_AUTH" ] ; then
                    php -d max_input_vars=10000 /var/www/html/admin/cli/cfg.php --name=session_redis_auth --set="$SESSION_CACHE_AUTH"
                fi
                php -d max_input_vars=10000 /var/www/html/admin/cli/cfg.php --name=session_redis_prefix --set="$SESSION_CACHE_PREFIX"
                php -d max_input_vars=10000 /var/www/html/admin/cli/cfg.php --name=session_redis_acquire_lock_timeout --set=120
                php -d max_input_vars=10000 /var/www/html/admin/cli/cfg.php --name=session_redis_lock_expire --set=7200
                php -d max_input_vars=10000 /var/www/html/admin/cli/cfg.php --name=session_redis_serializer_use_igbinary --set='true'
            fi
            ;;
        database)
            php -d max_input_vars=10000 /var/www/html/admin/cli/cfg.php --name=session_handler_class --set='\core\session\database'
            php -d max_input_vars=10000 /var/www/html/admin/cli/cfg.php --name=session_database_acquire_lock_timeout --set=120
            ;;
    esac
  fi
}
# Set session cache store
config_session_cache

# Remove .swf (flash) plugin for security reasons DISABLED BECAUSE IS REQUIRED
#php -d max_input_vars=10000 /var/www/html/admin/cli/uninstall_plugins.php --plugins=media_swf --run

# Disable plugin installation via the Admin GUI
if [ "$DISABLE_WEB_INSTALL_PLUGIN" = 'true' ]; then
  # shellcheck disable=SC2016
  sed -i '/require_once/i $CFG->disableupdateautodeploy = true;' /var/www/html/config.php
fi

# Avoid writing the config file
chmod 440 config.php

# Fix publicpaths check to point to the internal container on port 8080
sed -i 's/wwwroot/wwwroot\ \. \"\:8080\"/g' lib/classes/check/environment/publicpaths.php

# Update Moodle
if [ -z "$AUTO_UPDATE_MOODLE" ] || [ "$AUTO_UPDATE_MOODLE" = true ]; then
  # Check current moodle maintenance status and keep in maintenance mode in case of manual enablement of it
  # This is also useful when deploying multiple moodle instances in a cluster using shared storage,
  # in order to avoid interruption to users while moodle restart
  echo "Checking maintenance status..."
  START_IN_MAINT_MODE=false
  MAINT_STATUS=$(php -d max_input_vars=10000 /var/www/html/admin/cli/maintenance.php | sed 's/^==.*==//g' | sed '/^$/d')
  if [ "$MAINT_STATUS" = 'Status: enabled' ]; then
      echo "Maintenance mode will be kept enabled"
      START_IN_MAINT_MODE=true
  fi
  echo "Upgrading moodle..."
  php -d max_input_vars=10000 /var/www/html/admin/cli/maintenance.php --enable
  git -C /var/www/html fetch origin "$MODOLE_GIT_BRANCH" --depth=1 && git -C /var/www/html checkout FETCH_HEAD -B "$MODOLE_GIT_BRANCH"
  php -d max_input_vars=10000 /var/www/html/admin/cli/upgrade.php --non-interactive --allow-unstable
  if [ $START_IN_MAINT_MODE = false ]; then
      php -d max_input_vars=10000 /var/www/html/admin/cli/maintenance.php --disable
  else
      echo "Started in maintenance mode, requires manual disable the maintenance mode"
  fi
else
  echo "Skipped auto update of Moodle"
fi
