ARG ARCH=quay.io/
FROM ${ARCH}jimsihk/alpine-php-nginx:84.11.3

LABEL Description="Lightweight Moodle container with NGINX & PHP-FPM based on Alpine Linux." \
      Maintainer="99048231+jimsihk@users.noreply.github.com"

# renovate: datasource=repology depName=alpine_3_22/dcron versioning=loose
ARG DCRON_VERSION="=4.6-r0"
# renovate: datasource=repology depName=alpine_3_22/libcap versioning=loose
ARG LIBCAP_VERSION="=2.76-r0"
# renovate: datasource=repology depName=alpine_3_22/git versioning=loose
ARG GIT_VERSION="=2.49.1-r0"
# renovate: datasource=repology depName=alpine_3_22/bash versioning=loose
ARG BASH_VERSION="=5.2.37-r0"

ARG ARG_WEB_PATH='/var/www/html'
ENV WEB_PATH=${ARG_WEB_PATH}

# controls whether the remaining steps should use git clone or simply download from git repo
ARG ARG_ENABLE_GIT_CLONE='true'
ENV ENABLE_GIT_CLONE=${ARG_ENABLE_GIT_CLONE}

USER root
COPY --chown=nobody rootfs/ /

# crond needs root, so install dcron and cap package and set the capabilities
# on dcron binary https://github.com/inter169/systs/blob/master/alpine/crond/README.md
RUN apk add --no-cache \
        dcron${DCRON_VERSION} \
        libcap${LIBCAP_VERSION} \
        bash${BASH_VERSION} \
    && if [ "${ENABLE_GIT_CLONE}" = 'true' ]; then apk add --no-cache git${GIT_VERSION}; fi \
    # Always trust the web path to support bind volume of any host path permission
    && if [ "${ENABLE_GIT_CLONE}" = 'true' ]; then git config --system --add safe.directory "${WEB_PATH}"; fi \
    && chown nobody:nobody /usr/sbin/crond \
    && setcap cap_setgid=ep /usr/sbin/crond \
    # Clean up unused files from base image
    && if [ -f "${WEB_PATH}/index.php" ]; then rm ${WEB_PATH}/index.php; fi \
    && if [ -f "${WEB_PATH}/test.html" ]; then rm ${WEB_PATH}/test.html; fi

USER nobody

# Change MOODLE_XX_STABLE for new versions
ARG ARG_MOODLE_GIT_URL='https://github.com/moodle/moodle.git'
ARG ARG_MOODLE_GIT_BRANCH='MOODLE_500_STABLE'
# renovate: datasource=git-refs depName=https://github.com/moodle/moodle branch=MOODLE_500_STABLE
ARG ARG_MOODLE_GIT_COMMIT='a2f7f13d7c77854d7b9b779609567cc3404e3dbe'
ENV MOODLE_GIT_URL=${ARG_MOODLE_GIT_URL} \
    MOODLE_GIT_BRANCH=${ARG_MOODLE_GIT_BRANCH} \
    MOODLE_GIT_COMMIT=${ARG_MOODLE_GIT_COMMIT} \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    SITE_URL=http://localhost \
    DB_TYPE=pgsql \
    DB_HOST=postgres \
    DB_PORT=5432 \
    DB_NAME=moodle \
    DB_USER=moodle \
    DB_PASS=moodle \
    DB_PREFIX=mdl_ \
    DB_DBHANDLEOPTIONS=false \
    DB_DBPERSIST=false \
    SSLPROXY=false \
    MOODLE_EMAIL=user@example.com \
    MOODLE_LANGUAGE=en \
    MOODLE_SITENAME=New-Site \
    MOODLE_SHORTNAME=moodle \
    MOODLE_USERNAME=moodleuser \
    MOODLE_PASSWORD=PLEASE_CHANGEME \
    SMTP_HOST=smtp.gmail.com \
    SMTP_PORT=587 \
    SMTP_USER=your_email@gmail.com \
    SMTP_PASSWORD=your_password \
    SMTP_PROTOCOL=tls \
    MOODLE_MAIL_NOREPLY_ADDRESS=noreply@localhost \
    MOODLE_MAIL_PREFIX=[moodle] \
    client_max_body_size=50M \
    post_max_size=50M \
    upload_max_filesize=50M \
    max_input_vars=5000 \
    opcache_jit_buffer_size=64M \
    custom_router=/r.php \
    SESSION_CACHE_PREFIX=mdl \
    AUTO_UPDATE_MOODLE=true \
    UPGRADE_MOODLE_CODE=true \
    DISABLE_WEB_INSTALL_PLUGIN=false \
    MAINT_STATUS_KEYWORD='Status: enabled' \
    SKIP_MOODLE_CONFIG=false

ARG ARG_REDISSENTINEL_PLUGIN_GIT_URL='https://github.com/catalyst/moodle-cachestore_redissentinel.git'
ARG ARG_REDISSENTINEL_PLUGIN_GIT_BRANCH='master'
# renovate: datasource=git-refs depName=https://github.com/catalyst/moodle-cachestore_redissentinel branch=master
ARG ARG_REDISSENTINEL_PLUGIN_GIT_COMMIT='b495e8f36a81fd1a2a414e34a978da879c473f31'
ENV REDISSENTINEL_PLUGIN_GIT_URL=${ARG_REDISSENTINEL_PLUGIN_GIT_URL}
ENV REDISSENTINEL_PLUGIN_GIT_BRANCH=${ARG_REDISSENTINEL_PLUGIN_GIT_BRANCH}
ENV REDISSENTINEL_PLUGIN_GIT_COMMIT=${ARG_REDISSENTINEL_PLUGIN_GIT_COMMIT}

ARG ARG_MEMCACHED_PLUGIN_GIT_URL='https://github.com/moodlehq/moodle-cachestore_memcached'
ARG ARG_MEMCACHED_PLUGIN_GIT_BRANCH='master'
# renovate: datasource=git-refs depName=https://github.com/moodlehq/moodle-cachestore_memcached branch=master
ARG ARG_MEMCACHED_PLUGIN_GIT_COMMIT='db68d31ab5856cb55210478fdd452dc0cd6c6d05'
ENV MEMCACHED_PLUGIN_GIT_URL=${ARG_MEMCACHED_PLUGIN_GIT_URL}
ENV MEMCACHED_PLUGIN_GIT_BRANCH=${ARG_MEMCACHED_PLUGIN_GIT_BRANCH}
ENV MEMCACHED_PLUGIN_GIT_COMMIT=${ARG_MEMCACHED_PLUGIN_GIT_COMMIT}

ARG ARG_MOODLE_PLUGIN_LIST=''
ARG ARG_ALLOW_INCOMPATIBLE_PLUGIN='false'
ENV MOODLE_PLUGIN_LIST=${ARG_MOODLE_PLUGIN_LIST}
ENV ALLOW_INCOMPATIBLE_PLUGIN=${ARG_ALLOW_INCOMPATIBLE_PLUGIN}

# Download Moodle source codes and plugin source codes
RUN /usr/libexec/moodle/download-moodle-code \
    # Create a backup of custom code
    && cp -p /var/www/html/admin/cli/isinstalled.php /usr/libexec/moodle/
