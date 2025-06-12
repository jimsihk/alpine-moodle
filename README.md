# High Availability Moodle on Alpine Linux

[![Docker Pulls](https://img.shields.io/docker/pulls/jimsihk/alpine-moodle.svg)](https://hub.docker.com/r/jimsihk/alpine-moodle/)
![Docker Image Size](https://img.shields.io/docker/image-size/jimsihk/alpine-moodle)
![nginx 1.28](https://img.shields.io/badge/nginx-1.28-brightgreen.svg)
![php 8.4](https://img.shields.io/badge/php-8.4-brightgreen.svg)
![moodle-5.0](https://img.shields.io/badge/moodle-5.0-yellow)
![License MIT](https://img.shields.io/badge/license-MIT-blue.svg)

Moodle setup with high availability (HA) capabilities for Docker, build on [Alpine Linux](http://www.alpinelinux.org/).

Repository: https://github.com/jimsihk/alpine-moodle

* Based on official Moodle source https://github.com/moodle/moodle
* Built on the lightweight image https://github.com/jimsihk/alpine-php-nginx
* Smaller container image size (+/-150MB for full version, +/-90MB for slim version)
* Supports HA installation with multiple type of cache stores (memcached, Redis) and PostgresSQL poolers like PgBouncer
* Supports also Redis Sentinel as cache stores via plugin https://github.com/catalyst/moodle-cachestore_redissentinel
* Pre-install Moodle plug-ins at build time with argument `ARG_MOODLE_PLUGIN_LIST`
* Always up-to-date Moodle version and Alpine packages with Renovate (see below)
* Supports read-only replica of database
* Multi-arch support: 386, amd64, arm/v7, arm64, ppc64le, s390x
* Optimized for 100 concurrent users
* Optimized to only use resources when there's traffic (by using PHP-FPM's ondemand PM)
* JIT enabled by default
* Use of runit instead of supervisord to reduce memory footprint
* Configured cron to run as non-privileged user https://github.com/gliderlabs/docker-alpine/issues/381#issuecomment-621946699
* Configuration via ENV variables
* Auto update Moodle plugin and upgrade to newer Moodle versions (via `ARG_MOODLE_GIT_URL` and `ARG_MOODLE_GIT_BRANCH` at build time, `MOODLE_GIT_URL` and `MOODLE_GIT_BRANCH` at run time) when container start 
* The servers NGINX, PHP-FPM run under a non-privileged user (nobody) to make it more secure
* The logs of all the services are redirected to the output of the Docker container (visible with `docker logs -f <container name>`)
* Follows the KISS principle (Keep It Simple, Stupid) to make it easy to understand and adjust the image to your needs

## Automated Release

[![Renovate](https://img.shields.io/badge/renovate-enabled-yellow.svg)](https://app.renovatebot.com/dashboard)

Moodle version and package dependencies are monitored and automatically updated through pull requests by Renovate: https://github.com/renovatebot/renovate

[![Nightly Build](https://github.com/jimsihk/alpine-moodle/actions/workflows/nightly.yml/badge.svg)](https://github.com/jimsihk/alpine-moodle/actions/workflows/nightly.yml)

A nightly build in GitHub Action scans for changes, then performs tagging and publishes a newer release on container registries.

The release tag will be in pattern: **XXX.YYY.ZZ**
- **XXX** = Moodle Branch
- **YYY** = Moodle Release Increments & Incremental Changes Number based on `version.php` of Moodle source
- **ZZ** = Git Repo Releases

e.g. for Moodle 4.1.1+ branch _401_ version 20221128*01.06*, the release tag number will be starting from 401.106.0

## Multiple Container Registry
The images are available on multiple registries:
- DockerHub: https://hub.docker.com/r/jimsihk/alpine-moodle
- Quay.io: https://quay.io/repository/jimsihk/alpine-moodle

## Image Variants
#### alpine-moodle:XXX.YYY.ZZZ
- Standard version with full features
#### alpine-moodle:XXX.YYY.ZZZ-slim
- Even smaller container image size
- Git is not installed
- Removed in-place code upgrade functionality (i.e. ignored `UPDATE_MOODLE_CODE`)
- Controlled by build argument `ARG_ENABLE_GIT_CLONE` when build

## Usage

Start the Docker containers:
```
docker compose up
```
Start a Moodle cluster:
```
./generate_ssl_cert.sh
docker compose --file docker-compose.replica.yml up
```

Login on the system using the provided credentials (ENV vars)

#### Sample docker-compose files
* [docker-compose.yml](docker-compose.yml) - with PostgreSQL
* [docker-compose.replica.yml](docker-compose.replica.yml) - with PostgreSQL, Redis and multiple Moodle containers, using NGINX as load balancer with SSL termination
  * execute `generate_ssl_cert.sh` to generate a sample SSL certificate for localhost
  * refer to https://docs.moodle.org/en/Caching for setting up after login or set the `SESSION_CACHE_*` environment variables
  * please note this setup is NOT configured for production use, use it for demonstration only

## Configuration
Define the ENV variables in docker-compose.yml file

| Variable Name               | Default              | Description                                                                                                                                                     |
|-----------------------------|----------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------|
| LANG                        | en_US.UTF-8          |                                                                                                                                                                 |
| LANGUAGE                    | en_US:en             |                                                                                                                                                                 |
| SITE_URL                    | http://localhost     | Sets the public site URL                                                                                                                                        |
| SSLPROXY                    | false                | Disable SSL proxy to avoid site loop. e.g. Cloudflare                                                                                                           |
| DB_TYPE                     | pgsql                | mysqli - pgsql - mariadb                                                                                                                                        |
| DB_HOST                     | postgres             | Database hostname e.g. database container name                                                                                                                  |
| DB_PORT                     | 5432                 | PostgresSQL=5432 - MySQL/MariaDB=3306                                                                                                                           |
| DB_NAME                     | moodle               | Database name                                                                                                                                                   |
| DB_USER                     | moodle               | Database login username                                                                                                                                         |
| DB_PASS                     | moodle               | Database login password                                                                                                                                         |
| DB_FETCHBUFFERSIZE          |                      | Set to 0 if using PostgresSQL poolers like PgBouncer in 'transaction' mode                                                                                      |
| DB_DBHANDLEOPTIONS          | false                | Set to true if using PostgresSQL poolers like PgBouncer which does not support sending options                                                                  |
| DB_DBPERSIST                | false                | Set to true to keep database connected with Moodle PHP thread while active, may have performance gain but may also used up database connections                 |
| DB_HOST_REPLICA             |                      | Database hostname of the read-only replica database                                                                                                             |
| DB_PORT_REPLICA             |                      | Database port of replica, left it empty to be same as DB_PORT                                                                                                   |
| DB_USER_REPLICA             |                      | Database login username of replica, left it empty to be same as DB_USER                                                                                         |
| DB_PASS_REPLICA             |                      | Database login password of replica, left it empty to be same as DB_PASS                                                                                         |
| DB_PREFIX                   | mdl_                 | Database prefix. **WARNING**: don't use numeric values or Moodle won't start                                                                                    |
| MOODLE_EMAIL                | user@example.com     |                                                                                                                                                                 |
| MOODLE_LANGUAGE             | en                   |                                                                                                                                                                 |
| MOODLE_SITENAME             | New-Site             |                                                                                                                                                                 |
| MOODLE_SHORTNAME            | moodle               |                                                                                                                                                                 |
| MOODLE_USERNAME             | moodleuser           |                                                                                                                                                                 |
| MOODLE_PASSWORD             | PLEASE_CHANGEME      |                                                                                                                                                                 |
| SMTP_HOST                   | smtp.gmail.com       |                                                                                                                                                                 |
| SMTP_PORT                   | 587                  |                                                                                                                                                                 |
| SMTP_USER                   | your_email@gmail.com |                                                                                                                                                                 |
| SMTP_PASSWORD               | your_password        |                                                                                                                                                                 |
| SMTP_PROTOCOL               | tls                  |                                                                                                                                                                 |
| MOODLE_MAIL_NOREPLY_ADDRESS | noreply@localhost    |                                                                                                                                                                 |
| MOODLE_MAIL_PREFIX          | [moodle]             |                                                                                                                                                                 |
| memory_limit                | 128M                 | Maximum amount of memory that a PHP script is allowed to allocate _(default value inherited from base image)_                                                   |
| client_max_body_size        | 50M                  | Sets the maximum allowed size of the client request body, specified in the “Content-Length” request header field                                                |
| post_max_size               | 50M                  | Max size of post data allowed. This setting also affects file upload. To upload large files, this value must be larger than upload_max_filesize                 |
| upload_max_filesize         | 50M                  | Maximum size of an uploaded file.                                                                                                                               |
| max_input_vars              | 5000                 | Maximum number of input variables allowed per request, set to at least 5000                                                                                     |
| opcache_jit_buffer_size     | 64M                  | Amount of shared memory to reserve for compiled JIT code, set to 0 to disable the JIT                                                                           |
| opcache_jit                 | 1235                 | Configure the JIT mode _(default value inherited from base image)_                                                                                              |
| opcache_memory_consumption  | 128                  | Size of the shared memory storage used by OPcache in megabytes _(default value inherited from base image)_                                                      |
| SESSION_CACHE_TYPE          |                      | Optionally sets shared session cache store: memcached, redis, database _(leave it blank to keep unchanged)_                                                     |
| SESSION_CACHE_HOST          |                      | Hostname of the external cache store, required for memcached and redis                                                                                          |
| SESSION_CACHE_PORT          |                      | Memcached=11211, Redis=6379, required for memcached and redis                                                                                                   |
| SESSION_CACHE_PREFIX        | mdl                  | Cache prefix                                                                                                                                                    |
| SESSION_CACHE_AUTH          |                      | Authentication key for cache store, may be required for redis                                                                                                   |
| AUTO_UPDATE_MOODLE          | true                 | Set to false to disable performing update of Moodle (e.g. plugins) at docker start                                                                              |
| UPDATE_MOODLE_CODE          | true                 | Set to false to disable auto download latest patch of Moodle core code, only effective if AUTO_UPDATE_MOODLE is true or built with ARG_ENABLE_GIT_CLONE as true |
| DISABLE_WEB_INSTALL_PLUGIN  | false                | Set to true to disable plugin installation via site admin UI, could be useful to avoid image outsync with HA setting                                            |
| MAINT_STATUS_KEYWORD        | Status: enabled      | Keyword for detecting Moodle maintenance status when running admin/cli/maintenance.php, language following the Moodle site default language                     |
| LOCAL_CACHE_DIRECTORY       |                      | Set the path to a local fast filesystem for Moodle local caching that no need to be shared with other instances                                                 |
| SKIP_MOODLE_CONFIG          | false                | Set to true to skip the Moodle configuration script                                                                                                             |

_More settings on PHP and NGINX can refer to the base image https://github.com/jimsihk/alpine-php-nginx/blob/dev/README.md_

### Important Note about using `AUTO_UPDATE_MOODLE` and `UPDATE_MOODLE_CODE`

If set to `true`, Moodle will be set to [CLI maintenance mode](https://docs.moodle.org/401/en/Maintenance_mode#CLI_maintenance_mode) at container start while performing the update. No user will be able to use Moodle, not even admin.

If a cluster of Moodle containers are deployed for HA (e.g. on Kubernetes), it is suggested to set both to `false` to avoid unexpected interruption to users when auto scaling, such as adding extra containers to the cluster or container restart for auto healing.

## Custom builds
### Moodle plugins

#### `ARG_MOODLE_PLUGIN_LIST`: define the list of plugins
- For installing plugins while building the main Dockerfile (slower), use `ARG_MOODLE_PLUGIN_LIST`:
```
docker buildx build . -t my_moodle_image:my_tag \
    --build-arg ARG_MOODLE_PLUGIN_LIST='mod_attendance mod_checklist mod_customcert block_checklist gradeexport_checklist'
```
- For building only to install additional moodle plugins (faster), create a Dockerfile like the following and then build.
- Example of `Dockerfile.plugins`:
```dockerfile
# Dockerfile.plugins
FROM quay.io/jimsihk/alpine-moodle:latest

# Install additional plugins, a space/comma separated arg, (optional)
# Run install-plugin-list with argument "-f" to force install 
#   if the plugin is not compatible with current Moodle version
ARG ARG_MOODLE_PLUGIN_LIST=''
ENV MOODLE_PLUGIN_LIST=${ARG_MOODLE_PLUGIN_LIST}
RUN if [ -n "${MOODLE_PLUGIN_LIST}" ]; then /usr/libexec/moodle/install-plugin-list -p "${MOODLE_PLUGIN_LIST}"; fi && \
    rm -rf /tmp/moodle-plugins
```
- Since v4.2.1.02-2 (402.102.2), this could be further simplified into:
```dockerfile
# Dockerfile.plugins
FROM quay.io/jimsihk/alpine-moodle:latest

# Install additional plugins, a space/comma separated arg, (optional)
ARG ARG_MOODLE_PLUGIN_LIST=''
ENV MOODLE_PLUGIN_LIST=${ARG_MOODLE_PLUGIN_LIST}
RUN /usr/libexec/moodle/download-moodle-plugin
```
- Example of build using `Dockerfile.plugins`:
```
# Build
docker buildx build . -t my_moodle_image:my_tag \
    -f Dockerfile.plugins \
    --build-arg ARG_MOODLE_PLUGIN_LIST='mod_attendance,mod_checklist,mod_customcert,block_checklist,gradeexport_checklist'
```

#### `ARG_ALLOW_INCOMPATIBLE_PLUGIN`: allow installing incompatible plugins 
- Since v4.2.1.02-2 (402.102.2), `ARG_ALLOW_INCOMPATIBLE_PLUGIN` is also available to easily control if continue the installation of latest available version despite lack of compatibility from maturity, default as `false`:
```
docker buildx build . -t my_moodle_image:my_tag \
    --build-arg ARG_MOODLE_PLUGIN_LIST='mod_attendance mod_checklist mod_customcert block_checklist gradeexport_checklist' \
    --build-arg ARG_ALLOW_INCOMPATIBLE_PLUGIN='true'
```
- Or using a custom `Dockerfile.plugins`:
```dockerfile
# Dockerfile.plugins
FROM quay.io/jimsihk/alpine-moodle:latest

ARG ARG_MOODLE_PLUGIN_LIST='mod_attendance mod_checklist mod_customcert block_checklist gradeexport_checklist'
ARG ARG_ALLOW_INCOMPATIBLE_PLUGIN='true'
ENV MOODLE_PLUGIN_LIST=${ARG_MOODLE_PLUGIN_LIST}
ENV ALLOW_INCOMPATIBLE_PLUGIN=${ARG_ALLOW_INCOMPATIBLE_PLUGIN}
RUN /usr/libexec/moodle/download-moodle-plugin
```

## Known Issues
#### <del>Unable to Create/Update Moodle Roles with "Incorrect role short name" (https://github.com/erseco/alpine-moodle/issues/26)</del>
- <del>Workaround: install [Moosh](https://moodle.org/plugins/view.php?id=522) and use the `role-update-capability` command, but beware that only version 0.39 of the plugin has this command</del>
- **FIXED** since release v4.1.2.07-1 (401.207.1)

## Credits
- Plugin installation adopted from [Krestomatio](https://github.com/krestomatio/container_builder/tree/master/moodle)
