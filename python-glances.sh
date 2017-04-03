#!/bin/bash

# bail out if any part of this fails
set -e

# This is the self-extracting installer script for an FPM shell installer package.
# It contains the logic to unpack a tar archive appended to the end of this script
# and, optionally, to run post install logic.
# Run the package file with -h to see a usage message or look at the print_usage method.
#
# The post install scripts are called with INSTALL_ROOT, INSTALL_DIR and VERBOSE exported
# into the environment for their use.
#
# INSTALL_ROOT = the path passed in with -i or a relative directory of the name of the package
#                file with no extension
# INSTALL_DIR  = the same as INSTALL_ROOT unless -c (capistrano release directory) argumetn
#                is used. Then it is $INSTALL_ROOT/releases/<datestamp>
# CURRENT_DIR  = if -c argument is used, this is set to the $INSTALL_ROOT/current which is
#                symlinked to INSTALL_DIR
# VERBOSE      = is set if the package was called with -v for verbose output
function main() {
    set_install_dir

    if ! slug_already_current ; then

      create_pid
      wait_for_others
      kill_others
      set_owner
      pre_install
      unpack_payload

      if [ "$UNPACK_ONLY" == "1" ] ; then
          echo "Unpacking complete, not moving symlinks or restarting because unpack only was specified."
      else
          create_symlinks

          set +e # don't exit on errors to allow us to clean up
          if ! run_post_install ; then
              revert_symlinks
              log "Installation failed."
              exit 1
          else
              clean_out_old_releases
              log "Installation complete."
          fi
      fi

    else
        echo "This slug is already installed in 'current'. Specify -f to force reinstall. Exiting."
    fi
}

# check if this slug is already running and exit unless `force` specified
# Note: this only works with RELEASE_ID is used
function slug_already_current(){
    local this_slug=$(basename $0 .slug)
    local current=$(basename "$(readlink ${INSTALL_ROOT}/current)")
    log "'current' symlink points to slug: ${current}"

    if [ "$this_slug" == "$current" ] ; then
        if [ "$FORCE" == "1" ] ; then
        log "Force was specified. Proceeding with install after renaming live directory to allow running service to shutdown correctly."
            local real_dir=$(readlink ${INSTALL_ROOT}/current)
            if [ -e ${real_dir}.old ] ; then
                # remove that .old directory, if needed
                log "removing existing .old version of release"
                rm -rf ${real_dir}.old
            fi
            mv ${real_dir} ${real_dir}.old
            mkdir -p ${real_dir}
        else
            return 0;
        fi
    fi
    return 1;
}

# deletes the PID file for this installation
function delete_pid(){
    rm -f ${INSTALL_ROOT}/$$.pid 2> /dev/null
}

# creates a PID file for this installation
function create_pid(){
    trap "delete_pid" EXIT
    echo $$> ${INSTALL_ROOT}/$$.pid
}


# checks for other PID files and sleeps for a grace period if found
function wait_for_others(){
    local count=`ls ${INSTALL_ROOT}/*.pid | wc -l`

    if [ $count -gt 1 ] ; then
        sleep 10
    fi
}

# kills other running installations
function kill_others(){
    for PID_FILE in $(ls ${INSTALL_ROOT}/*.pid) ; do
        local p=`cat ${PID_FILE}`
        if ! [ $p == $$ ] ; then
            kill -9 $p
            rm -f $PID_FILE 2> /dev/null
        fi
    done
}

# echos metadata file. A function so that we can have it change after we set INSTALL_ROOT
function fpm_metadata_file(){
    echo "${INSTALL_ROOT}/.install-metadata"
}

# if this package was installed at this location already we will find a metadata file with the details
# about the installation that we left here. Load from that if available but allow command line args to trump
function load_environment(){
    local METADATA=$(fpm_metadata_file)
    if [ -r "${METADATA}" ] ; then
        log "Found existing metadata file '${METADATA}'. Loading previous install details. Env vars in current environment will take precedence over saved values."
        local TMP="/tmp/$(basename $0).$$.tmp"
        # save existing environment, load saved environment from previous run from install-metadata and then
        # overlay current environment so that anything set currencly will take precedence
        # but missing values will be loaded from previous runs.
        save_environment "$TMP"
        source "${METADATA}"
        source $TMP
        rm "$TMP"
    fi
}

# write out metadata for future installs
function save_environment(){
    local METADATA=$1
    echo -n "" > ${METADATA} # empty file

    # just piping env to a file doesn't quote the variables. This does
    # filter out multiline junk, _, and functions. _ is a readonly variable.
    env | grep -v "^_=" | grep -v "^[^=(]*()=" | egrep "^[^ ]+=" | while read ENVVAR ; do
        local NAME=${ENVVAR%%=*}
        # sed is to preserve variable values with dollars (for escaped variables or $() style command replacement),
        # and command replacement backticks
        # Escaped parens captures backward reference \1 which gets replaced with backslash and \1 to esape them in the saved
        # variable value
        local VALUE=$(eval echo '$'$NAME | sed 's/\([$`]\)/\\\1/g')
        echo "export $NAME=\"$VALUE\"" >> ${METADATA}
    done

    if [ -n "${OWNER}" ] ; then
        chown ${OWNER} ${METADATA}
    fi
}

function set_install_dir(){
    # if INSTALL_ROOT isn't set by parsed args, use basename of package file with no extension
    DEFAULT_DIR=$(echo $(basename $0) | sed -e 's/\.[^\.]*$//')
    INSTALL_DIR=${INSTALL_ROOT:-$DEFAULT_DIR}

    DATESTAMP=$(date +%Y%m%d%H%M%S)
    if [ -z "$USE_FLAT_RELEASE_DIRECTORY" ] ; then
        
        INSTALL_DIR="${RELEASES_DIR}/${RELEASE_ID:-$DATESTAMP}"
    fi

    mkdir -p "$INSTALL_DIR" || die "Unable to create install directory $INSTALL_DIR"

    export INSTALL_DIR

    log "Installing package to '$INSTALL_DIR'"
}

function set_owner(){
    export OWNER=${OWNER:-$USER}
    log "Installing as user $OWNER"
}

function pre_install() {
    # for rationale on the `:`, see #871
    :

}

function unpack_payload(){
    if [ "$FORCE" == "1" ] || [ ! "$(ls -A $INSTALL_DIR)" ] ; then
        log "Unpacking payload . . ."
        local archive_line=$(grep -a -n -m1 '__ARCHIVE__$' $0 | sed 's/:.*//')
        tail -n +$((archive_line + 1)) $0 | tar -C $INSTALL_DIR -xf - > /dev/null || die "Failed to unpack payload from the end of '$0' into '$INSTALL_DIR'"
    else
        # Files are already here, just move symlinks
        log "Directory already exists and has contents ($INSTALL_DIR). Not unpacking payload."
    fi
}

function run_post_install(){
    local AFTER_INSTALL=$INSTALL_DIR/.fpm/after_install
    if [ -r $AFTER_INSTALL ] ; then
        set_post_install_vars
        chmod +x $AFTER_INSTALL
        log "Running post install script"
        output=$($AFTER_INSTALL 2>&1)
        errorlevel=$?
        log $output
        return $errorlevel
    fi
    return 0
}

function set_post_install_vars(){
    # for rationale on the `:`, see #871
    :
    
}

function create_symlinks(){
    [ -n "$USE_FLAT_RELEASE_DIRECTORY" ] && return

    export CURRENT_DIR="$INSTALL_ROOT/current"
    if [ -e "$CURRENT_DIR" ] || [ -h "$CURRENT_DIR" ] ; then
        log "Removing current symlink"
        OLD_CURRENT_TARGET=$(readlink $CURRENT_DIR)
        rm "$CURRENT_DIR"
    fi
    ln -s "$INSTALL_DIR" "$CURRENT_DIR"

    log "Symlinked '$INSTALL_DIR' to '$CURRENT_DIR'"
}

# in case post install fails we may have to back out switching the symlink to current
# We can't switch the symlink after because post install may assume that it is in the
# exact state of being installed (services looking to current for their latest code)
function revert_symlinks(){
    if [ -n "$OLD_CURRENT_TARGET" ] ; then
        log "Putting current symlink back to '$OLD_CURRENT_TARGET'"
        if [ -e "$CURRENT_DIR" ] ; then
            rm "$CURRENT_DIR"
        fi
        ln -s "$OLD_CURRENT_TARGET" "$CURRENT_DIR"
    fi
}

function clean_out_old_releases(){
    [ -n "$USE_FLAT_RELEASE_DIRECTORY" ] && return

    if [ -n "$OLD_CURRENT_TARGET" ] ; then
        # exclude old 'current' from deletions
        while [ $(ls -tr "${RELEASES_DIR}" | grep -v ^$(basename "${OLD_CURRENT_TARGET}")$ | wc -l) -gt 2 ] ; do
            OLDEST_RELEASE=$(ls -tr "${RELEASES_DIR}" | grep -v ^$(basename "${OLD_CURRENT_TARGET}")$ | head -1)
            log "Deleting old release '${OLDEST_RELEASE}'"
            rm -rf "${RELEASES_DIR}/${OLDEST_RELEASE}"
        done
    else
        while [ $(ls -tr "${RELEASES_DIR}" | wc -l) -gt 2 ] ; do
            OLDEST_RELEASE=$(ls -tr "${RELEASES_DIR}" | head -1)
            log "Deleting old release '${OLDEST_RELEASE}'"
            rm -rf "${RELEASES_DIR}/${OLDEST_RELEASE}"
        done
    fi
}

function print_package_metadata(){
    local metadata_line=$(grep -a -n -m1 '__METADATA__$' $0 | sed 's/:.*//')
    local archive_line=$(grep -a -n -m1 '__ARCHIVE__$' $0 | sed 's/:.*//')
    sed -n "$((metadata_line + 1)),$((archive_line - 1)) p" $0
}

function print_usage(){
    echo "Usage: `basename $0` [options]"
    echo "Install this package"
    echo "  -i <DIRECTORY> : install_root - an optional directory to install to."
    echo "      Default is package file name without file extension"
    echo "  -o <USER>     : owner - the name of the user that will own the files installed"
    echo "                   by the package. Defaults to current user"
    echo "  -r: disable capistrano style release directories - Default behavior is to create a releases directory inside"
    echo "      install_root and unpack contents into a date stamped (or build time id named) directory under the release"
    echo "      directory. Then create a 'current' symlink under install_root to the unpacked"
    echo "      directory once installation is complete replacing the symlink if it already "
    echo "      exists. If this flag is set just install into install_root directly"
    echo "  -u: Unpack the package, but do not install and symlink the payload"
    echo "  -f: force - Always overwrite existing installations"
    echo "  -y: yes - Don't prompt to clobber existing installations"
    echo "  -v: verbose - More output on installation"
    echo "  -h: help -  Display this message"
}

function die () {
    local message=$*
    echo "Error: $message : $!"
    exit 1
}

function log(){
    local message=$*
    if [ -n "$VERBOSE" ] ; then
        echo "$*"
    fi
}

function parse_args() {
    args=`getopt mi:o:rfuyvh $*`

    if [ $? != 0 ] ; then
        print_usage
        exit 2
    fi
    set -- $args
    for i
    do
        case "$i"
            in
            -m)
                print_package_metadata
                exit 0
                shift;;
            -r)
                USE_FLAT_RELEASE_DIRECTORY=1
                shift;;
            -i)
                shift;
                export INSTALL_ROOT="$1"
                export RELEASES_DIR="${INSTALL_ROOT}/releases"
                shift;;
            -o)
                shift;
                export OWNER="$1"
                shift;;
            -v)
                export VERBOSE=1
                shift;;
            -u)
                UNPACK_ONLY=1
                shift;;
            -f)
                FORCE=1
                shift;;
            -y)
                CONFIRM="y"
                shift;;
            -h)
                print_usage
                exit 0
                shift;;
            --)
                shift; break;;
        esac
    done
}

# parse args first to get install root
parse_args $*
# load environment from previous installations so we get defaults from that
load_environment
# reparse args so they can override any settings from previous installations if provided on the command line
parse_args $*

main
save_environment $(fpm_metadata_file)
exit 0

__METADATA__

__ARCHIVE__
./                                                                                                  0000775 0000000 0000000 00000000000 13070471670 006110  5                                                                                                    ustar                                                                                                                                                                                                                                                          ./usr/                                                                                              0000775 0000000 0000000 00000000000 13070471670 006721  5                                                                                                    ustar                                                                                                                                                                                                                                                          ./usr/local/                                                                                        0000775 0000000 0000000 00000000000 13070471670 010013  5                                                                                                    ustar                                                                                                                                                                                                                                                          ./usr/local/share/                                                                                  0000775 0000000 0000000 00000000000 13070471670 011115  5                                                                                                    ustar                                                                                                                                                                                                                                                          ./usr/local/share/doc/                                                                              0000775 0000000 0000000 00000000000 13070471670 011662  5                                                                                                    ustar                                                                                                                                                                                                                                                          ./usr/local/share/doc/glances/                                                                      0000775 0000000 0000000 00000000000 13070471670 013276  5                                                                                                    ustar                                                                                                                                                                                                                                                          ./usr/local/share/doc/glances/NEWS                                                                  0000664 0000000 0000000 00000100230 13066703446 013775  0                                                                                                    ustar                                                                                                                                                                                                                                                          ==============================================================================
Glances Version 2
==============================================================================

Version 2.9.1
=============

Bugs corrected:

    * Glances PerCPU issues with Curses UI on Android (issue #1071)
    * Remove extra } in format string (issue #1073)
    
Version 2.9.0
=============

Enhancements and new features:

    * Add a Prometheus export module (issue #930)
    * Add a Kafka export module (issue #858)
    * Port in the -c URI (-c hostname:port) (issue #996)

Bugs corrected:

    * On Windows --export-statsd terminates immediately and does not export (issue #1067)
    * Glances v2.8.7 issues with Curses UI on Android (issue #1053)
    * Fails to start, OSError in sensors_temperatures (issue #1057)
    * Crashs after long time running the glances --browser (issue #1059)
    * Sensor values don't refresh since psutil backend (issue #1061)
    * glances-version.db Permission denied (issue #1066)

Version 2.8.8
=============

Bugs corrected:

    * Drop requests to check for outdated Glances version
    *  Glances cannot load "Powersupply" (issue #1051)

Version 2.8.7
=============

Bugs corrected:

    * Windows OS - Global name standalone not defined again (issue #1030)

Version 2.8.6
=============

Bugs corrected:

    * Windows OS - Global name standalone not defined (issue #1030)

Version 2.8.5
=============

Bugs corrected:

    * Cloud plugin error: Name 'requests' is not defined (issue #1047)

Version 2.8.4
=============

Bugs corrected:

    * Correct issue on Travis CI test

Version 2.8.3
=============

Enhancements and new features:

    * Use new sensors-related APIs of Psutil 5.1.0 (issue #1018)
    * Add a "Cloud" plugin to grab stats inside the AWS EC2 API (issue #1029)

Bugs corrected:

    * Unable to launch Glances on Windows (issue #1021)
    * Glances --export-influxdb starts Webserver (issue #1038)
    * Cut mount point name if it is too long (issue #1045)
    * TypeError: string indices must be integers in per cpu (issue #1027)
    * Glances crash on RPi 1 running ArchLinuxARM (issue #1046)

Version 2.8.2
=============

Bugs corrected:

    * InfluxDB export in 2.8.1 is broken (issue #1026)

Version 2.8.1
=============

Enhancements and new features:

    * Enable docker plugin on Windows (issue #1009) - Thanks to @fraoustin

Bugs corrected:

    * Glances export issue with CPU and SENSORS (issue #1024)
    * Can't export data to a CSV file in Client/Server mode (issue #1023)
    * Autodiscover error while binding on IPv6 addresses (issue #1002)
    * GPU plugin is display when hitting '4' or '5' shortkeys (issue #1012)
    * Interrupts and usb_fiq (issue #1007)
    * Docker image does not work in web server mode! (issue #1017)
    * IRQ plugin is not display anymore (issue #1013)
    * Autodiscover error while binding on IPv6 addresses (issue #1002)

Version 2.8
===========

Changes:

    * The curses interface on Windows is no more. The web-based interface is now
      the default. (issue #946)
    * The name of the log file now contains the name of the current user logged in,
      i.e., 'glances-USERNAME.log'.
    * IRQ plugin off by default. '--disable-irq' option replaced by '--enable-irq'.

Enhancements and new features:

    * GPU monitoring (limited to NVidia) (issue #170)
    * WebUI CPU consumption optimization (issue #836)
    * Not compatible with the new Docker API 2.0 (Docker 1.13) (issue #1000)
    * Add ZeroMQ exporter (issue #939)
    * Add CouchDB exporter (issue #928)
    * Add hotspot Wifi informations (issue #937)
    * Add default interface speed and automatic rate thresolds (issue #718)
    * Highlight max stats in the processes list (issue #878)
    * Docker alerts and actions (issue #875)
    * Glances API returns the processes PPID (issue #926)
    * Configure server cached time from the command line --cached-time (issue #901)
    * Make the log logger configurable (issue #900)
    * System uptime in export (issue #890)
    * Refactor the --disable-* options (issue #948)
    * PID column too small if kernel.pid_max is > 99999 (issue #959)

Bugs corrected:

    * Glances RAID plugin Traceback (issue #927)
    * Default AMP crashes when 'command' given (issue #933)
    * Default AMP ignores `enable` setting (issue #932)
    * /proc/interrupts not found in an OpenVZ container (issue #947)

Version 2.7.1
=============

Bugs corrected:

    * AMP plugin crashs on start with Python 3 (issue #917)
    * Ports plugin crashs on start with Python 3 (issue #918)

Version 2.7
===========

Backward-incompatible changes:

    * Drop support for Python 2.6 (issue #300)

Deprecated:

    * Monitoring process list module is replaced by AMP (see issue #780)
    * Use --export-graph instead of --enable-history (issue #696)
    * Use --path-graph instead of --path-history (issue #696)

Enhancements and new features:

    * Add Application Monitoring Process plugin (issue #780)
    * Add a new "Ports scanner" plugin (issue #734)
    * Add a new IRQ monitoring plugin (issue #911)
    * Improve IP plugin to display public IP address (issue #646)
    * CPU additionnal stats monitoring: Context switch, Interrupts... (issue #810)
    * Filter processes by others stats (username) (issue #748)
    * [Folders] Differentiate permission issue and non-existence of a directory (issue #828)
    * [Web UI] Add cpu name in quicklook plugin (issue #825)
    * Allow theme to be set in configuration file (issue #862)
    * Display a warning message when Glances is outdated (issue #865)
    * Refactor stats history and export to graph. History available through API (issue #696)
    * Add Cassandra/Scylla export plugin (issue #857)
    * Huge pull request by Nicolas Hart to optimize the WebUI (issue #906)
    * Improve documentation: http://glances.readthedocs.io (issue #872)

Bugs corrected:

    * Crash on launch when viewing temperature of laptop HDD in sleep mode (issue #824)
    * [Web UI] Fix folders plugin never displayed (issue #829)
    * Correct issue IP plugin: VPN with no internet access (issue #842)
    * Idle process is back on FreeBSD and Windows (issue #844)
    * On Windows, Glances try to display unexisting Load stats (issue #871)
    * Check CPU info (issue #881)
    * Unicode error on processlist on Windows server 2008 (french) (issue #886)
    * PermissionError/OSError when starting glances (issue #885)
    * Zeroconf problem with zeroconf_type = "_%s._tcp." % __appname__ (issue #888)
    * Zeroconf problem with zeroconf service name (issue #889)
    * [WebUI] Glances will not get past loading screen - Windows OS (issue #815)
    * Improper bytes/unicode in glances_hddtemp.py (issue #887)
    * Top 3 processes are back in the alert summary

Code quality follow up: from 5.93 to 6.24 (source: https://scrutinizer-ci.com/g/nicolargo/glances)

Version 2.6.2
=============

Bugs corrected:

    * Crash with Docker 1.11 (issue #848)

Version 2.6.1
=============

Enhancements and new features:

    * Add a connector to Riemann (issue #822 by Greogo Nagy)

Bugs corrected:

    * Browsing for servers which are in the [serverlist] is broken (issue #819)
    * [WebUI] Glances will not get past loading screen (issue #815) opened 9 days ago
    * Python error after upgrading from 2.5.1 to 2.6 bug (issue #813)

Version 2.6
===========

Deprecations:

    * Add deprecation warning for Python 2.6.
      Python 2.6 support will be dropped in future releases.
      Please switch to at least Python 2.7 or 3.3+ as soon as possible.
      See http://www.snarky.ca/stop-using-python-2-6 for more information.

Enhancements and new features:

    * Add a connector to ElasticSearch (welcome to Kibana dashboard) (issue #311)
    * New folders' monitoring plugins (issue #721)
    * Use wildcard (regexp) to the hide configuration option for network, diskio and fs sections (issue #799 )
    * Command line arguments are now take into account in the WebUI (#789 by  @notFloran)
    * Change username for server and web server authentication (issue #693)
    * Add an option to disable top menu (issue #766)
    * Add IOps in the DiskIO plugin (issue #763)
    * Add hide configuration key for FS Plugin (issue #736)
    * Add process summary min/max stats (issue #703)
    * Add timestamp to the CSV export module (issue #708)
    * Add a shortcut 'E' to delete process filter (issue #699)
    * By default, hide disk I/O ram1-** (issue #714)
    * When Glances is starting the notifications should be delayed (issue #732)
    * Add option (--disable-bg) to disable ANSI background colours (issue #738 by okdana)
    * [WebUI] add "pointer" cursor for sortable columns (issue #704 by @notFloran)
    * [WebUI] Make web page title configurable (issue #724)
    * Do not show interface in down state (issue #765)
    * InfluxDB > 0.9.3 needs float and not int for numerical value (issue#749 and issue#750 by nicolargo)

Bugs corrected:

    * Can't read sensors on a Thinkpad (issue #711)
    * InfluxDB/OpenTSDB: tag parsing broken (issue #713)
    * Grafana Dashboard outdated for InfluxDB 0.9.x (issue #648)
    * '--tree' breaks process filter on Debian 8 (issue #768)
    * Fix highlighting of process when it contains whitespaces (issue #546 by Alessio Sergi)
    * Fix RAID support in Python 3 (issue #793 by Alessio Sergi)
    * Use dict view objects to avoid issue (issue #758 by Alessio Sergi)
    * System exit if Cpu not supported by the Cpuinfo lib (issue #754 by nicolargo)
    * KeyError: 'cpucore' when exporting data to InfluxDB (issue #729) by nicolargo)

Others:
    * A new Glances docker container to monitor your Docker infrastructure is available here (issue #728): https://hub.docker.com/r/nicolargo/glances/
    * Documentation is now generated automatically thanks to Sphinx and the Alessio Sergi patch (https://glances.readthedocs.io/en/latest/)

Contributors summary:
    * Nicolas Hennion: 112 commits
    * Alessio Sergi: 55 commits
    * Floran Brutel: 19 commits
    * Nicolas Hart: 8 commits
    * @desbma: 4 commits
    * @dana: 2 commits
    * Damien Martin, Raju Kadam, @georgewhewell: 1 commit

Version 2.5.1
=============

Bugs corrected:

    * Unable to unlock password protected servers in browser mode bug (issue #694)
    * Correct issue when Glances is started in console on Windows OS
    * [WebUI] when alert is ongoing hide level enhancement (issue #692)

Version 2.5
===========

Enhancements and new features:

    * Allow export of Docker and sensors plugins stats to InfluxDB, StatsD... (issue #600)
    * Docker plugin shows IO and network bitrate (issue #520)
    * Server password configuration for the browser mode (issue #500)
    * Add support for OpenTSDB export (issue #638)
    * Add additional stats (iowait, steal) to the perCPU plugin (issue #672)
    * Support Fahrenheit unit in the sensor plugin using the --fahrenheit command line option (issue #620)
    * When a process filter is set, display sum of CPU, MEM... (issue #681)
    * Improve the QuickLookplugin by adding hardware CPU info (issue #673)
    * WebUI display a message if server is not available (issue #564)
    * Display an error if export is not used in the standalone/client mode (issue #614)
    * New --disable-quicklook, --disable-cpu, --disable-mem, --disable-swap, --disable-load tags (issue #631)
    * Complete refactoring of the WebUI thanks to the (awesome) Floran pull (issue #656)
    * Network cumulative /combination feature available in the WebUI (issue #552)
    * IRIX mode off implementation (issue#628)
    * Short process name displays arguments (issue #609)
    * Server password configuration for the browser mode (issue #500)
    * Display an error if export is not used in the standalone/client mode (issue #614)

Bugs corrected:

    * The WebUI displays bad sensors stats (issue #632)
    * Filter processes crashs with a bad regular expression pattern (issue #665)
    * Error with IP plugin (issue #651)
    * Crach with Docker plugin (issue #649)
    * Docker plugin crashs with webserver mode (issue #654)
    * Infrequently crashing due to assert (issue #623)
    * Value for free disk space is counterintuative on ext file systems (issue #644)
    * Try/catch for unexpected psutil.NoSuchProcess: process no longer exists (issue #432)
    * Fatal error using Python 3.4 and Docker plugin bug (issue #602)
    * Add missing new line before g man option (issue #595)
    * Remove unnecessary type="text/css" for link (HTML5) (issue #595)
    * Correct server mode issue when no network interface is available (issue #528)
    * Avoid crach on olds kernels (issue #554)
    * Avoid crashing if LC_ALL is not defined by user (issue #517)
    * Add a disable HDD temperature option on the command line (issue #515)


Version 2.4.2
=============

Bugs corrected:

    * Process no longer exists (again) (issue #613)
    * Crash when "top extended stats" is enabled on OS X (issue #612)
    * Graphical percentage bar displays "?" (issue #608)
    * Quick look doesn't work (issue #605)
    * [Web UI] Display empty Battery sensors enhancement (issue #601)
    * [Web UI] Per CPU plugin has to be improved (issue #566)

Version 2.4.1
=============

Bugs corrected:

    * Fatal error using Python 3.4 and Docker plugin bug (issue #602)

Version 2.4
===========

Changes:

    * Glances doesn't provide a system-wide configuration file by default anymore.
      Just copy it in any of the supported locations. See glances-doc.html for
      more information. (issue #541)
    * The default key bindings have been changed to:
      - 'u': sort processes by USER
      - 'U': show cumulative network I/O
    * No more translations

Enhancements and new features:

    * The Web user interface is now based on AngularJS (issue #473, #508, #468)
    * Implement a 'quick look' plugin (issue #505)
    * Add sort processes by USER (issue #531)
    * Add a new IP information plugin (issue #509)
    * Add RabbitMQ export module (issue #540 Thk to @Katyucha)
    * Add a quiet mode (-q), can be useful using with export module
    * Grab FAN speed in the Glances sensors plugin (issue #501)
    * Allow logical mounts points in the FS plugin (issue #448)
    * Add a --disable-hddtemp to disable HDD temperature module at startup (issue #515)
    * Increase alert minimal delay to 6 seconds (issue #522)
    * If the Curses application raises an exception, restore the terminal correctly (issue #537)

Bugs corrected:

    * Monitor list, all processes are take into account (issue #507)
    * Duplicated --enable-history in the doc (issue #511)
    * Sensors title is displayed if no sensors are detected (issue #510)
    * Server mode issue when no network interface is available (issue #528)
    * DEBUG mode activated by default with Python 2.6 (issue #512)
    * Glances display of time trims the hours showing only minutes and seconds (issue #543)
    * Process list header not decorating when sorting by command (issue #551)

Version 2.3
===========

Enhancements and new features:

    * Add the Docker plugin (issue #440) with per container CPU and memory monitoring (issue #490)
    * Add the RAID plugin (issue #447)
    * Add actions on alerts (issue #132). It is now possible to run action (command line) by triggers. Action could contain {{tag}} (Mustache) with stat value.
    * Add InfluxDB export module (--export-influxdb) (issue #455)
    * Add StatsD export module (--export-statsd) (issue #465)
    * Refactor export module (CSV export option is now --export-csv). It is now possible to export stats from the Glances client mode (issue #463)
    * The Web inteface is now based on Bootstrap / RWD grid (issue #417, #366 and #461) Thanks to Nicolas Hart @nclsHart
    * It is now possible, through the configuration file, to define if an alarm should be logged or not (using the _log option) (issue #437)
    * You can now set alarm for Disk IO
    * API: add getAllLimits and getAllViews methods (issue #481) and allow CORS request (issue #479)
    * SNMP client support NetApp appliance (issue #394)

Bugs corrected:

    *  R/W error with the glances.log file (issue #474)

Other enhancement:

    * Alert < 3 seconds are no longer displayed

Version 2.2.1
=============

    * Fix incorrect kernel thread detection with --hide-kernel-threads (issue #457)
    * Handle IOError exception if no /etc/os-release to use Glances on Synology DSM (issue #458)
    * Check issue error in client/server mode (issue #459)

Version 2.2
===========

Enhancements and new features:

    * Add centralized curse interface with a Glances servers list to monitor (issue #418)
    * Add processes tree view (--tree) (issue #444)
    * Improve graph history feature (issue #69)
    * Extended stats is disable by default (use --enable-process-extended to enable it - issue #430)
    * Add a short key ('F') and a command line option (--fs-free-space) to display FS free space instead of used space (issue #411)
    * Add a short key ('2') and a command line option (--disable-left-sidebar) to disable/enable the side bar (issue #429)
    * Add CPU times sort short key ('t') in the curse interface (issue #449)
    * Refactor operating system detection for GNU/Linux operating system
    * Code optimization

Bugs corrected:

    * Correct a bug with Glances pip install --user (issue #383)
    * Correct issue on battery stat update (issue #433)
    * Correct issue on process no longer exist (issues #414 and #432)

Version 2.1.2
=============

    Maintenance version (only needed for Mac OS X).

Bugs corrected:

    * Mac OS X: Error if Glances is not ran with sudo (issue #426)

Version 2.1.1
=============

Enhancement:

    * Automaticaly compute top processes number for the current screen (issue #408)
    * CPU and Memory footprint optimization (issue #401)

Bugs corrected:

    * Mac OS X 10.9: Exception at start (issue #423)
    * Process no longer exists (issue #421)
    * Error with Glances Client with Python 3.4.1 (issue #419)
    * TypeError: memory_maps() takes exactly 2 arguments (issue #413)
    * No filesystem informations since Glances 2.0 bug enhancement (issue #381)

Version 2.1
===========

    * Add user process filter feature
      User can define a process filter pattern (as a regular expression).
      The pattern could be defined from the command line (-f <pattern>)
      or by pressing the ENTER key in the curse interface.
      For the moment, process filter feature is only available in standalone mode.
    * Add extended processes informations for top process
      Top process stats availables: CPU affinity, extended memory information (shared, text, lib, datat, dirty, swap), open threads/files and TCP/UDP network sessions, IO nice level
      For the moment, extended processes stats are only available in standalone mode.
    * Add --process-short-name tag and '/' key to switch between short/command line
    * Create a max_processes key in the configuration file
      The goal is to reduce the number of displayed processes in the curses UI and
      so limit the CPU footprint of the Glances standalone mode.
      The API always return all the processes, the key is only active in the curses UI.
      If the key is not define, all the processes will be displayed.
      The default value is 20 (processes displayed).
      For the moment, this feature is only available in standalone mode.
    * Alias for network interfaces, disks and sensors
      Users can configure alias from the Glances configuration file.
    * Add Glances log message (in the /tmp/glances.log file)
      The default log level is INFO, you can switch to the DEBUG mode using the -d option on the command line.
    * Add RESTFul API to the Web server mode
      RestFul API doc: https://github.com/nicolargo/glances/wiki/The-Glances-RESTFULL-JSON-API
    * Improve SNMP fallback mode for Cisco IOS, VMware ESXi
    * Add --theme-white feature to optimize display for white background
    * Experimental history feature (--enable-history option on the command line)
      This feature allows users to generate graphs within the curse interface.
      Graphs are available for CPU, LOAD and MEM.
      To generate graph, click on the 'g' key.
      To reset the history, press the 'r' key.
      Note: This feature uses the matplotlib library.
    * CI: Improve Travis coverage

Bugs corrected:

    * Quitting glances leaves a column layout to the current terminal (issue #392)
    * Glances crashes with malformed UTF-8 sequences in process command lines (issue #391)
    * SNMP fallback mode is not Python 3 compliant (issue #386)
    * Trouble using batinfo, hddtemp, pysensors w/ Python (issue #324)


Version 2.0.1
=============

Maintenance version.

Bugs corrected:

    * Error when displaying numeric process user names (#380)
    * Display users without username correctly (#379)
    * Bug when parsing configuration file (#378)
    * The sda2 partition is not seen by glances (#376)
    * Client crash if server is ended during XML request (#375)
    * Error with the Sensors module on Debian/Ubuntu (#373)
    * Windows don't view all processes (#319)

Version 2.0
===========

    Glances v2.0 is not a simple upgrade of the version 1.x but a complete code refactoring.
    Based on a plugins system, it aims at providing an easy way to add new features.
    - Core defines the basics and commons functions.
    - all stats are grabbed through plugins (see the glances/plugins source folder).
    - also outputs methods (Curse, Web mode, CSV) are managed as plugins.

    The Curse interface is almost the same than the version 1.7. Some improvements have been made:
    - space optimisation for the CPU, LOAD and MEM stats (justified alignment)
    - CPU:
        . CPU stats are displayed as soon as Glances is started
        . steal CPU alerts are no more logged
    - LOAD:
        . 5 min LOAD alerts are no more logged
    - File System:
        . Display the device name (if space is available)
    - Sensors:
        . Sensors and HDD temperature are displayed in the same block
    - Process list:
        . Refactor columns: CPU%, MEM%, VIRT, RES, PID, USER, NICE, STATUS, TIME, IO, Command/name
        . The running processes status is highlighted
        . The process name is highlighted in the command line

    Glances 2.0 brings a brand new Web Interface. You can run Glances in Web server mode and
    consult the stats directly from a standard Web Browser.

    The client mode can now fallback to a simple SNMP mode if Glances server is not found on the remote machine.

    Complete release notes:
    * Cut ifName and DiskName if they are too long in the curses interface (by Nicolargo)
    * Windows CLI is OK but early experimental (by Nicolargo)
    * Add bitrate limits to the networks interfaces (by Nicolargo)
    * Batteries % stats are now in the sensors list (by Nicolargo)
    * Refactor the client/server password security: using SHA256 (by Nicolargo,
      based on Alessio Sergi's example script)
    * Refactor the CSV output (by Nicolargo)
    * Glances client fallback to SNMP server if Glances one not found (by Nicolargo)
    * Process list: Highlight running/basename processes (by Alessio Sergi)
    * New Web server mode thk to the Bottle library (by Nicolargo)
    * Responsive design for Bottle interface (by Nicolargo)
    * Remove HTML output (by Nicolargo)
    * Enable/disable for optional plugins through the command line (by Nicolargo)
    * Refactor the API (by Nicolargo)
    * Load-5 alert are no longer logged (by Nicolargo)
    * Rename In/Out by Read/Write for DiskIO according to #339 (by Nicolargo)
    * Migrate from pysensors to py3sensors (by Alessio Sergi)
    * Migration to PsUtil 2.x (by Nicolargo)
    * New plugins system (by Nicolargo)
    * Python 2.x and 3.x compatibility (by Alessio Sergi)
    * Code quality improvements (by Alessio Sergi)
    * Refactor unitaries tests (by Nicolargo)
    * Development now follow the git flow workflow (by Nicolargo)


==============================================================================
Glances Version 1
==============================================================================

Version 1.7.7
=============

    * Fix CVS export [issue #348]
    * Adapt to PSUtil 2.1.1
    * Compatibility with Python 3.4
    * Improve German update

Version 1.7.6
=============

    * Adapt to psutil 2.0.0 API
    * Fixed psutil 0.5.x support on Windows
    * Fix help screen in 80x24 terminal size
    * Implement toggle of process list display ('z' key)

Version 1.7.5
=============

    * Force the Pypi installer to use the PsUtil branch 1.x (#333)

Version 1.7.4
=============

    * Add threads number in the task summary line (#308)
    * Add system uptime (#276)
    * Add CPU steal % to cpu extended stats (#309)
    * You can hide disk from the IOdisk view using the conf file (#304)
    * You can hide network interface from the Network view using the conf file
    * Optimisation of CPU consumption (around ~10%)
    * Correct issue #314: Client/server mode always asks for password
    * Correct issue #315: Defining password in client/server mode doesn't work as intended
    * Correct issue #316: Crash in client server mode
    * Correct issue #318: Argument parser, try-except blocks never get triggered

Version 1.7.3
=============

    * Add --password argument to enter the client/server password from the prompt
    * Fix an issue with the configuration file path (#296)
    * Fix an issue with the HTML template (#301)

Version 1.7.2
=============

    * Console interface is now Microsoft Windows compatible (thk to @fraoustin)
    * Update documentation and Wiki regarding the API
    * Added package name for python sources/headers in openSUSE/SLES/SLED
    * Add FreeBSD packager
    * Bugs corrected

Version 1.7.1
=============

    * Fix IoWait error on FreeBSD / Mac OS
    * HDDTemp module is now Python v3 compatible
    * Don't warn a process is not running if countmin=0
    * Add Pypi badge on the README.rst
    * Update documentation
    * Add document structure for http://readthedocs.org

Version 1.7
===========

    * Add monitored processes list
    * Add hard disk temperature monitoring (thanks to the HDDtemp daemon)
    * Add batteries capacities information (thanks to the Batinfo lib)
    * Add command line argument -r toggles processes (reduce CPU usage)
    * Add command line argument -1 to run Glances in per CPU mode
    * Platform/architecture is more specific now
    * XML-RPC server: Add IPv6 support for the client/server mode
    * Add support for local conf file
    * Add a uninstall script
    * Add getNetTimeSinceLastUpdate() getDiskTimeSinceLastUpdate() and getProcessDiskTimeSinceLastUpdate() in the API
    * Add more translation: Italien, Chinese
    * and last but not least... up to 100 hundred bugs corrected / software and
    * docs improvements

Version 1.6.1
=============

    * Add per-user settings (configuration file) support
    * Add -z/--nobold option for better appearance under Solarized terminal
    * Key 'u' shows cumulative net traffic
    * Work in improving autoUnit
    * Take into account the number of core in the CPU process limit
    * API improvment add time_since_update for disk, process_disk and network
    * Improve help display
    * Add more dummy FS to the ignore list
    * Code refactory: PsUtil < 0.4.1 is depredicated (Thk to Alessio)
    * Correct a bug on the CPU process limit
    * Fix crash bug when specifying custom server port
    * Add Debian style init script for the Glances server

Version 1.6
===========

    * Configuration file: user can defines limits
    * In client/server mode, limits are set by the server side
    * Display limits in the help screen
    * Add per process IO (read and write) rate in B per second
      IO rate only available on Linux from a root account
    * If CPU iowait alert then sort by processes by IO rate
    * Per CPU display IOwait (if data is available)
    * Add password for the client/server mode (-P password)
    * Process column style auto (underline) or manual (bold)
    * Display a sort indicator (is space is available)
    * Change the table key in the help screen

Version 1.5.2
=============

    * Add sensors module (enable it with -e option)
    * Improve CPU stats (IO wait, Nice, IRQ)
    * More stats in lower space (yes it's possible)
    * Refactor processes list and count (lower CPU/MEM footprint)
    * Add functions to the RCP method
    * Completed unit test
    * and fixes...

Version 1.5.1
=============

    * Patch for PsUtil 0.4 compatibility
    * Test PsUtil version before running Glances

Version 1.5
===========

    * Add a client/server mode (XMLRPC) for remote monitoring
    * Correct a bug on process IO with non root users
    * Add 'w' shortkey to delete finished warning message
    * Add 'x' shortkey to delete finished warning/critical message
    * Bugs correction
    * Code optimization

Version 1.4.2.2
===============

    * Add switch between bit/sec and byte/sec for network IO
    * Add Changelog (generated with gitchangelog)

Version 1.4.2.1
===============

    * Minor patch to solve memomy issue (#94) on Mac OS X

Version 1.4.2
=============

    * Use the new virtual_memory() and virtual_swap() fct (PsUtil)
    * Display "Top process" in logs
    * Minor patch on man page for Debian packaging
    * Code optimization (less try and except)

Version 1.4.1.1
===============

    * Minor patch to disable Process IO for OS X (not available in PsUtil)

Version 1.4.1
=============

    * Per core CPU stats (if space is available)
    * Add Process IO Read/Write information (if space is available)
    * Uniformize units

Version 1.4
===========

    * Goodby StatGrab... Welcome to the PsUtil library !
    * No more autotools, use setup.py to install (or package)
    * Only major stats (CPU, Load and memory) use background colors
    * Improve operating system name detection
    * New system info: one-line layout and add Arch Linux support
    * No decimal places for values < GB
    * New memory and swap layout
    * Add percentage of usage for both memory and swap
    * Add MEM% usage, NICE, STATUS, UID, PID and running TIME per process
    * Add sort by MEM% ('m' key)
    * Add sort by Process name ('p' key)
    * Multiple minor fixes, changes and improvements
    * Disable Disk IO module from the command line (-d)
    * Disable Mount module from the command line (-m)
    * Disable Net rate module from the command line (-n)
    * Improved FreeBSD support
    * Cleaning code and style
    * Code is now checked with pep8
    * CSV and HTML output (experimental functions, no yet documentation)

Version 1.3.7
=============

    * Display (if terminal space is available) an alerts history (logs)
    * Add a limits classe to manage stats limits
    * Manage black and white console (issue #31)

Version 1.3.6
=============

    * Add control before libs import
    * Change static Python path (issue #20)
    * Correct a bug with a network interface disaippear (issue #27)
    * Add French and Spanish translation (thx to Jean Bob)

Version 1.3.5
=============

    * Add an help panel when Glances is running (key: 'h')
    * Add keys descriptions in the syntax (--help | -h)

Version 1.3.4
=============

    * New key: 'n' to enable/disable network stats
    * New key: 'd' to enable/disable disk IO stats
    * New key: 'f' to enable/disable FS stats
    * Reorganised the screen when stat are not available|disable
    * Force Glances to use the enmbeded fs stats (issue #16)

Version 1.3.3
=============

    * Automatically swith between process short and long name
    * Center the host / system information
    * Always put the hour/date in the bottom/right
    * Correct a bug if there is a lot of Disk/IO
    * Add control about available libstatgrab functions

Version 1.3.2
=============

    * Add alert for network bit rate°
    * Change the caption
    * Optimised net, disk IO and fs display (share the space)
      Disable on Ubuntu because the libstatgrab return a zero value
      for the network interface speed.

Version 1.3.1
=============

    * Add alert on load (depend on number of CPU core)
    * Fix bug when the FS list is very long

Version 1.3
===========

    * Add file system stats (total and used space)
    * Adapt unit dynamically (K, M, G)
    * Add man page (Thanks to Edouard Bourguignon)

Version 1.2
===========

    * Resize the terminal and the windows are adapted dynamically
    * Refresh screen instantanetly when a key is pressed

Version 1.1.3
=============

    * Add disk IO monitoring
    * Add caption
    * Correct a bug when computing the bitrate with the option -t
    * Catch CTRL-C before init the screen (Bug #2)
    * Check if mem.total = 0 before division (Bug #1)
                                                                                                                                                                                                                                                                                                                                                                        ./usr/local/share/doc/glances/COPYING                                                               0000664 0000000 0000000 00000016744 13066703446 014351  0                                                                                                    ustar                                                                                                                                                                                                                                                                             GNU LESSER GENERAL PUBLIC LICENSE
                       Version 3, 29 June 2007

 Copyright (C) 2007 Free Software Foundation, Inc. <http://fsf.org/>
 Everyone is permitted to copy and distribute verbatim copies
 of this license document, but changing it is not allowed.


  This version of the GNU Lesser General Public License incorporates
the terms and conditions of version 3 of the GNU General Public
License, supplemented by the additional permissions listed below.

  0. Additional Definitions.

  As used herein, "this License" refers to version 3 of the GNU Lesser
General Public License, and the "GNU GPL" refers to version 3 of the GNU
General Public License.

  "The Library" refers to a covered work governed by this License,
other than an Application or a Combined Work as defined below.

  An "Application" is any work that makes use of an interface provided
by the Library, but which is not otherwise based on the Library.
Defining a subclass of a class defined by the Library is deemed a mode
of using an interface provided by the Library.

  A "Combined Work" is a work produced by combining or linking an
Application with the Library.  The particular version of the Library
with which the Combined Work was made is also called the "Linked
Version".

  The "Minimal Corresponding Source" for a Combined Work means the
Corresponding Source for the Combined Work, excluding any source code
for portions of the Combined Work that, considered in isolation, are
based on the Application, and not on the Linked Version.

  The "Corresponding Application Code" for a Combined Work means the
object code and/or source code for the Application, including any data
and utility programs needed for reproducing the Combined Work from the
Application, but excluding the System Libraries of the Combined Work.

  1. Exception to Section 3 of the GNU GPL.

  You may convey a covered work under sections 3 and 4 of this License
without being bound by section 3 of the GNU GPL.

  2. Conveying Modified Versions.

  If you modify a copy of the Library, and, in your modifications, a
facility refers to a function or data to be supplied by an Application
that uses the facility (other than as an argument passed when the
facility is invoked), then you may convey a copy of the modified
version:

   a) under this License, provided that you make a good faith effort to
   ensure that, in the event an Application does not supply the
   function or data, the facility still operates, and performs
   whatever part of its purpose remains meaningful, or

   b) under the GNU GPL, with none of the additional permissions of
   this License applicable to that copy.

  3. Object Code Incorporating Material from Library Header Files.

  The object code form of an Application may incorporate material from
a header file that is part of the Library.  You may convey such object
code under terms of your choice, provided that, if the incorporated
material is not limited to numerical parameters, data structure
layouts and accessors, or small macros, inline functions and templates
(ten or fewer lines in length), you do both of the following:

   a) Give prominent notice with each copy of the object code that the
   Library is used in it and that the Library and its use are
   covered by this License.

   b) Accompany the object code with a copy of the GNU GPL and this license
   document.

  4. Combined Works.

  You may convey a Combined Work under terms of your choice that,
taken together, effectively do not restrict modification of the
portions of the Library contained in the Combined Work and reverse
engineering for debugging such modifications, if you also do each of
the following:

   a) Give prominent notice with each copy of the Combined Work that
   the Library is used in it and that the Library and its use are
   covered by this License.

   b) Accompany the Combined Work with a copy of the GNU GPL and this license
   document.

   c) For a Combined Work that displays copyright notices during
   execution, include the copyright notice for the Library among
   these notices, as well as a reference directing the user to the
   copies of the GNU GPL and this license document.

   d) Do one of the following:

       0) Convey the Minimal Corresponding Source under the terms of this
       License, and the Corresponding Application Code in a form
       suitable for, and under terms that permit, the user to
       recombine or relink the Application with a modified version of
       the Linked Version to produce a modified Combined Work, in the
       manner specified by section 6 of the GNU GPL for conveying
       Corresponding Source.

       1) Use a suitable shared library mechanism for linking with the
       Library.  A suitable mechanism is one that (a) uses at run time
       a copy of the Library already present on the user's computer
       system, and (b) will operate properly with a modified version
       of the Library that is interface-compatible with the Linked
       Version.

   e) Provide Installation Information, but only if you would otherwise
   be required to provide such information under section 6 of the
   GNU GPL, and only to the extent that such information is
   necessary to install and execute a modified version of the
   Combined Work produced by recombining or relinking the
   Application with a modified version of the Linked Version. (If
   you use option 4d0, the Installation Information must accompany
   the Minimal Corresponding Source and Corresponding Application
   Code. If you use option 4d1, you must provide the Installation
   Information in the manner specified by section 6 of the GNU GPL
   for conveying Corresponding Source.)

  5. Combined Libraries.

  You may place library facilities that are a work based on the
Library side by side in a single library together with other library
facilities that are not Applications and are not covered by this
License, and convey such a combined library under terms of your
choice, if you do both of the following:

   a) Accompany the combined library with a copy of the same work based
   on the Library, uncombined with any other library facilities,
   conveyed under the terms of this License.

   b) Give prominent notice with the combined library that part of it
   is a work based on the Library, and explaining where to find the
   accompanying uncombined form of the same work.

  6. Revised Versions of the GNU Lesser General Public License.

  The Free Software Foundation may publish revised and/or new versions
of the GNU Lesser General Public License from time to time. Such new
versions will be similar in spirit to the present version, but may
differ in detail to address new problems or concerns.

  Each version is given a distinguishing version number. If the
Library as you received it specifies that a certain numbered version
of the GNU Lesser General Public License "or any later version"
applies to it, you have the option of following the terms and
conditions either of that published version or of any later version
published by the Free Software Foundation. If the Library as you
received it does not specify a version number of the GNU Lesser
General Public License, you may choose any version of the GNU Lesser
General Public License ever published by the Free Software Foundation.

  If the Library as you received it specifies that a proxy can decide
whether future versions of the GNU Lesser General Public License shall
apply, that proxy's public statement of acceptance of any version is
permanent authorization for you to choose that version for the
Library.

                            ./usr/local/share/doc/glances/README.rst                                                            0000664 0000000 0000000 00000024461 13066703446 015000  0                                                                                                    ustar                                                                                                                                                                                                                                                          ===============================
Glances - An eye on your system
===============================

.. image:: https://img.shields.io/pypi/v/glances.svg
    :target: https://pypi.python.org/pypi/Glances

.. image:: https://img.shields.io/github/stars/nicolargo/glances.svg
    :target: https://github.com/nicolargo/glances/
    :alt: Github stars

.. image:: https://img.shields.io/travis/nicolargo/glances/master.svg?maxAge=3600&label=Linux%20/%20BSD%20/%20macOS
    :target: https://travis-ci.org/nicolargo/glances
    :alt: Linux tests (Travis)

.. image:: https://img.shields.io/appveyor/ci/nicolargo/glances/master.svg?maxAge=3600&label=Windows
    :target: https://ci.appveyor.com/project/nicolargo/glances
    :alt: Windows tests (Appveyor)

.. image:: https://img.shields.io/scrutinizer/g/nicolargo/glances.svg
    :target: https://scrutinizer-ci.com/g/nicolargo/glances/

Follow Glances on Twitter: `@nicolargo`_ or `@glances_system`_

Summary
=======

**Glances** is a cross-platform monitoring tool which aims to present a
maximum of information in a minimum of space through a curses or Web
based interface. It can adapt dynamically the displayed information
depending on the user interface size.

.. image:: https://raw.githubusercontent.com/nicolargo/glances/develop/docs/_static/glances-summary.png

It can also work in client/server mode. Remote monitoring could be done
via terminal, Web interface or API (XML-RPC and RESTful). Stats can also
be exported to files or external time/value databases.

.. image:: https://raw.githubusercontent.com/nicolargo/glances/develop/docs/_static/glances-responsive-webdesign.png

Glances is written in Python and uses libraries to grab information from
your system. It is based on an open architecture where developers can
add new plugins or exports modules.

Requirements
============

- ``python 2.7,>=3.3``
- ``psutil>=2.0.0`` (better with latest version)

Optional dependencies:

- ``bernhard`` (for the Riemann export module)
- ``bottle`` (for Web server mode)
- ``cassandra-driver`` (for the Cassandra export module)
- ``couchdb`` (for the CouchDB export module)
- ``docker`` (for the Docker monitoring support) [Linux-only]
- ``elasticsearch`` (for the Elastic Search export module)
- ``hddtemp`` (for HDD temperature monitoring support) [Linux-only]
- ``influxdb`` (for the InfluxDB export module)
- ``kafka-python`` (for the Kafka export module)
- ``matplotlib`` (for graphical/chart support)
- ``netifaces`` (for the IP plugin)
- ``nvidia-ml-py`` (for the GPU plugin) [Python 2-only]
- ``pika`` (for the RabbitMQ/ActiveMQ export module)
- ``potsdb`` (for the OpenTSDB export module)
- ``prometheus_client`` (for the Prometheus export module)
- ``py-cpuinfo`` (for the Quicklook CPU info module)
- ``pymdstat`` (for RAID support) [Linux-only]
- ``pysnmp`` (for SNMP support)
- ``pystache`` (for the action script feature)
- ``pyzmq`` (for the ZeroMQ export module)
- ``requests`` (for the Ports and Cloud plugins)
- ``scandir`` (for the Folders plugin) [Only for Python < 3.5]
- ``statsd`` (for the StatsD export module)
- ``wifi`` (for the wifi plugin) [Linux-only]
- ``zeroconf`` (for the autodiscover mode)

*Note for Python 2.6 users*

Since version 2.7, Glances no longer support Python 2.6. Please upgrade
to at least Python 2.7/3.3+ or downgrade to Glances 2.6.2 (latest version
with Python 2.6 support).

*Note for CentOS Linux 6 and 7 users*

Python 2.7, 3.3 and 3.4 are now available via SCLs. See:
https://lists.centos.org/pipermail/centos-announce/2015-December/021555.html.

Installation
============

Several method to test/install Glances on your system. Choose your weapon !

Glances Auto Install script: the total way
------------------------------------------

To install both dependencies and latest Glances production ready version
(aka *master* branch), just enter the following command line:

.. code-block:: console

    curl -L https://bit.ly/glances | /bin/bash

or

.. code-block:: console

    wget -O- https://bit.ly/glances | /bin/bash

*Note*: Only supported on some GNU/Linux distributions. If you want to
support other distributions, please contribute to `glancesautoinstall`_.

PyPI: The simple way
--------------------

Glances is on ``PyPI``. By using PyPI, you are sure to have the latest
stable version.

To install, simply use ``pip``:

.. code-block:: console

    pip install glances

*Note*: Python headers are required to install `psutil`_. For example,
on Debian/Ubuntu you need to install first the *python-dev* package.
For Fedora/CentOS/RHEL install first *python-devel* package. For Windows,
just install psutil from the binary installation file.

*Note 2 (for the Wifi plugin)*: If you want to use the Wifi plugin, you need
to install the *wireless-tools* package on your system.

You can also install the following libraries in order to use optional
features (like the Web interface, exports modules...):

.. code-block:: console

    pip install glances[action,browser,cloud,cpuinfo,chart,docker,export,folders,gpu,ip,raid,snmp,web,wifi]

To upgrade Glances to the latest version:

.. code-block:: console

    pip install --upgrade glances
    pip install --upgrade glances[...]

If you need to install Glances in a specific user location, use:

.. code-block:: console

    export PYTHONUSERBASE=~/mylocalpath
    pip install --user glances

Docker: the funny way
---------------------

A Glances container is available. It will include the latest development
HEAD version. You can use it to monitor your server and all your others
containers !

Get the Glances container:

.. code-block:: console

    docker pull nicolargo/glances

Run the container in *console mode*:

.. code-block:: console

    docker run -v /var/run/docker.sock:/var/run/docker.sock:ro --pid host -it docker.io/nicolargo/glances

Additionally, if you want to use your own glances.conf file, you can
create your own Dockerfile:

.. code-block:: console

    FROM nicolargo/glances
    COPY glances.conf /glances/conf/glances.conf
    CMD python -m glances -C /glances/conf/glances.conf $GLANCES_OPT

Alternatively, you can specify something along the same lines with
docker run options:

.. code-block:: console

    docker run -v ./glances.conf:/glances/conf/glances.conf -v /var/run/docker.sock:/var/run/docker.sock:ro --pid host -it docker.io/nicolargo/glances

Where ./glances.conf is a local directory containing your glances.conf file.

Run the container in *Web server mode* (notice the `GLANCES_OPT` environment
variable setting parameters for the glances startup command):

.. code-block:: console

    docker run -d --restart="always" -p 61208-61209:61208-61209 -e GLANCES_OPT="-w" -v /var/run/docker.sock:/var/run/docker.sock:ro --pid host docker.io/nicolargo/glances

GNU/Linux
---------

`Glances` is available on many Linux distributions, so you should be
able to install it using your favorite package manager. Be aware that
Glances may not be the latest one using this method.

FreeBSD
-------

To install the binary package:

.. code-block:: console

    # pkg install py27-glances

To install Glances from ports:

.. code-block:: console

    # cd /usr/ports/sysutils/py-glances/
    # make install clean

macOS
-----

macOS users can install Glances using ``Homebrew`` or ``MacPorts``.

Homebrew
````````

.. code-block:: console

    $ brew install python
    $ pip install glances

MacPorts
````````

.. code-block:: console

    $ sudo port install glances

Windows
-------

Install `Python`_ for Windows (Python 2.7.9+ and 3.4+ ship with pip) and
then just:

.. code-block:: console

    $ pip install glances

Android
-------

You need a rooted device and the `Termux`_ application (available on the
Google Store).

Start Termux on your device and enter:

.. code-block:: console

    $ apt update
    $ apt upgrade
    $ apt install clang python python-dev
    $ pip install glances

And start Glances:

.. code-block:: console

    $ glances

Source
------

To install Glances from source:

.. code-block:: console

    $ wget https://github.com/nicolargo/glances/archive/vX.Y.tar.gz -O - | tar xz
    $ cd glances-*
    # python setup.py install

*Note*: Python headers are required to install psutil.

Chef
----

An awesome ``Chef`` cookbook is available to monitor your infrastructure:
https://supermarket.chef.io/cookbooks/glances (thanks to Antoine Rouyer)

Puppet
------

You can install Glances using ``Puppet``: https://github.com/rverchere/puppet-glances

Usage
=====

For the standalone mode, just run:

.. code-block:: console

    $ glances

For the Web server mode, run:

.. code-block:: console

    $ glances -w

and enter the URL ``http://<ip>:61208`` in your favorite web browser.

For the client/server mode, run:

.. code-block:: console

    $ glances -s

on the server side and run:

.. code-block:: console

    $ glances -c <ip>

on the client one.

You can also detect and display all Glances servers available on your
network or defined in the configuration file:

.. code-block:: console

    $ glances --browser

and RTFM, always.

Documentation
=============

For complete documentation have a look at the readthedocs_ website.

If you have any question (after RTFM!), please post it on the official Q&A `forum`_.

Gateway to other services
=========================

Glances can export stats to: ``CSV`` file, ``InfluxDB``, ``Cassandra``, ``CouchDB``,
``OpenTSDB``, ``Prometheus``, ``StatsD``, ``ElasticSearch``, ``RabbitMQ/ActiveMQ``,
``ZeroMQ``, ``Kafka`` and ``Riemann`` server.

How to contribute ?
===================

If you want to contribute to the Glances project, read this `wiki`_ page.

There is also a chat dedicated to the Glances developers:

.. image:: https://badges.gitter.im/Join%20Chat.svg
        :target: https://gitter.im/nicolargo/glances?utm_source=badge&utm_medium=badge&utm_campaign=pr-badge&utm_content=badge

Author
======

Nicolas Hennion (@nicolargo) <nicolas@nicolargo.com>

License
=======

LGPLv3. See ``COPYING`` for more details.

.. _psutil: https://github.com/giampaolo/psutil
.. _glancesautoinstall: https://github.com/nicolargo/glancesautoinstall
.. _@nicolargo: https://twitter.com/nicolargo
.. _@glances_system: https://twitter.com/glances_system
.. _Python: https://www.python.org/getit/
.. _Termux: https://play.google.com/store/apps/details?id=com.termux
.. _readthedocs: https://glances.readthedocs.io/
.. _forum: https://groups.google.com/forum/?hl=en#!forum/glances-users
.. _wiki: https://github.com/nicolargo/glances/wiki/How-to-contribute-to-Glances-%3F
                                                                                                                                                                                                               ./usr/local/share/doc/glances/AUTHORS                                                               0000664 0000000 0000000 00000002601 13066703446 014351  0                                                                                                    ustar                                                                                                                                                                                                                                                          ==========
Developers
==========

Nicolas Hennion (aka) Nicolargo
http://blog.nicolargo.com
https://twitter.com/nicolargo
https://github.com/nicolargo
nicolashennion@gmail.com
PGP Fingerprint: 835F C447 3BCD 60E9 9200  2778 ABA4 D1AB 9731 6A3C
PGP Public key:  gpg --keyserver pgp.mit.edu --recv-keys 0xaba4d1ab97316a3c

Alessio Sergi (aka) Al3hex
https://twitter.com/al3hex
https://github.com/asergi

Brandon Philips (aka) Philips
http://ifup.org/
https://github.com/philips

Jon Renner (aka) Jrenner
https://github.com/jrenner

Maxime Desbrus (aka) Desbma
https://github.com/desbma

Nicolas Hart (aka) NclsHart (for the Web user interface)
https://github.com/nclsHart

Sylvain Mouquet (aka) SylvainMouquet (for the Web user interface)
http://github.com/sylvainmouquet

Floran Brutel (aka) notFloran (for the Web user interface)
https://github.com/notFloran

=========
Packagers
=========

Daniel Echeverry and Sebastien Badia for the Debian package
https://tracker.debian.org/pkg/glances

Philip Lacroix and Nicolas Kovacs for the Slackware (SlackBuild) package

gasol.wu@gmail.com for the FreeBSD port

Frederic Aoustin (https://github.com/fraoustin) and Nicolas Bourges (installer) for the Windows port

Aljaž Srebrnič for the MacPorts package
http://www.macports.org/ports.php?by=name&substr=glances

John Kirkham for the conda package (at conda-forge)
https://github.com/conda-forge/glances-feedstock
                                                                                                                               ./usr/local/share/doc/glances/glances.conf                                                          0000664 0000000 0000000 00000027225 13066703446 015575  0                                                                                                    ustar                                                                                                                                                                                                                                                          ##############################################################################
# Globals Glances parameters
##############################################################################

[global]
# Does Glances should check if a newer version is available on PyPI ?
check_update=true
# History size (maximum number of values)
# Default is 28800: 1 day with 1 point every 3 seconds (default refresh time)
history_size=28800

##############################################################################
# User interface
##############################################################################

[outputs]
# Theme name for the Curses interface: black or white
curse_theme=black
# Limit the number of processes to display in the WebUI
max_processes_display=30

##############################################################################
# plugins
##############################################################################

[quicklook]
# Define CPU, MEM and SWAP thresholds in %
cpu_careful=50
cpu_warning=70
cpu_critical=90
mem_careful=50
mem_warning=70
mem_critical=90
swap_careful=50
swap_warning=70
swap_critical=90

[cpu]
# Default values if not defined: 50/70/90 (except for iowait)
user_careful=50
user_warning=70
user_critical=90
#user_log=False
#user_critical_action=echo {{user}} {{value}} {{max}} > /tmp/cpu.alert
system_careful=50
system_warning=70
system_critical=90
steal_careful=50
steal_warning=70
steal_critical=90
#steal_log=True
# I/O wait percentage should be lower than 1/# (of CPU cores)
# Leave commented to just use the default config (1/#-20% / 1/#-10% / 1/#)
#iowait_careful=30
#iowait_warning=40
#iowait_critical=50
# Context switch limit (core / second)
# Leave commented to just use the default config (critical is 56000/# (of CPU core))
#ctx_switches_careful=10000
#ctx_switches_warning=12000
#ctx_switches_critical=14000

[percpu]
# Define CPU thresholds in %
# Default values if not defined: 50/70/90
user_careful=50
user_warning=70
user_critical=90
iowait_careful=50
iowait_warning=70
iowait_critical=90
system_careful=50
system_warning=70
system_critical=90

[gpu]
# Default processor values if not defined: 50/70/90
proc_careful=50
proc_warning=70
proc_critical=90
# Default memory values if not defined: 50/70/90
mem_careful=50
mem_warning=70
mem_critical=90

[mem]
# Define RAM thresholds in %
# Default values if not defined: 50/70/90
careful=50
warning=70
critical=90

[memswap]
# Define SWAP thresholds in %
# Default values if not defined: 50/70/90
careful=50
warning=70
critical=90

[load]
# Define LOAD thresholds
# Value * number of cores
# Default values if not defined: 0.7/1.0/5.0 per number of cores
# Source: http://blog.scoutapp.com/articles/2009/07/31/understanding-load-averages
#         http://www.linuxjournal.com/article/9001
careful=0.7
warning=1.0
critical=5.0
#log=False

[network]
# Default bitrate thresholds in % of the network interface speed
# Default values if not defined: 70/80/90
rx_careful=70
rx_warning=80
rx_critical=90
tx_careful=70
tx_warning=80
tx_critical=90
# Define the list of hidden network interfaces (comma-separated regexp)
#hide=docker.*,lo
# WLAN 0 alias
#wlan0_alias=Wireless IF
# It is possible to overwrite the bitrate thresholds per interface
# WLAN 0 Default limits (in bits per second aka bps) for interface bitrate
#wlan0_rx_careful=4000000
#wlan0_rx_warning=5000000
#wlan0_rx_critical=6000000
#wlan0_rx_log=True
#wlan0_tx_careful=700000
#wlan0_tx_warning=900000
#wlan0_tx_critical=1000000
#wlan0_tx_log=True

[wifi]
# Define the list of hidden wireless network interfaces (comma-separated regexp)
hide=lo,docker.*
# Define SIGNAL thresholds in db (lower is better...)
# Based on: http://serverfault.com/questions/501025/industry-standard-for-minimum-wifi-signal-strength
careful=-65
warning=-75
critical=-85

#[diskio]
# Define the list of hidden disks (comma-separated regexp)
#hide=sda2,sda5,loop.*
# Alias for sda1
#sda1_alias=IntDisk

[fs]
# Define the list of hidden file system (comma-separated regexp)
#hide=/boot.*
# Define filesystem space thresholds in %
# Default values if not defined: 50/70/90
# It is also possible to define per mount point value
# Example: /_careful=40
careful=50
warning=70
critical=90
# Allow additional file system types (comma-separated FS type)
#allow=zfs

[folders]
# Define a folder list to monitor
# The list is composed of items (list_#nb <= 10)
# An item is defined by:
# * path: absolute path
# * careful: optional careful threshold (in MB)
# * warning: optional warning threshold (in MB)
# * critical: optional critical threshold (in MB)
#folder_1_path=/tmp
#folder_1_careful=2500
#folder_1_warning=3000
#folder_1_critical=3500
#folder_2_path=/home/nicolargo/Videos
#folder_2_warning=17000
#folder_2_critical=20000
#folder_3_path=/nonexisting
#folder_4_path=/root

[sensors]
# Sensors core thresholds (in Celsius...)
# Default values if not defined: 60/70/80
temperature_core_careful=60
temperature_core_warning=70
temperature_core_critical=80
# Temperatures threshold in °C for hddtemp
# Default values if not defined: 45/52/60
temperature_hdd_careful=45
temperature_hdd_warning=52
temperature_hdd_critical=60
# Battery threshold in %
battery_careful=80
battery_warning=90
battery_critical=95
# Sensors alias
#temp1_alias=Motherboard 0
#temp2_alias=Motherboard 1
#core 0_alias=CPU Core 0
#core 1_alias=CPU Core 1

[processlist]
# Define CPU/MEM (per process) thresholds in %
# Default values if not defined: 50/70/90
cpu_careful=50
cpu_warning=70
cpu_critical=90
mem_careful=50
mem_warning=70
mem_critical=90

[ports]
# Ports scanner plugin configuration
# Interval in second between two scans
refresh=30
# Set the default timeout (in second) for a scan (can be overwritten in the scan list)
timeout=3
# If port_default_gateway is True, add the default gateway on top of the scan list
port_default_gateway=True
# Define the scan list (1 < x < 255)
# port_x_host (name or IP) is mandatory
# port_x_port (TCP port number) is optional (if not set, use ICMP)
# port_x_description is optional (if not set, define to host:port)
# port_x_timeout is optional and overwrite the default timeout value
# port_x_rtt_warning is optional and defines the warning threshold in ms
#port_1_host=192.168.0.1
#port_1_port=80
#port_1_description=Home Box
#port_1_timeout=1
#port_2_host=www.free.fr
#port_2_description=My ISP
#port_3_host=www.google.com
#port_3_description=Internet ICMP
#port_3_rtt_warning=1000
#port_4_host=www.google.com
#port_4_description=Internet Web
#port_4_port=80
#port_4_rtt_warning=1000

[docker]
# Thresholds for CPU and MEM (in %)
#cpu_careful=50
#cpu_warning=70
#cpu_critical=90
#mem_careful=20
#mem_warning=50
#mem_critical=70
# Per container thresholds
#containername_cpu_careful=10
#containername_cpu_warning=20
#containername_cpu_critical=30

##############################################################################
# Client/server
##############################################################################

[serverlist]
# Define the static servers list
#server_1_name=localhost
#server_1_alias=My local PC
#server_1_port=61209
#server_2_name=localhost
#server_2_port=61235
#server_3_name=192.168.0.17
#server_3_alias=Another PC on my network
#server_3_port=61209
#server_4_name=pasbon
#server_4_port=61237

[passwords]
# Define the passwords list
# Syntax: host=password
# Where: host is the hostname
#        password is the clear password
# Additionally (and optionally) a default password could be defined
#localhost=abc
#default=defaultpassword

##############################################################################
# Exports
##############################################################################

[influxdb]
# Configuration for the --export-influxdb option
# https://influxdb.com/
host=localhost
port=8086
user=root
password=root
db=glances
prefix=localhost
#tags=foo:bar,spam:eggs

[cassandra]
# Configuration for the --export-cassandra option
# Also works for the ScyllaDB
# https://influxdb.com/ or http://www.scylladb.com/
host=localhost
port=9042
protocol_version=3
keyspace=glances
replication_factor=2
# If not define, table name is set to host key
table=localhost

[opentsdb]
# Configuration for the --export-opentsdb option
# http://opentsdb.net/
host=localhost
port=4242
#prefix=glances
#tags=foo:bar,spam:eggs

[statsd]
# Configuration for the --export-statsd option
# https://github.com/etsy/statsd
host=localhost
port=8125
#prefix=glances

[elasticsearch]
# Configuration for the --export-elasticsearch option
# Data are available via the ES Restful API. ex: URL/<index>/cpu/system
# https://www.elastic.co
host=localhost
port=9200
index=glances

[riemann]
# Configuration for the --export-riemann option
# http://riemann.io
host=localhost
port=5555

[rabbitmq]
host=localhost
port=5672
user=guest
password=guest
queue=glances_queue

[couchdb]
# Configuration for the --export-couchdb option
# https://www.couchdb.org
host=localhost
port=5984
db=glances
# user and password are optional (comment if not configured on the server side)
#user=root
#password=root

[kafka]
# Configuration for the --export-kafka option
# http://kafka.apache.org/
host=localhost
port=9092
topic=glances
#compression=gzip

[zeromq]
# Configuration for the --export-zeromq option
# http://www.zeromq.org
# Use * to bind on all interfaces
host=*
port=5678
# Glances envelopes the stats in a publish message with two frames:
# - First frame containing the following prefix (STRING)
# - Second frame with the Glances plugin name (STRING)
# - Third frame with the Glances plugin stats (JSON)
prefix=G

[prometheus]
# Configuration for the --export-prometheus option
# https://prometheus.io
# Create a Prometheus exporter listening on localhost:9091 (default configuration)
# Metric are exporter using the following name:
#   <prefix>_<plugin>_<stats> (all specials character are replaced by '_')
# Note: You should add this exporter to your Prometheus server configuration:
#   scrape_configs:
#    - job_name: 'glances_exporter'
#      scrape_interval: 5s
#      static_configs:
#        - targets: ['localhost:9091']
host=localhost
port=9091
prefix=glances

##############################################################################
# AMPS
# * enable: Enable (true) or disable (false) the AMP
# * regex: Regular expression to filter the process(es)
# * refresh: The AMP is executed every refresh seconds
# * one_line: (optional) Force (if true) the AMP to be displayed in one line
# * command: (optional) command to execute when the process is detected (thk to the regex)
# * countmin: (optional) minimal number of processes
#             A warning will be displayed if number of process < count
# * countmax: (optional) maximum number of processes
#             A warning will be displayed if number of process > count
# * <foo>: Others variables can be defined and used in the AMP script
##############################################################################

[amp_dropbox]
# Use the default AMP (no dedicated AMP Python script)
# Check if the Dropbox daemon is running
# Every 3 seconds, display the 'dropbox status' command line
enable=false
regex=.*dropbox.*
refresh=3
one_line=false
command=dropbox status
countmin=1

[amp_python]
# Use the default AMP (no dedicated AMP Python script)
# Monitor all the Python scripts
# Alert if more than 20 Python scripts are running
enable=false
regex=.*python.*
refresh=3
countmax=20

[amp_nginx]
# Use the NGinx AMP
# Nginx status page should be enable (https://easyengine.io/tutorials/nginx/status-page/)
enable=false
regex=\/usr\/sbin\/nginx
refresh=60
one_line=false
status_url=http://localhost/nginx_status

[amp_systemd]
# Use the Systemd AMP
enable=true
regex=\/lib\/systemd\/systemd
refresh=30
one_line=true
systemctl_cmd=/bin/systemctl --plain

[amp_systemv]
# Use the Systemv AMP
enable=true
regex=\/sbin\/init
refresh=30
one_line=true
service_cmd=/usr/bin/service --status-all
                                                                                                                                                                                                                                                                                                                                                                           ./usr/local/share/doc/glances/CONTRIBUTING.md                                                       0000664 0000000 0000000 00000012733 13066703446 015541  0                                                                                                    ustar                                                                                                                                                                                                                                                          # Contributing to Glances

Looking to contribute something to Glances ? **Here's how you can help.**

Please take a moment to review this document in order to make the contribution
process easy and effective for everyone involved.

Following these guidelines helps to communicate that you respect the time of
the developers managing and developing this open source project. In return,
they should reciprocate that respect in addressing your issue or assessing
patches and features.


## Using the issue tracker

The [issue tracker](https://github.com/nicolargo/glances/issues) is
the preferred channel for [bug reports](#bug-reports), [features requests](#feature-requests)
and [submitting pull requests](#pull-requests), but please respect the following
restrictions:

* Please **do not** use the issue tracker for personal support requests. A official Q&A exist. [Use it](https://groups.google.com/forum/?hl=en#!forum/glances-users)!

* Please **do not** derail or troll issues. Keep the discussion on topic and
  respect the opinions of others.


## Bug reports

A bug is a _demonstrable problem_ that is caused by the code in the repository.
Good bug reports are extremely helpful, so thanks!

Guidelines for bug reports:

0. **Use the GitHub issue search** &mdash; check if the issue has already been
   reported.

1. **Check if the issue has been fixed** &mdash; try to reproduce it using the
   latest `master` or `develop` branch in the repository.

2. **Isolate the problem** &mdash; ideally create a simple test bed.

3. **Give us your test environment** &mdash; Operating system name and version
   Glances version...

Example:

> Short and descriptive example bug report title
>
> Glances and PsUtil version used (glances -V)
>
> Operating system description (name and version).
>
> A summary of the issue and the OS environment in which it occurs. If
> suitable, include the steps required to reproduce the bug.
>
> 1. This is the first step
> 2. This is the second step
> 3. Further steps, etc.
>
> Screenshot (if usefull)
>
> Any other information you want to share that is relevant to the issue being
> reported. This might include the lines of code that you have identified as
> causing the bug, and potential solutions (and your opinions on their
> merits).


## Feature requests

Feature requests are welcome. But take a moment to find out whether your idea
fits with the scope and aims of the project. It's up to *you* to make a strong
case to convince the project's developers of the merits of this feature. Please
provide as much detail and context as possible.


## Pull requests

Good pull requests—patches, improvements, new features—are a fantastic
help. They should remain focused in scope and avoid containing unrelated
commits.

**Please ask first** before embarking on any significant pull request (e.g.
implementing features, refactoring code, porting to a different language),
otherwise you risk spending a lot of time working on something that the
project's developers might not want to merge into the project.

First of all, all pull request should be done on the `develop` branch.

Glances uses PEP8 compatible code, so use a PEP validator before submitting
your pull request. Also uses the unitaries tests scripts (unitest-all.py).

Similarly, when contributing to Glances's documentation, you should edit the
documentation source files in
[the `/doc/` and `/man/` directories of the `develop` branch](https://github.com/nicolargo/glances/tree/develop/docs) and generate
the documentation outputs files by reading the [README](https://github.com/nicolargo/glances/tree/develop/docs/README.txt) file.

Adhering to the following process is the best way to get your work
included in the project:

1. [Fork](https://help.github.com/fork-a-repo/) the project, clone your fork,
   and configure the remotes:

   ```bash
   # Clone your fork of the repo into the current directory
   git clone https://github.com/<your-username>/glances.git
   # Navigate to the newly cloned directory
   cd glances
   # Assign the original repo to a remote called "upstream"
   git remote add upstream https://github.com/nicolargo/glances.git
   ```

2. Get the latest changes from upstream:

   ```bash
   git checkout develop
   git pull upstream develop
   ```

3. Create a new topic branch (off the main project development branch) to
   contain your feature, change, or fix (best way is to call it issue#xxx):

   ```bash
   git checkout -b <topic-branch-name>
   ```

4. It's coding time !
   Please respect the following coding convention: [Elements of Python Style](https://github.com/amontalenti/elements-of-python-style)
   Commit your changes in logical chunks. Please adhere to these [git commit
   message guidelines](http://tbaggery.com/2008/04/19/a-note-about-git-commit-messages.html)
   or your code is unlikely be merged into the main project. Use Git's
   [interactive rebase](https://help.github.com/articles/interactive-rebase)
   feature to tidy up your commits before making them public.

5. Locally merge (or rebase) the upstream development branch into your topic branch:

   ```bash
   git pull [--rebase] upstream develop
   ```

6. Push your topic branch up to your fork:

   ```bash
   git push origin <topic-branch-name>
   ```

7. [Open a Pull Request](https://help.github.com/articles/using-pull-requests/)
    with a clear title and description against the `develop` branch.

**IMPORTANT**: By submitting a patch, you agree to allow the project owners to
license your work under the terms of the [LGPLv3](COPYING) (if it
includes code changes).
                                     ./usr/local/share/man/                                                                              0000775 0000000 0000000 00000000000 13070471670 011670  5                                                                                                    ustar                                                                                                                                                                                                                                                          ./usr/local/share/man/man1/                                                                         0000775 0000000 0000000 00000000000 13070471670 012524  5                                                                                                    ustar                                                                                                                                                                                                                                                          ./usr/local/share/man/man1/glances.1                                                                0000664 0000000 0000000 00000041725 13066703446 014237  0                                                                                                    ustar                                                                                                                                                                                                                                                          .\" Man page generated from reStructuredText.
.
.TH "GLANCES" "1" "Mar 29, 2017" "2.9.1" "Glances"
.SH NAME
glances \- An eye on your system
.
.nr rst2man-indent-level 0
.
.de1 rstReportMargin
\\$1 \\n[an-margin]
level \\n[rst2man-indent-level]
level margin: \\n[rst2man-indent\\n[rst2man-indent-level]]
-
\\n[rst2man-indent0]
\\n[rst2man-indent1]
\\n[rst2man-indent2]
..
.de1 INDENT
.\" .rstReportMargin pre:
. RS \\$1
. nr rst2man-indent\\n[rst2man-indent-level] \\n[an-margin]
. nr rst2man-indent-level +1
.\" .rstReportMargin post:
..
.de UNINDENT
. RE
.\" indent \\n[an-margin]
.\" old: \\n[rst2man-indent\\n[rst2man-indent-level]]
.nr rst2man-indent-level -1
.\" new: \\n[rst2man-indent\\n[rst2man-indent-level]]
.in \\n[rst2man-indent\\n[rst2man-indent-level]]u
..
.SH SYNOPSIS
.sp
\fBglances\fP [OPTIONS]
.SH DESCRIPTION
.sp
\fBglances\fP is a cross\-platform curses\-based monitoring tool which aims
to present a maximum of information in a minimum of space, ideally to
fit in a classical 80x24 terminal or higher to have additional
information. It can adapt dynamically the displayed information
depending on the terminal size. It can also work in client/server mode.
Remote monitoring could be done via terminal or web interface.
.sp
\fBglances\fP is written in Python and uses the \fIpsutil\fP library to get
information from your system.
.SH OPTIONS
.SH COMMAND-LINE OPTIONS
.INDENT 0.0
.TP
.B \-h, \-\-help
show this help message and exit
.UNINDENT
.INDENT 0.0
.TP
.B \-V, \-\-version
show program\(aqs version number and exit
.UNINDENT
.INDENT 0.0
.TP
.B \-d, \-\-debug
enable debug mode
.UNINDENT
.INDENT 0.0
.TP
.B \-C CONF_FILE, \-\-config CONF_FILE
path to the configuration file
.UNINDENT
.INDENT 0.0
.TP
.B \-\-disable\-alert
disable alert/log module
.UNINDENT
.INDENT 0.0
.TP
.B \-\-disable\-amps
disable application monitoring process module
.UNINDENT
.INDENT 0.0
.TP
.B \-\-disable\-cpu
disable CPU module
.UNINDENT
.INDENT 0.0
.TP
.B \-\-disable\-diskio
disable disk I/O module
.UNINDENT
.INDENT 0.0
.TP
.B \-\-disable\-docker
disable Docker module
.UNINDENT
.INDENT 0.0
.TP
.B \-\-disable\-folders
disable folders module
.UNINDENT
.INDENT 0.0
.TP
.B \-\-disable\-fs
disable file system module
.UNINDENT
.INDENT 0.0
.TP
.B \-\-disable\-hddtemp
disable HD temperature module
.UNINDENT
.INDENT 0.0
.TP
.B \-\-disable\-ip
disable IP module
.UNINDENT
.INDENT 0.0
.TP
.B \-\-disable\-irq
disable IRQ module
.UNINDENT
.INDENT 0.0
.TP
.B \-\-disable\-load
disable load module
.UNINDENT
.INDENT 0.0
.TP
.B \-\-disable\-mem
disable memory module
.UNINDENT
.INDENT 0.0
.TP
.B \-\-disable\-memswap
disable memory swap module
.UNINDENT
.INDENT 0.0
.TP
.B \-\-disable\-network
disable network module
.UNINDENT
.INDENT 0.0
.TP
.B \-\-disable\-now
disable current time module
.UNINDENT
.INDENT 0.0
.TP
.B \-\-disable\-ports
disable Ports module
.UNINDENT
.INDENT 0.0
.TP
.B \-\-disable\-process
disable process module
.UNINDENT
.INDENT 0.0
.TP
.B \-\-disable\-raid
disable RAID module
.UNINDENT
.INDENT 0.0
.TP
.B \-\-disable\-sensors
disable sensors module
.UNINDENT
.INDENT 0.0
.TP
.B \-\-disable\-wifi
disable Wifi module
.UNINDENT
.INDENT 0.0
.TP
.B \-0, \-\-disable\-irix
task\(aqs CPU usage will be divided by the total number of CPUs
.UNINDENT
.INDENT 0.0
.TP
.B \-1, \-\-percpu
start Glances in per CPU mode
.UNINDENT
.INDENT 0.0
.TP
.B \-2, \-\-disable\-left\-sidebar
disable network, disk I/O, FS and sensors modules
.UNINDENT
.INDENT 0.0
.TP
.B \-3, \-\-disable\-quicklook
disable quick look module
.UNINDENT
.INDENT 0.0
.TP
.B \-4, \-\-full\-quicklook
disable all but quick look and load
.UNINDENT
.INDENT 0.0
.TP
.B \-5, \-\-disable\-top
disable top menu (QuickLook, CPU, MEM, SWAP and LOAD)
.UNINDENT
.INDENT 0.0
.TP
.B \-6, \-\-meangpu
start Glances in mean GPU mode
.UNINDENT
.INDENT 0.0
.TP
.B \-\-enable\-history
enable the history mode (matplotlib lib needed)
.UNINDENT
.INDENT 0.0
.TP
.B \-\-disable\-bold
disable bold mode in the terminal
.UNINDENT
.INDENT 0.0
.TP
.B \-\-disable\-bg
disable background colors in the terminal
.UNINDENT
.INDENT 0.0
.TP
.B \-\-enable\-process\-extended
enable extended stats on top process
.UNINDENT
.INDENT 0.0
.TP
.B \-\-export\-graph
export stats to graph
.UNINDENT
.INDENT 0.0
.TP
.B \-\-path\-graph PATH_GRAPH
set the export path for graph history
.UNINDENT
.INDENT 0.0
.TP
.B \-\-export\-csv EXPORT_CSV
export stats to a CSV file
.UNINDENT
.INDENT 0.0
.TP
.B \-\-export\-cassandra
export stats to a Cassandra/Scylla server (cassandra lib needed)
.UNINDENT
.INDENT 0.0
.TP
.B \-\-export\-couchdb
export stats to a CouchDB server (couchdb lib needed)
.UNINDENT
.INDENT 0.0
.TP
.B \-\-export\-elasticsearch
export stats to an Elasticsearch server (elasticsearch lib needed)
.UNINDENT
.INDENT 0.0
.TP
.B \-\-export\-influxdb
export stats to an InfluxDB server (influxdb lib needed)
.UNINDENT
.INDENT 0.0
.TP
.B \-\-export\-opentsdb
export stats to an OpenTSDB server (potsdb lib needed)
.UNINDENT
.INDENT 0.0
.TP
.B \-\-export\-rabbitmq
export stats to RabbitMQ broker (pika lib needed)
.UNINDENT
.INDENT 0.0
.TP
.B \-\-export\-statsd
export stats to a StatsD server (statsd lib needed)
.UNINDENT
.INDENT 0.0
.TP
.B \-\-export\-riemann
export stats to Riemann server (bernhard lib needed)
.UNINDENT
.INDENT 0.0
.TP
.B \-\-export\-zeromq
export stats to a ZeroMQ server (zmq lib needed)
.UNINDENT
.INDENT 0.0
.TP
.B \-c CLIENT, \-\-client CLIENT
connect to a Glances server by IPv4/IPv6 address, hostname or hostname:port
.UNINDENT
.INDENT 0.0
.TP
.B \-s, \-\-server
run Glances in server mode
.UNINDENT
.INDENT 0.0
.TP
.B \-\-browser
start the client browser (list of servers)
.UNINDENT
.INDENT 0.0
.TP
.B \-\-disable\-autodiscover
disable autodiscover feature
.UNINDENT
.INDENT 0.0
.TP
.B \-p PORT, \-\-port PORT
define the client/server TCP port [default: 61209]
.UNINDENT
.INDENT 0.0
.TP
.B \-B BIND_ADDRESS, \-\-bind BIND_ADDRESS
bind server to the given IPv4/IPv6 address or hostname
.UNINDENT
.INDENT 0.0
.TP
.B \-\-username
define a client/server username
.UNINDENT
.INDENT 0.0
.TP
.B \-\-password
define a client/server password
.UNINDENT
.INDENT 0.0
.TP
.B \-\-snmp\-community SNMP_COMMUNITY
SNMP community
.UNINDENT
.INDENT 0.0
.TP
.B \-\-snmp\-port SNMP_PORT
SNMP port
.UNINDENT
.INDENT 0.0
.TP
.B \-\-snmp\-version SNMP_VERSION
SNMP version (1, 2c or 3)
.UNINDENT
.INDENT 0.0
.TP
.B \-\-snmp\-user SNMP_USER
SNMP username (only for SNMPv3)
.UNINDENT
.INDENT 0.0
.TP
.B \-\-snmp\-auth SNMP_AUTH
SNMP authentication key (only for SNMPv3)
.UNINDENT
.INDENT 0.0
.TP
.B \-\-snmp\-force
force SNMP mode
.UNINDENT
.INDENT 0.0
.TP
.B \-t TIME, \-\-time TIME
set refresh time in seconds [default: 3 sec]
.UNINDENT
.INDENT 0.0
.TP
.B \-w, \-\-webserver
run Glances in web server mode (bottle lib needed)
.UNINDENT
.INDENT 0.0
.TP
.B \-\-cached\-time CACHED_TIME
set the server cache time [default: 1 sec]
.UNINDENT
.INDENT 0.0
.TP
.B open\-web\-browser
try to open the Web UI in the default Web browser
.UNINDENT
.INDENT 0.0
.TP
.B \-q, \-\-quiet
do not display the curses interface
.UNINDENT
.INDENT 0.0
.TP
.B \-f PROCESS_FILTER, \-\-process\-filter PROCESS_FILTER
set the process filter pattern (regular expression)
.UNINDENT
.INDENT 0.0
.TP
.B \-\-process\-short\-name
force short name for processes name
.UNINDENT
.INDENT 0.0
.TP
.B \-\-hide\-kernel\-threads
hide kernel threads in process list
.UNINDENT
.INDENT 0.0
.TP
.B \-\-tree
display processes as a tree
.UNINDENT
.INDENT 0.0
.TP
.B \-b, \-\-byte
display network rate in byte per second
.UNINDENT
.INDENT 0.0
.TP
.B \-\-diskio\-show\-ramfs
show RAM FS in the DiskIO plugin
.UNINDENT
.INDENT 0.0
.TP
.B \-\-diskio\-iops
show I/O per second in the DiskIO plugin
.UNINDENT
.INDENT 0.0
.TP
.B \-\-fahrenheit
display temperature in Fahrenheit (default is Celsius)
.UNINDENT
.INDENT 0.0
.TP
.B \-\-fs\-free\-space
display FS free space instead of used
.UNINDENT
.INDENT 0.0
.TP
.B \-\-theme\-white
optimize display colors for white background
.UNINDENT
.INDENT 0.0
.TP
.B \-\-disable\-check\-update
disable online Glances version ckeck
.UNINDENT
.SH INTERACTIVE COMMANDS
.sp
The following commands (key pressed) are supported while in Glances:
.INDENT 0.0
.TP
.B \fBENTER\fP
Set the process filter
.sp
\fBNOTE:\fP
.INDENT 7.0
.INDENT 3.5
On macOS please use \fBCTRL\-H\fP to delete filter.
.UNINDENT
.UNINDENT
.sp
Filter is a regular expression pattern:
.INDENT 7.0
.IP \(bu 2
\fBgnome\fP: matches all processes starting with the \fBgnome\fP
string
.IP \(bu 2
\fB\&.*gnome.*\fP: matches all processes containing the \fBgnome\fP
string
.UNINDENT
.TP
.B \fBa\fP
Sort process list automatically
.INDENT 7.0
.IP \(bu 2
If CPU \fB>70%\fP, sort processes by CPU usage
.IP \(bu 2
If MEM \fB>70%\fP, sort processes by MEM usage
.IP \(bu 2
If CPU iowait \fB>60%\fP, sort processes by I/O read and write
.UNINDENT
.TP
.B \fBA\fP
Enable/disable Application Monitoring Process
.TP
.B \fBb\fP
Switch between bit/s or Byte/s for network I/O
.TP
.B \fBB\fP
View disk I/O counters per second
.TP
.B \fBc\fP
Sort processes by CPU usage
.TP
.B \fBd\fP
Show/hide disk I/O stats
.TP
.B \fBD\fP
Enable/disable Docker stats
.TP
.B \fBe\fP
Enable/disable top extended stats
.TP
.B \fBE\fP
Erase current process filter
.TP
.B \fBf\fP
Show/hide file system and folder monitoring stats
.TP
.B \fBF\fP
Switch between file system used and free space
.TP
.B \fBg\fP
Generate graphs for current history
.TP
.B \fBh\fP
Show/hide the help screen
.TP
.B \fBi\fP
Sort processes by I/O rate
.TP
.B \fBI\fP
Show/hide IP module
.TP
.B \fBl\fP
Show/hide log messages
.TP
.B \fBm\fP
Sort processes by MEM usage
.TP
.B \fBM\fP
Reset processes summary min/max
.TP
.B \fBn\fP
Show/hide network stats
.TP
.B \fBN\fP
Show/hide current time
.TP
.B \fBp\fP
Sort processes by name
.TP
.B \fBq|ESC\fP
Quit the current Glances session
.TP
.B \fBQ\fP
Show/hide IRQ module
.TP
.B \fBr\fP
Reset history
.TP
.B \fBR\fP
Show/hide RAID plugin
.TP
.B \fBs\fP
Show/hide sensors stats
.TP
.B \fBt\fP
Sort process by CPU times (TIME+)
.TP
.B \fBT\fP
View network I/O as combination
.TP
.B \fBu\fP
Sort processes by USER
.TP
.B \fBU\fP
View cumulative network I/O
.TP
.B \fBw\fP
Delete finished warning log messages
.TP
.B \fBW\fP
Show/hide Wifi module
.TP
.B \fBx\fP
Delete finished warning and critical log messages
.TP
.B \fBz\fP
Show/hide processes stats
.TP
.B \fB0\fP
Enable/disable Irix/Solaris mode
.sp
Task\(aqs CPU usage will be divided by the total number of CPUs
.TP
.B \fB1\fP
Switch between global CPU and per\-CPU stats
.TP
.B \fB2\fP
Enable/disable left sidebar
.TP
.B \fB3\fP
Enable/disable the quick look module
.TP
.B \fB4\fP
Enable/disable all but quick look and load module
.TP
.B \fB5\fP
Enable/disable top menu (QuickLook, CPU, MEM, SWAP and LOAD)
.TP
.B \fB6\fP
Enable/disable mean GPU mode
.TP
.B \fB/\fP
Switch between process command line or command name
.UNINDENT
.sp
In the Glances client browser (accessible through the \fB\-\-browser\fP
command line argument):
.INDENT 0.0
.TP
.B \fBENTER\fP
Run the selected server
.TP
.B \fBUP\fP
Up in the servers list
.TP
.B \fBDOWN\fP
Down in the servers list
.TP
.B \fBq|ESC\fP
Quit Glances
.UNINDENT
.SH CONFIGURATION
.sp
No configuration file is mandatory to use Glances.
.sp
Furthermore a configuration file is needed to access more settings.
.SH LOCATION
.sp
\fBNOTE:\fP
.INDENT 0.0
.INDENT 3.5
A template is available in the \fB/usr{,/local}/share/doc/glances\fP
(Unix\-like) directory or directly on \fI\%GitHub\fP\&.
.UNINDENT
.UNINDENT
.sp
You can put your own \fBglances.conf\fP file in the following locations:
.TS
center;
|l|l|.
_
T{
\fBLinux\fP, \fBSunOS\fP
T}	T{
~/.config/glances, /etc/glances
T}
_
T{
\fB*BSD\fP
T}	T{
~/.config/glances, /usr/local/etc/glances
T}
_
T{
\fBmacOS\fP
T}	T{
~/Library/Application Support/glances, /usr/local/etc/glances
T}
_
T{
\fBWindows\fP
T}	T{
%APPDATA%\eglances
T}
_
.TE
.INDENT 0.0
.IP \(bu 2
On Windows XP, \fB%APPDATA%\fP is: \fBC:\eDocuments and Settings\e<USERNAME>\eApplication Data\fP\&.
.IP \(bu 2
On Windows Vista and later: \fBC:\eUsers\e<USERNAME>\eAppData\eRoaming\fP\&.
.UNINDENT
.sp
User\-specific options override system\-wide options and options given on
the command line override either.
.SH SYNTAX
.sp
Glances reads configuration files in the \fIini\fP syntax.
.sp
A first section (called global) is available:
.INDENT 0.0
.INDENT 3.5
.sp
.nf
.ft C
[global]
# Does Glances should check if a newer version is available on PyPI?
check_update=true
.ft P
.fi
.UNINDENT
.UNINDENT
.sp
Each plugin, export module and application monitoring process (AMP) can
have a section. Below an example for the CPU plugin:
.INDENT 0.0
.INDENT 3.5
.sp
.nf
.ft C
[cpu]
user_careful=50
user_warning=70
user_critical=90
iowait_careful=50
iowait_warning=70
iowait_critical=90
system_careful=50
system_warning=70
system_critical=90
steal_careful=50
steal_warning=70
steal_critical=90
.ft P
.fi
.UNINDENT
.UNINDENT
.sp
an InfluxDB export module:
.INDENT 0.0
.INDENT 3.5
.sp
.nf
.ft C
[influxdb]
# Configuration for the \-\-export\-influxdb option
# https://influxdb.com/
host=localhost
port=8086
user=root
password=root
db=glances
prefix=localhost
#tags=foo:bar,spam:eggs
.ft P
.fi
.UNINDENT
.UNINDENT
.sp
or a Nginx AMP:
.INDENT 0.0
.INDENT 3.5
.sp
.nf
.ft C
[amp_nginx]
# Nginx status page should be enable (https://easyengine.io/tutorials/nginx/status\-page/)
enable=true
regex=\e/usr\e/sbin\e/nginx
refresh=60
one_line=false
status_url=http://localhost/nginx_status
.ft P
.fi
.UNINDENT
.UNINDENT
.SH LOGGING
.sp
Glances logs all of its internal messages to a log file.
.sp
\fBDEBUG\fP messages can been logged using the \fB\-d\fP option on the command
line.
.sp
By default, the \fBglances\-USERNAME.log\fP file is under the temporary directory:
.TS
center;
|l|l|.
_
T{
\fB*nix\fP
T}	T{
/tmp
T}
_
T{
\fBWindows\fP
T}	T{
%TEMP%
T}
_
.TE
.INDENT 0.0
.IP \(bu 2
On Windows XP, \fB%TEMP%\fP is: \fBC:\eDocuments and Settings\e<USERNAME>\eLocal Settings\eTemp\fP\&.
.IP \(bu 2
On Windows Vista and later: \fBC:\eUsers\e<USERNAME>\eAppData\eLocal\eTemp\fP\&.
.UNINDENT
.sp
If you want to use another system path or change the log message, you
can use your own logger configuration. First of all, you have to create
a \fBglances.json\fP file with, for example, the following content (JSON
format):
.INDENT 0.0
.INDENT 3.5
.sp
.nf
.ft C
{
    "version": 1,
    "disable_existing_loggers": "False",
    "root": {
        "level": "INFO",
        "handlers": ["file", "console"]
    },
    "formatters": {
        "standard": {
            "format": "%(asctime)s \-\- %(levelname)s \-\- %(message)s"
        },
        "short": {
            "format": "%(levelname)s: %(message)s"
        },
        "free": {
            "format": "%(message)s"
        }
    },
    "handlers": {
        "file": {
            "level": "DEBUG",
            "class": "logging.handlers.RotatingFileHandler",
            "formatter": "standard",
            "filename": "/var/tmp/glances.log"
        },
        "console": {
            "level": "CRITICAL",
            "class": "logging.StreamHandler",
            "formatter": "free"
        }
    },
    "loggers": {
        "debug": {
            "handlers": ["file", "console"],
            "level": "DEBUG"
        },
        "verbose": {
            "handlers": ["file", "console"],
            "level": "INFO"
        },
        "standard": {
            "handlers": ["file"],
            "level": "INFO"
        },
        "requests": {
            "handlers": ["file", "console"],
            "level": "ERROR"
        },
        "elasticsearch": {
            "handlers": ["file", "console"],
            "level": "ERROR"
        },
        "elasticsearch.trace": {
            "handlers": ["file", "console"],
            "level": "ERROR"
        }
    }
}
.ft P
.fi
.UNINDENT
.UNINDENT
.sp
and start Glances using the following command line:
.INDENT 0.0
.INDENT 3.5
.sp
.nf
.ft C
LOG_CFG=<path>/glances.json glances
.ft P
.fi
.UNINDENT
.UNINDENT
.sp
\fBNOTE:\fP
.INDENT 0.0
.INDENT 3.5
Replace \fB<path>\fP by the folder where your \fBglances.json\fP file
is hosted.
.UNINDENT
.UNINDENT
.SH EXAMPLES
.sp
Monitor local machine (standalone mode):
.INDENT 0.0
.INDENT 3.5
$ glances
.UNINDENT
.UNINDENT
.sp
Monitor local machine with the web interface (Web UI):
.INDENT 0.0
.INDENT 3.5
$ glances \-w
.UNINDENT
.UNINDENT
.sp
Monitor local machine and export stats to a CSV file:
.INDENT 0.0
.INDENT 3.5
$ glances \-\-export\-csv
.UNINDENT
.UNINDENT
.sp
Monitor local machine and export stats to a InfluxDB server with 5s
refresh time (also possible to export to OpenTSDB, Cassandra, Statsd,
ElasticSearch, RabbitMQ and Riemann):
.INDENT 0.0
.INDENT 3.5
$ glances \-t 5 \-\-export\-influxdb
.UNINDENT
.UNINDENT
.sp
Start a Glances server (server mode):
.INDENT 0.0
.INDENT 3.5
$ glances \-s
.UNINDENT
.UNINDENT
.sp
Connect Glances to a Glances server (client mode):
.INDENT 0.0
.INDENT 3.5
$ glances \-c <ip_server>
.UNINDENT
.UNINDENT
.sp
Connect to a Glances server and export stats to a StatsD server:
.INDENT 0.0
.INDENT 3.5
$ glances \-c <ip_server> \-\-export\-statsd
.UNINDENT
.UNINDENT
.sp
Start the client browser (browser mode):
.INDENT 0.0
.INDENT 3.5
$ glances \-\-browser
.UNINDENT
.UNINDENT
.SH AUTHOR
.sp
Nicolas Hennion aka Nicolargo <\fI\%contact@nicolargo.com\fP>
.SH COPYRIGHT
2017, Nicolas Hennion
.\" Generated by docutils manpage writer.
.
                                           ./usr/local/lib/                                                                                    0000775 0000000 0000000 00000000000 13070471670 010561  5                                                                                                    ustar                                                                                                                                                                                                                                                          ./usr/local/lib/python2.7/                                                                          0000775 0000000 0000000 00000000000 13070471670 012331  5                                                                                                    ustar                                                                                                                                                                                                                                                          ./usr/local/lib/python2.7/dist-packages/                                                            0000775 0000000 0000000 00000000000 13070471670 015050  5                                                                                                    ustar                                                                                                                                                                                                                                                          ./usr/local/lib/python2.7/dist-packages/Glances-2.9.1-py2.7.egg-info/                               0000775 0000000 0000000 00000000000 13070471670 021440  5                                                                                                    ustar                                                                                                                                                                                                                                                          ./usr/local/lib/python2.7/dist-packages/Glances-2.9.1-py2.7.egg-info/entry_points.txt               0000664 0000000 0000000 00000000052 13070471670 024733  0                                                                                                    ustar                                                                                                                                                                                                                                                          [console_scripts]
glances = glances:main

                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      ./usr/local/lib/python2.7/dist-packages/Glances-2.9.1-py2.7.egg-info/requires.txt                   0000664 0000000 0000000 00000000667 13070471670 024051  0                                                                                                    ustar                                                                                                                                                                                                                                                          psutil>=2.0.0

[action]
pystache

[browser]
zeroconf>=0.17

[chart]
matplotlib

[cloud]
requests

[cpuinfo]
py-cpuinfo

[docker]
docker>=2.0.0

[export]
bernhard
cassandra-driver
couchdb
elasticsearch
influxdb>=1.0.0
kafka-python
pika
potsdb
prometheus_client
pyzmq
statsd

[folders:python_version<"3.5"]
scandir

[gpu:python_version=="2.7"]
nvidia-ml-py

[ip]
netifaces

[raid]
pymdstat

[snmp]
pysnmp

[web]
bottle
requests

[wifi]
wifi
                                                                         ./usr/local/lib/python2.7/dist-packages/Glances-2.9.1-py2.7.egg-info/PKG-INFO                       0000664 0000000 0000000 00000034604 13070471670 022544  0                                                                                                    ustar                                                                                                                                                                                                                                                          Metadata-Version: 1.1
Name: Glances
Version: 2.9.1
Summary: A cross-platform curses-based monitoring tool
Home-page: https://github.com/nicolargo/glances
Author: Nicolas Hennion
Author-email: nicolas@nicolargo.com
License: LGPLv3
Description: ===============================
        Glances - An eye on your system
        ===============================
        
        .. image:: https://img.shields.io/pypi/v/glances.svg
            :target: https://pypi.python.org/pypi/Glances
        
        .. image:: https://img.shields.io/github/stars/nicolargo/glances.svg
            :target: https://github.com/nicolargo/glances/
            :alt: Github stars
        
        .. image:: https://img.shields.io/travis/nicolargo/glances/master.svg?maxAge=3600&label=Linux%20/%20BSD%20/%20macOS
            :target: https://travis-ci.org/nicolargo/glances
            :alt: Linux tests (Travis)
        
        .. image:: https://img.shields.io/appveyor/ci/nicolargo/glances/master.svg?maxAge=3600&label=Windows
            :target: https://ci.appveyor.com/project/nicolargo/glances
            :alt: Windows tests (Appveyor)
        
        .. image:: https://img.shields.io/scrutinizer/g/nicolargo/glances.svg
            :target: https://scrutinizer-ci.com/g/nicolargo/glances/
        
        Follow Glances on Twitter: `@nicolargo`_ or `@glances_system`_
        
        Summary
        =======
        
        **Glances** is a cross-platform monitoring tool which aims to present a
        maximum of information in a minimum of space through a curses or Web
        based interface. It can adapt dynamically the displayed information
        depending on the user interface size.
        
        .. image:: https://raw.githubusercontent.com/nicolargo/glances/develop/docs/_static/glances-summary.png
        
        It can also work in client/server mode. Remote monitoring could be done
        via terminal, Web interface or API (XML-RPC and RESTful). Stats can also
        be exported to files or external time/value databases.
        
        .. image:: https://raw.githubusercontent.com/nicolargo/glances/develop/docs/_static/glances-responsive-webdesign.png
        
        Glances is written in Python and uses libraries to grab information from
        your system. It is based on an open architecture where developers can
        add new plugins or exports modules.
        
        Requirements
        ============
        
        - ``python 2.7,>=3.3``
        - ``psutil>=2.0.0`` (better with latest version)
        
        Optional dependencies:
        
        - ``bernhard`` (for the Riemann export module)
        - ``bottle`` (for Web server mode)
        - ``cassandra-driver`` (for the Cassandra export module)
        - ``couchdb`` (for the CouchDB export module)
        - ``docker`` (for the Docker monitoring support) [Linux-only]
        - ``elasticsearch`` (for the Elastic Search export module)
        - ``hddtemp`` (for HDD temperature monitoring support) [Linux-only]
        - ``influxdb`` (for the InfluxDB export module)
        - ``kafka-python`` (for the Kafka export module)
        - ``matplotlib`` (for graphical/chart support)
        - ``netifaces`` (for the IP plugin)
        - ``nvidia-ml-py`` (for the GPU plugin) [Python 2-only]
        - ``pika`` (for the RabbitMQ/ActiveMQ export module)
        - ``potsdb`` (for the OpenTSDB export module)
        - ``prometheus_client`` (for the Prometheus export module)
        - ``py-cpuinfo`` (for the Quicklook CPU info module)
        - ``pymdstat`` (for RAID support) [Linux-only]
        - ``pysnmp`` (for SNMP support)
        - ``pystache`` (for the action script feature)
        - ``pyzmq`` (for the ZeroMQ export module)
        - ``requests`` (for the Ports and Cloud plugins)
        - ``scandir`` (for the Folders plugin) [Only for Python < 3.5]
        - ``statsd`` (for the StatsD export module)
        - ``wifi`` (for the wifi plugin) [Linux-only]
        - ``zeroconf`` (for the autodiscover mode)
        
        *Note for Python 2.6 users*
        
        Since version 2.7, Glances no longer support Python 2.6. Please upgrade
        to at least Python 2.7/3.3+ or downgrade to Glances 2.6.2 (latest version
        with Python 2.6 support).
        
        *Note for CentOS Linux 6 and 7 users*
        
        Python 2.7, 3.3 and 3.4 are now available via SCLs. See:
        https://lists.centos.org/pipermail/centos-announce/2015-December/021555.html.
        
        Installation
        ============
        
        Several method to test/install Glances on your system. Choose your weapon !
        
        Glances Auto Install script: the total way
        ------------------------------------------
        
        To install both dependencies and latest Glances production ready version
        (aka *master* branch), just enter the following command line:
        
        .. code-block:: console
        
            curl -L https://bit.ly/glances | /bin/bash
        
        or
        
        .. code-block:: console
        
            wget -O- https://bit.ly/glances | /bin/bash
        
        *Note*: Only supported on some GNU/Linux distributions. If you want to
        support other distributions, please contribute to `glancesautoinstall`_.
        
        PyPI: The simple way
        --------------------
        
        Glances is on ``PyPI``. By using PyPI, you are sure to have the latest
        stable version.
        
        To install, simply use ``pip``:
        
        .. code-block:: console
        
            pip install glances
        
        *Note*: Python headers are required to install `psutil`_. For example,
        on Debian/Ubuntu you need to install first the *python-dev* package.
        For Fedora/CentOS/RHEL install first *python-devel* package. For Windows,
        just install psutil from the binary installation file.
        
        *Note 2 (for the Wifi plugin)*: If you want to use the Wifi plugin, you need
        to install the *wireless-tools* package on your system.
        
        You can also install the following libraries in order to use optional
        features (like the Web interface, exports modules...):
        
        .. code-block:: console
        
            pip install glances[action,browser,cloud,cpuinfo,chart,docker,export,folders,gpu,ip,raid,snmp,web,wifi]
        
        To upgrade Glances to the latest version:
        
        .. code-block:: console
        
            pip install --upgrade glances
            pip install --upgrade glances[...]
        
        If you need to install Glances in a specific user location, use:
        
        .. code-block:: console
        
            export PYTHONUSERBASE=~/mylocalpath
            pip install --user glances
        
        Docker: the funny way
        ---------------------
        
        A Glances container is available. It will include the latest development
        HEAD version. You can use it to monitor your server and all your others
        containers !
        
        Get the Glances container:
        
        .. code-block:: console
        
            docker pull nicolargo/glances
        
        Run the container in *console mode*:
        
        .. code-block:: console
        
            docker run -v /var/run/docker.sock:/var/run/docker.sock:ro --pid host -it docker.io/nicolargo/glances
        
        Additionally, if you want to use your own glances.conf file, you can
        create your own Dockerfile:
        
        .. code-block:: console
        
            FROM nicolargo/glances
            COPY glances.conf /glances/conf/glances.conf
            CMD python -m glances -C /glances/conf/glances.conf $GLANCES_OPT
        
        Alternatively, you can specify something along the same lines with
        docker run options:
        
        .. code-block:: console
        
            docker run -v ./glances.conf:/glances/conf/glances.conf -v /var/run/docker.sock:/var/run/docker.sock:ro --pid host -it docker.io/nicolargo/glances
        
        Where ./glances.conf is a local directory containing your glances.conf file.
        
        Run the container in *Web server mode* (notice the `GLANCES_OPT` environment
        variable setting parameters for the glances startup command):
        
        .. code-block:: console
        
            docker run -d --restart="always" -p 61208-61209:61208-61209 -e GLANCES_OPT="-w" -v /var/run/docker.sock:/var/run/docker.sock:ro --pid host docker.io/nicolargo/glances
        
        GNU/Linux
        ---------
        
        `Glances` is available on many Linux distributions, so you should be
        able to install it using your favorite package manager. Be aware that
        Glances may not be the latest one using this method.
        
        FreeBSD
        -------
        
        To install the binary package:
        
        .. code-block:: console
        
            # pkg install py27-glances
        
        To install Glances from ports:
        
        .. code-block:: console
        
            # cd /usr/ports/sysutils/py-glances/
            # make install clean
        
        macOS
        -----
        
        macOS users can install Glances using ``Homebrew`` or ``MacPorts``.
        
        Homebrew
        ````````
        
        .. code-block:: console
        
            $ brew install python
            $ pip install glances
        
        MacPorts
        ````````
        
        .. code-block:: console
        
            $ sudo port install glances
        
        Windows
        -------
        
        Install `Python`_ for Windows (Python 2.7.9+ and 3.4+ ship with pip) and
        then just:
        
        .. code-block:: console
        
            $ pip install glances
        
        Android
        -------
        
        You need a rooted device and the `Termux`_ application (available on the
        Google Store).
        
        Start Termux on your device and enter:
        
        .. code-block:: console
        
            $ apt update
            $ apt upgrade
            $ apt install clang python python-dev
            $ pip install glances
        
        And start Glances:
        
        .. code-block:: console
        
            $ glances
        
        Source
        ------
        
        To install Glances from source:
        
        .. code-block:: console
        
            $ wget https://github.com/nicolargo/glances/archive/vX.Y.tar.gz -O - | tar xz
            $ cd glances-*
            # python setup.py install
        
        *Note*: Python headers are required to install psutil.
        
        Chef
        ----
        
        An awesome ``Chef`` cookbook is available to monitor your infrastructure:
        https://supermarket.chef.io/cookbooks/glances (thanks to Antoine Rouyer)
        
        Puppet
        ------
        
        You can install Glances using ``Puppet``: https://github.com/rverchere/puppet-glances
        
        Usage
        =====
        
        For the standalone mode, just run:
        
        .. code-block:: console
        
            $ glances
        
        For the Web server mode, run:
        
        .. code-block:: console
        
            $ glances -w
        
        and enter the URL ``http://<ip>:61208`` in your favorite web browser.
        
        For the client/server mode, run:
        
        .. code-block:: console
        
            $ glances -s
        
        on the server side and run:
        
        .. code-block:: console
        
            $ glances -c <ip>
        
        on the client one.
        
        You can also detect and display all Glances servers available on your
        network or defined in the configuration file:
        
        .. code-block:: console
        
            $ glances --browser
        
        and RTFM, always.
        
        Documentation
        =============
        
        For complete documentation have a look at the readthedocs_ website.
        
        If you have any question (after RTFM!), please post it on the official Q&A `forum`_.
        
        Gateway to other services
        =========================
        
        Glances can export stats to: ``CSV`` file, ``InfluxDB``, ``Cassandra``, ``CouchDB``,
        ``OpenTSDB``, ``Prometheus``, ``StatsD``, ``ElasticSearch``, ``RabbitMQ/ActiveMQ``,
        ``ZeroMQ``, ``Kafka`` and ``Riemann`` server.
        
        How to contribute ?
        ===================
        
        If you want to contribute to the Glances project, read this `wiki`_ page.
        
        There is also a chat dedicated to the Glances developers:
        
        .. image:: https://badges.gitter.im/Join%20Chat.svg
                :target: https://gitter.im/nicolargo/glances?utm_source=badge&utm_medium=badge&utm_campaign=pr-badge&utm_content=badge
        
        Author
        ======
        
        Nicolas Hennion (@nicolargo) <nicolas@nicolargo.com>
        
        License
        =======
        
        LGPLv3. See ``COPYING`` for more details.
        
        .. _psutil: https://github.com/giampaolo/psutil
        .. _glancesautoinstall: https://github.com/nicolargo/glancesautoinstall
        .. _@nicolargo: https://twitter.com/nicolargo
        .. _@glances_system: https://twitter.com/glances_system
        .. _Python: https://www.python.org/getit/
        .. _Termux: https://play.google.com/store/apps/details?id=com.termux
        .. _readthedocs: https://glances.readthedocs.io/
        .. _forum: https://groups.google.com/forum/?hl=en#!forum/glances-users
        .. _wiki: https://github.com/nicolargo/glances/wiki/How-to-contribute-to-Glances-%3F
        
Keywords: cli curses monitoring system
Platform: UNKNOWN
Classifier: Development Status :: 5 - Production/Stable
Classifier: Environment :: Console :: Curses
Classifier: Environment :: Web Environment
Classifier: Framework :: Bottle
Classifier: Intended Audience :: Developers
Classifier: Intended Audience :: End Users/Desktop
Classifier: Intended Audience :: System Administrators
Classifier: License :: OSI Approved :: GNU Lesser General Public License v3 (LGPLv3)
Classifier: Operating System :: OS Independent
Classifier: Programming Language :: Python :: 2
Classifier: Programming Language :: Python :: 2.7
Classifier: Programming Language :: Python :: 3
Classifier: Programming Language :: Python :: 3.3
Classifier: Programming Language :: Python :: 3.4
Classifier: Programming Language :: Python :: 3.5
Classifier: Programming Language :: Python :: 3.6
Classifier: Topic :: System :: Monitoring
                                                                                                                            ./usr/local/lib/python2.7/dist-packages/Glances-2.9.1-py2.7.egg-info/top_level.txt                  0000664 0000000 0000000 00000000010 13070471670 024161  0                                                                                                    ustar                                                                                                                                                                                                                                                          glances
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        ./usr/local/lib/python2.7/dist-packages/Glances-2.9.1-py2.7.egg-info/SOURCES.txt                    0000664 0000000 0000000 00000021371 13070471670 023330  0                                                                                                    ustar                                                                                                                                                                                                                                                          AUTHORS
CONTRIBUTING.md
COPYING
MANIFEST.in
NEWS
README.rst
setup.cfg
setup.py
Glances.egg-info/PKG-INFO
Glances.egg-info/SOURCES.txt
Glances.egg-info/dependency_links.txt
Glances.egg-info/entry_points.txt
Glances.egg-info/requires.txt
Glances.egg-info/top_level.txt
conf/glances.conf
docs/Makefile
docs/README.txt
docs/api.rst
docs/cmds.rst
docs/conf.py
docs/config.rst
docs/glances.rst
docs/index.rst
docs/install.rst
docs/make.bat
docs/quickstart.rst
docs/support.rst
docs/_static/amp-dropbox.png
docs/_static/amp-python-warning.png
docs/_static/amp-python.png
docs/_static/amps.png
docs/_static/browser.png
docs/_static/connected.png
docs/_static/cpu-wide.png
docs/_static/cpu.png
docs/_static/disconnected.png
docs/_static/diskio.png
docs/_static/docker.png
docs/_static/folders.png
docs/_static/fs.png
docs/_static/glances-responsive-webdesign.png
docs/_static/glances-summary.png
docs/_static/gpu.png
docs/_static/grafana.png
docs/_static/header.png
docs/_static/irq.png
docs/_static/load.png
docs/_static/logs.png
docs/_static/mem-wide.png
docs/_static/mem.png
docs/_static/monitored.png
docs/_static/network.png
docs/_static/per-cpu.png
docs/_static/pergpu.png
docs/_static/ports.png
docs/_static/processlist-filter.png
docs/_static/processlist-top.png
docs/_static/processlist-wide.png
docs/_static/processlist.png
docs/_static/prometheus_exporter.png
docs/_static/prometheus_server.png
docs/_static/quicklook-percpu.png
docs/_static/quicklook.png
docs/_static/raid.png
docs/_static/screencast.gif
docs/_static/screenshot-web.png
docs/_static/screenshot-web2.png
docs/_static/screenshot-wide.png
docs/_static/screenshot.png
docs/_static/sensors.png
docs/_static/wifi.png
docs/_templates/links.html
docs/aoa/actions.rst
docs/aoa/amps.rst
docs/aoa/cpu.rst
docs/aoa/disk.rst
docs/aoa/docker.rst
docs/aoa/folders.rst
docs/aoa/fs.rst
docs/aoa/gpu.rst
docs/aoa/header.rst
docs/aoa/index.rst
docs/aoa/irq.rst
docs/aoa/load.rst
docs/aoa/logs.rst
docs/aoa/memory.rst
docs/aoa/monitor.rst
docs/aoa/network.rst
docs/aoa/ports.rst
docs/aoa/ps.rst
docs/aoa/quicklook.rst
docs/aoa/sensors.rst
docs/aoa/wifi.rst
docs/gw/cassandra.rst
docs/gw/couchdb.rst
docs/gw/csv.rst
docs/gw/elastic.rst
docs/gw/index.rst
docs/gw/influxdb.rst
docs/gw/kafka.rst
docs/gw/opentsdb.rst
docs/gw/prometheus.rst
docs/gw/rabbitmq.rst
docs/gw/riemann.rst
docs/gw/statsd.rst
docs/gw/zeromq.rst
docs/man/glances.1
glances/__init__.py
glances/__main__.py
glances/actions.py
glances/amps_list.py
glances/attribute.py
glances/autodiscover.py
glances/client.py
glances/client_browser.py
glances/compat.py
glances/config.py
glances/cpu_percent.py
glances/filter.py
glances/folder_list.py
glances/globals.py
glances/history.py
glances/logger.py
glances/logs.py
glances/main.py
glances/outdated.py
glances/password.py
glances/password_list.py
glances/ports_list.py
glances/processes.py
glances/processes_tree.py
glances/server.py
glances/snmp.py
glances/standalone.py
glances/static_list.py
glances/stats.py
glances/stats_client.py
glances/stats_client_snmp.py
glances/stats_server.py
glances/timer.py
glances/webserver.py
glances/amps/__init__.py
glances/amps/glances_amp.py
glances/amps/glances_default.py
glances/amps/glances_nginx.py
glances/amps/glances_systemd.py
glances/amps/glances_systemv.py
glances/exports/__init__.py
glances/exports/glances_cassandra.py
glances/exports/glances_couchdb.py
glances/exports/glances_csv.py
glances/exports/glances_elasticsearch.py
glances/exports/glances_export.py
glances/exports/glances_influxdb.py
glances/exports/glances_kafka.py
glances/exports/glances_opentsdb.py
glances/exports/glances_prometheus.py
glances/exports/glances_rabbitmq.py
glances/exports/glances_riemann.py
glances/exports/glances_statsd.py
glances/exports/glances_zeromq.py
glances/exports/graph.py
glances/outputs/__init__.py
glances/outputs/glances_bars.py
glances/outputs/glances_bottle.py
glances/outputs/glances_curses.py
glances/outputs/glances_curses_browser.py
glances/outputs/static/README.md
glances/outputs/static/bower.json
glances/outputs/static/favicon.ico
glances/outputs/static/gulpfile.js
glances/outputs/static/package.json
glances/outputs/static/css/bootstrap.css
glances/outputs/static/css/normalize.css
glances/outputs/static/css/style.css
glances/outputs/static/html/help.html
glances/outputs/static/html/index.html
glances/outputs/static/html/stats.html
glances/outputs/static/html/plugins/alert.html
glances/outputs/static/html/plugins/alerts.html
glances/outputs/static/html/plugins/amps.html
glances/outputs/static/html/plugins/cloud.html
glances/outputs/static/html/plugins/cpu.html
glances/outputs/static/html/plugins/diskio.html
glances/outputs/static/html/plugins/docker.html
glances/outputs/static/html/plugins/folders.html
glances/outputs/static/html/plugins/fs.html
glances/outputs/static/html/plugins/gpu.html
glances/outputs/static/html/plugins/ip.html
glances/outputs/static/html/plugins/irq.html
glances/outputs/static/html/plugins/load.html
glances/outputs/static/html/plugins/mem.html
glances/outputs/static/html/plugins/mem_more.html
glances/outputs/static/html/plugins/memswap.html
glances/outputs/static/html/plugins/network.html
glances/outputs/static/html/plugins/per_cpu.html
glances/outputs/static/html/plugins/ports.html
glances/outputs/static/html/plugins/processcount.html
glances/outputs/static/html/plugins/processlist.html
glances/outputs/static/html/plugins/quicklook.html
glances/outputs/static/html/plugins/raid.html
glances/outputs/static/html/plugins/sensors.html
glances/outputs/static/html/plugins/system.html
glances/outputs/static/html/plugins/uptime.html
glances/outputs/static/html/plugins/wifi.html
glances/outputs/static/images/glances.png
glances/outputs/static/js/app.js
glances/outputs/static/js/controllers.js
glances/outputs/static/js/directives.js
glances/outputs/static/js/filters.js
glances/outputs/static/js/variables.js
glances/outputs/static/js/services/core/favicon.js
glances/outputs/static/js/services/core/stats.js
glances/outputs/static/js/services/plugins/alert.js
glances/outputs/static/js/services/plugins/amps.js
glances/outputs/static/js/services/plugins/cloud.js
glances/outputs/static/js/services/plugins/cpu.js
glances/outputs/static/js/services/plugins/diskio.js
glances/outputs/static/js/services/plugins/docker.js
glances/outputs/static/js/services/plugins/folders.js
glances/outputs/static/js/services/plugins/fs.js
glances/outputs/static/js/services/plugins/gpu.js
glances/outputs/static/js/services/plugins/ip.js
glances/outputs/static/js/services/plugins/irq.js
glances/outputs/static/js/services/plugins/load.js
glances/outputs/static/js/services/plugins/mem.js
glances/outputs/static/js/services/plugins/memswap.js
glances/outputs/static/js/services/plugins/network.js
glances/outputs/static/js/services/plugins/percpu.js
glances/outputs/static/js/services/plugins/plugin.js
glances/outputs/static/js/services/plugins/ports.js
glances/outputs/static/js/services/plugins/processcount.js
glances/outputs/static/js/services/plugins/processlist.js
glances/outputs/static/js/services/plugins/quicklook.js
glances/outputs/static/js/services/plugins/raid.js
glances/outputs/static/js/services/plugins/sensors.js
glances/outputs/static/js/services/plugins/system.js
glances/outputs/static/js/services/plugins/uptime.js
glances/outputs/static/js/services/plugins/wifi.js
glances/outputs/static/public/favicon.ico
glances/outputs/static/public/help.html
glances/outputs/static/public/index.html
glances/outputs/static/public/stats.html
glances/outputs/static/public/css/bootstrap.min.css
glances/outputs/static/public/css/normalize.min.css
glances/outputs/static/public/css/style.min.css
glances/outputs/static/public/images/glances.png
glances/outputs/static/public/js/main.min.js
glances/outputs/static/public/js/templates.min.js
glances/outputs/static/public/js/vendor.min.js
glances/plugins/__init__.py
glances/plugins/glances_alert.py
glances/plugins/glances_amps.py
glances/plugins/glances_batpercent.py
glances/plugins/glances_cloud.py
glances/plugins/glances_core.py
glances/plugins/glances_cpu.py
glances/plugins/glances_diskio.py
glances/plugins/glances_docker.py
glances/plugins/glances_folders.py
glances/plugins/glances_fs.py
glances/plugins/glances_gpu.py
glances/plugins/glances_hddtemp.py
glances/plugins/glances_help.py
glances/plugins/glances_ip.py
glances/plugins/glances_irq.py
glances/plugins/glances_load.py
glances/plugins/glances_mem.py
glances/plugins/glances_memswap.py
glances/plugins/glances_network.py
glances/plugins/glances_now.py
glances/plugins/glances_percpu.py
glances/plugins/glances_plugin.py
glances/plugins/glances_ports.py
glances/plugins/glances_processcount.py
glances/plugins/glances_processlist.py
glances/plugins/glances_psutilversion.py
glances/plugins/glances_quicklook.py
glances/plugins/glances_raid.py
glances/plugins/glances_sensors.py
glances/plugins/glances_system.py
glances/plugins/glances_uptime.py
glances/plugins/glances_wifi.py                                                                                                                                                                                                                                                                       ./usr/local/lib/python2.7/dist-packages/Glances-2.9.1-py2.7.egg-info/dependency_links.txt           0000664 0000000 0000000 00000000001 13070471670 025506  0                                                                                                    ustar                                                                                                                                                                                                                                                          
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               ./usr/local/lib/python2.7/dist-packages/glances/                                                    0000775 0000000 0000000 00000000000 13070471670 016464  5                                                                                                    ustar                                                                                                                                                                                                                                                          ./usr/local/lib/python2.7/dist-packages/glances/ports_list.py                                       0000664 0000000 0000000 00000013211 13066703446 021242  0                                                                                                    ustar                                                                                                                                                                                                                                                          # -*- coding: utf-8 -*-
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""Manage the Glances ports list (Ports plugin)."""

from glances.compat import range
from glances.logger import logger
from glances.globals import BSD

# XXX *BSDs: Segmentation fault (core dumped)
# -- https://bitbucket.org/al45tair/netifaces/issues/15
# Also used in the glances_ip plugin
if not BSD:
    try:
        import netifaces
        netifaces_tag = True
    except ImportError:
        netifaces_tag = False
else:
    netifaces_tag = False


class GlancesPortsList(object):

    """Manage the ports list for the ports plugin."""

    _section = "ports"
    _default_refresh = 60
    _default_timeout = 3

    def __init__(self, config=None, args=None):
        # ports_list is a list of dict (JSON compliant)
        # [ {'host': 'www.google.fr', 'port': 443, 'refresh': 30, 'description': Internet, 'status': True} ... ]
        # Load the configuration file
        self._ports_list = self.load(config)

    def load(self, config):
        """Load the ports list from the configuration file."""
        ports_list = []

        if config is None:
            logger.debug("No configuration file available. Cannot load ports list.")
        elif not config.has_section(self._section):
            logger.debug("No [%s] section in the configuration file. Cannot load ports list." % self._section)
        else:
            logger.debug("Start reading the [%s] section in the configuration file" % self._section)

            refresh = int(config.get_value(self._section, 'refresh', default=self._default_refresh))
            timeout = int(config.get_value(self._section, 'timeout', default=self._default_timeout))

            # Add default gateway on top of the ports_list lits
            default_gateway = config.get_value(self._section, 'port_default_gateway', default='False')
            if default_gateway.lower().startswith('true') and netifaces_tag:
                new_port = {}
                try:
                    new_port['host'] = netifaces.gateways()['default'][netifaces.AF_INET][0]
                except KeyError:
                    new_port['host'] = None
                # ICMP
                new_port['port'] = 0
                new_port['description'] = 'DefaultGateway'
                new_port['refresh'] = refresh
                new_port['timeout'] = timeout
                new_port['status'] = None
                new_port['rtt_warning'] = None
                logger.debug("Add default gateway %s to the static list" % (new_port['host']))
                ports_list.append(new_port)

            # Read the scan list
            for i in range(1, 256):
                new_port = {}
                postfix = 'port_%s_' % str(i)

                # Read mandatories configuration key: host
                new_port['host'] = config.get_value(self._section, '%s%s' % (postfix, 'host'))

                if new_port['host'] is None:
                    continue

                # Read optionals configuration keys
                # Port is set to 0 by default. 0 mean ICMP check instead of TCP check
                new_port['port'] = config.get_value(self._section,
                                                    '%s%s' % (postfix, 'port'),
                                                    0)
                new_port['description'] = config.get_value(self._section,
                                                           '%sdescription' % postfix,
                                                           default="%s:%s" % (new_port['host'], new_port['port']))

                # Default status
                new_port['status'] = None

                # Refresh rate in second
                new_port['refresh'] = refresh

                # Timeout in second
                new_port['timeout'] = int(config.get_value(self._section,
                                                           '%stimeout' % postfix,
                                                           default=timeout))

                # RTT warning
                new_port['rtt_warning'] = config.get_value(self._section,
                                                           '%srtt_warning' % postfix,
                                                           default=None)
                if new_port['rtt_warning'] is not None:
                    # Convert to second
                    new_port['rtt_warning'] = int(new_port['rtt_warning']) / 1000.0

                # Add the server to the list
                logger.debug("Add port %s:%s to the static list" % (new_port['host'], new_port['port']))
                ports_list.append(new_port)

            # Ports list loaded
            logger.debug("Ports list loaded: %s" % ports_list)

        return ports_list

    def get_ports_list(self):
        """Return the current server list (dict of dict)."""
        return self._ports_list

    def set_server(self, pos, key, value):
        """Set the key to the value for the pos (position in the list)."""
        self._ports_list[pos][key] = value
                                                                                                                                                                                                                                                                                                                                                                                       ./usr/local/lib/python2.7/dist-packages/glances/outdated.pyc                                        0000664 0000000 0000000 00000013411 13070471670 021012  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   s�   d  Z  d d l m Z m Z d d l m Z d d l Z d d l Z d d l Z d d l Z d d l	 m
 Z
 d d l m Z m
 Z d e f d �  �  YZ d S(
 d	 �  Z d
 �  Z RS(   s�   
    This class aims at providing methods to warn the user when a new Glances
    version is available on the PyPI repository (https://pypi.python.org/pypi/Glances/).
    c         C   s�   | |  _  | |  _ t �  |  _ t j j |  j d � |  _ i t d 6d d 6t	 j
 �  d 6|  _ |  j | � t
   cache_fileR   R    t   nowt   datat   load_configR
   t   debugt   formatt   disable_check_updatet   get_pypi_version(   t   selfR   R
 S(   sH   Load outdated parameter in the global section of the configuration file.t   globalt   has_sectiont   check_updatet   falses0   Cannot find section {} in the configuration file(   t   hasattrR   t	   get_valuet   lowerR   R   R
   R   R   t   Falset   True(   R   R
        The data are stored in a cached file
        Only update online once a week
        Nt   targetR'   s#   Get Glances version from cache file(
   R   R   t   _load_cachet	   threadingt   Threadt   _update_pypi_versiont   startR   R
   R   (   R   t   cached_datat   thread(    (    s:   /usr/local/lib/python2.7/dist-packages/glances/outdated.pyR   W   s    
   R   R   R&   R'   R   (   R   (    (    s:   /usr/local/lib/python2.7/dist-packages/glances/outdated.pyt   is_outdatedl   s    %c         C   s�   t  d d � } i  } y. t |  j d � � } t j | � } Wd QXWn/ t k
 rt } t j d j |  j | � � nG Xt j d � | d |  j	 �  k s� t
 j �  | d | k r� i  } n  | S(	   s&   Load cache file and return cached datat   daysi   t   rbNs,   Cannot read version from cache file: {} ({})s   Read version from cache fileR&   R(   (   R   t   openR   t   picklet   loadt	   ExceptionR
   R   R   R&   R    R   (   R   t   max_refresh_dateR/   t   ft   e(    (    s:   /usr/local/lib/python2.7/dist-packages/glances/outdated.pyR*   u   s     
 rp } t j	 d j
 |  j | � � n Xd S(   s   Save data to the cache file.t   wbNs*   Cannot write version to cache file {} ({})(   R	   R   R4   R   R5   t   dumpR   R7   R
   t   errorR   (   R   R9   R:   (    (    s:   /usr/local/lib/python2.7/dist-packages/glances/outdated.pyt   _save_cache�   s    
 f k
 rv } t  j d j | � � n2 Xt j t
   sB   Get the latest PyPI version (as a string) via the RESTful JSON APIs9   Get latest Glances version from the PyPI RESTful API ({})u   refresh_datet   timeouti   s9   Cannot get Glances version from the PyPI RESTful API ({})t   infot   versionu   latest_versions&   Save Glances version to the cache file(   R
   R   R   t   PYPI_API_URLR    R   R   R   t   readR   R   t   jsont   loadsR   R>   (   R   t   resR:   (    (    s:   /usr/local/lib/python2.7/dist-packages/glances/outdated.pyR-   �   s    $
(
   __module__t   __doc__R   R   R&   R'   R(   R   R1   R*   R>   R-   (    (    (    s:   /usr/local/lib/python2.7/dist-packages/glances/outdated.pyR   &   s   		
   RB   t   objectR   (    (    (    s:   /usr/local/lib/python2.7/dist-packages/glances/outdated.pyt   <module>   s   "                                                                                                                                                                                                                                                       ./usr/local/lib/python2.7/dist-packages/glances/server.py                                           0000664 0000000 0000000 00000021005 13066703446 020346  0                                                                                                    ustar                                                                                                                                                                                                                                                          # -*- coding: utf-8 -*-
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""Manage the Glances server."""

import json
import socket
import sys
from base64 import b64decode

from glances import __version__
from glances.compat import SimpleXMLRPCRequestHandler, SimpleXMLRPCServer, Server
from glances.autodiscover import GlancesAutoDiscoverClient
from glances.logger import logger
from glances.stats_server import GlancesStatsServer
from glances.timer import Timer


class GlancesXMLRPCHandler(SimpleXMLRPCRequestHandler, object):

    """Main XML-RPC handler."""

    rpc_paths = ('/RPC2', )

    def end_headers(self):
        # Hack to add a specific header
        # Thk to: https://gist.github.com/rca/4063325
        self.send_my_headers()
        super(GlancesXMLRPCHandler, self).end_headers()

    def send_my_headers(self):
        # Specific header is here (solved the issue #227)
        self.send_header("Access-Control-Allow-Origin", "*")

    def authenticate(self, headers):
        # auth = headers.get('Authorization')
        try:
            (basic, _, encoded) = headers.get('Authorization').partition(' ')
        except Exception:
            # Client did not ask for authentidaction
            # If server need it then exit
            return not self.server.isAuth
        else:
            # Client authentication
            (basic, _, encoded) = headers.get('Authorization').partition(' ')
            assert basic == 'Basic', 'Only basic authentication supported'
            # Encoded portion of the header is a string
            # Need to convert to bytestring
            encoded_byte_string = encoded.encode()
            # Decode base64 byte string to a decoded byte string
            decoded_bytes = b64decode(encoded_byte_string)
            # Convert from byte string to a regular string
            decoded_string = decoded_bytes.decode()
            # Get the username and password from the string
            (username, _, password) = decoded_string.partition(':')
            # Check that username and password match internal global dictionary
            return self.check_user(username, password)

    def check_user(self, username, password):
        # Check username and password in the dictionary
        if username in self.server.user_dict:
            from glances.password import GlancesPassword
            pwd = GlancesPassword()
            return pwd.check_password(self.server.user_dict[username], password)
        else:
            return False

    def parse_request(self):
        if SimpleXMLRPCRequestHandler.parse_request(self):
            # Next we authenticate
            if self.authenticate(self.headers):
                return True
            else:
                # if authentication fails, tell the client
                self.send_error(401, 'Authentication failed')
        return False

    def log_message(self, log_format, *args):
        # No message displayed on the server side
        pass


class GlancesXMLRPCServer(SimpleXMLRPCServer, object):

    """Init a SimpleXMLRPCServer instance (IPv6-ready)."""

    finished = False

    def __init__(self, bind_address, bind_port=61209,
                 requestHandler=GlancesXMLRPCHandler):

        self.bind_address = bind_address
        self.bind_port = bind_port
        try:
            self.address_family = socket.getaddrinfo(bind_address, bind_port)[0][0]
        except socket.error as e:
            logger.error("Couldn't open socket: {}".format(e))
            sys.exit(1)

        super(GlancesXMLRPCServer, self).__init__((bind_address, bind_port), requestHandler)

    def end(self):
        """Stop the server"""
        self.server_close()
        self.finished = True

    def serve_forever(self):
        """Main loop"""
        while not self.finished:
            self.handle_request()
            logger.info(self.finished)


class GlancesInstance(object):

    """All the methods of this class are published as XML-RPC methods."""

    def __init__(self,
                 config=None,
                 args=None):
        # Init stats
        self.stats = GlancesStatsServer(config=config, args=args)

        # Initial update
        self.stats.update()

        # cached_time is the minimum time interval between stats updates
        # i.e. XML/RPC calls will not retrieve updated info until the time
        # since last update is passed (will retrieve old cached info instead)
        self.timer = Timer(0)
        self.cached_time = args.cached_time

    def __update__(self):
        # Never update more than 1 time per cached_time
        if self.timer.finished():
            self.stats.update()
            self.timer = Timer(self.cached_time)

    def init(self):
        # Return the Glances version
        return __version__

    def getAll(self):
        # Update and return all the stats
        self.__update__()
        return json.dumps(self.stats.getAll())

    def getAllPlugins(self):
        # Return the plugins list
        return json.dumps(self.stats.getAllPlugins())

    def getAllLimits(self):
        # Return all the plugins limits
        return json.dumps(self.stats.getAllLimitsAsDict())

    def getAllViews(self):
        # Return all the plugins views
        return json.dumps(self.stats.getAllViewsAsDict())

    def __getattr__(self, item):
        """Overwrite the getattr method in case of attribute is not found.

        The goal is to dynamically generate the API get'Stats'() methods.
        """
        header = 'get'
        # Check if the attribute starts with 'get'
        if item.startswith(header):
            try:
                # Update the stat
                self.__update__()
                # Return the attribute
                return getattr(self.stats, item)
            except Exception:
                # The method is not found for the plugin
                raise AttributeError(item)
        else:
            # Default behavior
            raise AttributeError(item)


class GlancesServer(object):

    """This class creates and manages the TCP server."""

    def __init__(self,
                 requestHandler=GlancesXMLRPCHandler,
                 config=None,
                 args=None):
        # Args
        self.args = args

        # Init the XML RPC server
        try:
            self.server = GlancesXMLRPCServer(args.bind_address, args.port, requestHandler)
        except Exception as e:
            logger.critical("Cannot start Glances server: {}".format(e))
            sys.exit(2)
        else:
            print('Glances XML-RPC server is running on {}:{}'.format(args.bind_address, args.port))

        # The users dict
        # username / password couple
        # By default, no auth is needed
        self.server.user_dict = {}
        self.server.isAuth = False

        # Register functions
        self.server.register_introspection_functions()
        self.server.register_instance(GlancesInstance(config, args))

        if not self.args.disable_autodiscover:
            # Note: The Zeroconf service name will be based on the hostname
            # Correct issue: Zeroconf problem with zeroconf service name #889
            self.autodiscover_client = GlancesAutoDiscoverClient(socket.gethostname().split('.', 1)[0], args)
        else:
            logger.info("Glances autodiscover announce is disabled")

    def add_user(self, username, password):
        """Add an user to the dictionary."""
        self.server.user_dict[username] = password
        self.server.isAuth = True

    def serve_forever(self):
        """Call the main loop."""
        # Set the server login/password (if -P/--password tag)
        if self.args.password != "":
            self.add_user(self.args.username, self.args.password)
        # Serve forever
        self.server.serve_forever()

    def end(self):
        """End of the Glances server session."""
        if not self.args.disable_autodiscover:
            self.autodiscover_client.close()
        self.server.end()
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           ./usr/local/lib/python2.7/dist-packages/glances/actions.py                                          0000664 0000000 0000000 00000006530 13066703446 020506  0                                                                                                    ustar                                                                                                                                                                                                                                                          # -*- coding: utf-8 -*-
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""Manage on alert actions."""

from subprocess import Popen

from glances.logger import logger
from glances.timer import Timer

try:
    import pystache
except ImportError:
    logger.debug("Pystache library not found (action scripts won't work)")
    pystache_tag = False
else:
    pystache_tag = True


class GlancesActions(object):

    """This class manage action if an alert is reached."""

    def __init__(self, args=None):
        """Init GlancesActions class."""
        # Dict with the criticity status
        # - key: stat_name
        # - value: criticity
        # Goal: avoid to execute the same command twice
        self.status = {}

        # Add a timer to avoid any trigger when Glances is started (issue#732)
        # Action can be triggered after refresh * 2 seconds
        if hasattr(args, 'time'):
            self.start_timer = Timer(args.time * 2)
        else:
            self.start_timer = Timer(3)

    def get(self, stat_name):
        """Get the stat_name criticity."""
        try:
            return self.status[stat_name]
        except KeyError:
            return None

    def set(self, stat_name, criticity):
        """Set the stat_name to criticity."""
        self.status[stat_name] = criticity

    def run(self, stat_name, criticity, commands, mustache_dict=None):
        """Run the commands (in background).

        - stats_name: plugin_name (+ header)
        - criticity: criticity of the trigger
        - commands: a list of command line with optional {{mustache}}
        - mustache_dict: Plugin stats (can be use within {{mustache}})

        Return True if the commands have been ran.
        """
        if self.get(stat_name) == criticity or not self.start_timer.finished():
            # Action already executed => Exit
            return False

        logger.debug("Run action {} for {} ({}) with stats {}".format(
            commands, stat_name, criticity, mustache_dict))

        # Run all actions in background
        for cmd in commands:
            # Replace {{arg}} by the dict one (Thk to {Mustache})
            if pystache_tag:
                cmd_full = pystache.render(cmd, mustache_dict)
            else:
                cmd_full = cmd
            # Execute the action
            logger.info("Action triggered for {} ({}): {}".format(stat_name, criticity, cmd_full))
            logger.debug("Stats value for the trigger: {}".format(mustache_dict))
            try:
                Popen(cmd_full, shell=True)
            except OSError as e:
                logger.error("Can't execute the action ({})".format(e))

        self.set(stat_name, criticity)

        return True
                                                                                                                                                                        ./usr/local/lib/python2.7/dist-packages/glances/plugins/                                            0000775 0000000 0000000 00000000000 13070471670 020145  5                                                                                                    ustar                                                                                                                                                                                                                                                          ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_wifi.py                             0000664 0000000 0000000 00000015770 13066703446 023167  0                                                                                                    ustar                                                                                                                                                                                                                                                          # -*- coding: utf-8 -*-
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""Wifi plugin."""

import operator

from glances.logger import logger
from glances.plugins.glances_plugin import GlancesPlugin

import psutil
# Use the Wifi Python lib (https://pypi.python.org/pypi/wifi)
# Linux-only
try:
    from wifi.scan import Cell
    from wifi.exceptions import InterfaceError
except ImportError:
    logger.debug("Wifi library not found. Glances cannot grab Wifi info.")
    wifi_tag = False
else:
    wifi_tag = True


class Plugin(GlancesPlugin):

    """Glances Wifi plugin.
    Get stats of the current Wifi hotspots.
    """

    def __init__(self, args=None):
        """Init the plugin."""
        super(Plugin, self).__init__(args=args)

        # We want to display the stat in the curse interface
        self.display_curse = True

        # Init the stats
        self.reset()

    def get_key(self):
        """Return the key of the list.

        :returns: string -- SSID is the dict key
        """
        return 'ssid'

    def reset(self):
        """Reset/init the stats to an empty list.

        :returns: None
        """
        self.stats = []

    @GlancesPlugin._check_decorator
    @GlancesPlugin._log_result_decorator
    def update(self):
        """Update Wifi stats using the input method.

        Stats is a list of dict (one dict per hotspot)

        :returns: list -- Stats is a list of dict (hotspot)
        """
        # Reset stats
        self.reset()

        # Exist if we can not grab the stats
        if not wifi_tag:
            return self.stats

        if self.input_method == 'local':
            # Update stats using the standard system lib

            # Grab network interface stat using the PsUtil net_io_counter method
            try:
                netiocounters = psutil.net_io_counters(pernic=True)
            except UnicodeDecodeError:
                return self.stats

            for net in netiocounters:
                # Do not take hidden interface into account
                if self.is_hide(net):
                    continue

                # Grab the stats using the Wifi Python lib
                try:
                    wifi_cells = Cell.all(net)
                except InterfaceError:
                    # Not a Wifi interface
                    pass
                except Exception as e:
                    # Other error
                    logger.debug("WIFI plugin: Can not grab cellule stats ({})".format(e))
                    pass
                else:
                    for wifi_cell in wifi_cells:
                        hotspot = {
                            'key': self.get_key(),
                            'ssid': wifi_cell.ssid,
                            'signal': wifi_cell.signal,
                            'quality': wifi_cell.quality,
                            'encrypted': wifi_cell.encrypted,
                            'encryption_type': wifi_cell.encryption_type if wifi_cell.encrypted else None
                        }
                        # Add the hotspot to the list
                        self.stats.append(hotspot)

        elif self.input_method == 'snmp':
            # Update stats using SNMP

            # Not implemented yet
            pass

        return self.stats

    def get_alert(self, value):
        """Overwrite the default get_alert method.
        Alert is on signal quality where lower is better...

        :returns: string -- Signal alert
        """

        ret = 'OK'
        try:
            if value <= self.get_limit('critical', stat_name=self.plugin_name):
                ret = 'CRITICAL'
            elif value <= self.get_limit('warning', stat_name=self.plugin_name):
                ret = 'WARNING'
            elif value <= self.get_limit('careful', stat_name=self.plugin_name):
                ret = 'CAREFUL'
        except KeyError:
            ret = 'DEFAULT'

        return ret

    def update_views(self):
        """Update stats views."""
        # Call the father's method
        super(Plugin, self).update_views()

        # Add specifics informations
        # Alert on signal thresholds
        for i in self.stats:
            self.views[i[self.get_key()]]['signal']['decoration'] = self.get_alert(i['signal'])
            self.views[i[self.get_key()]]['quality']['decoration'] = self.views[i[self.get_key()]]['signal']['decoration']

    def msg_curse(self, args=None, max_width=None):
        """Return the dict to display in the curse interface."""
        # Init the return message
        ret = []

        # Only process if stats exist and display plugin enable...
        if not self.stats or args.disable_wifi or not wifi_tag:
            return ret

        # Max size for the interface name
        if max_width is not None and max_width >= 23:
            # Interface size name = max_width - space for encyption + quality
            ifname_max_width = max_width - 5
        else:
            ifname_max_width = 16

        # Build the string message
        # Header
        msg = '{:{width}}'.format('WIFI', width=ifname_max_width)
        ret.append(self.curse_add_line(msg, "TITLE"))
        msg = '{:>7}'.format('dBm')
        ret.append(self.curse_add_line(msg))

        # Hotspot list (sorted by name)
        for i in sorted(self.stats, key=operator.itemgetter(self.get_key())):
            # Do not display hotspot with no name (/ssid)
            if i['ssid'] == '':
                continue
            ret.append(self.curse_new_line())
            # New hotspot
            hotspotname = i['ssid']
            # Add the encryption type (if it is available)
            if i['encrypted']:
                hotspotname += ' {}'.format(i['encryption_type'])
            # Cut hotspotname if it is too long
            if len(hotspotname) > ifname_max_width:
                hotspotname = '_' + hotspotname[-ifname_max_width + 1:]
            # Add the new hotspot to the message
            msg = '{:{width}}'.format(hotspotname, width=ifname_max_width)
            ret.append(self.curse_add_line(msg))
            msg = '{:>7}'.format(i['signal'], width=ifname_max_width)
            ret.append(self.curse_add_line(msg,
                                           self.get_views(item=i[self.get_key()],
                                                          key='signal',
                                                          option='decoration')))

        return ret
        ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_raid.pyc                            0000664 0000000 0000000 00000010422 13070471670 023274  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   s�   d  Z  d d l m Z d d l m Z d d l m Z y d d l m Z Wn e	 k
 rj e j
 d � n Xd e f d �  �  YZ d	 S(
   s   RAID plugin.i����(   t   iterkeys(   t   logger(   t
 d �  Z RS(   sK   Glances RAID plugin.

    stats is a dict (see pymdstat documentation)
    c         C   s0   t  t |  � j d | � t |  _ |  j �  d S(   s   Init the plugin.t   argsN(   t   superR   t   __init__t   Truet
   2   s    c         C   s�   |  j  �  |  j d k rg y  t �  } | j �  d |  _ Wqy t k
 rc } t j d | � |  j SXn |  j d k ry n  |  j S(   s)   Update RAID stats using the input method.t   localt   arrayss   Can not grab RAID stats (%s)t   snmp(   R
   t   input_methodR   t	   get_statsR   t	   ExceptionR   t   debug(   R   t   mdst   e(    (    sF   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_raid.pyt   update6   s    
	c         C   s�  g  } |  j  s | Sd j d � } | j |  j | d � � d j d � } | j |  j | � � d j d � } | j |  j | � � t t |  j  � � } x'| D]} | j |  j �  � |  j |  j  | d |  j  | d |  j  | d	 � } |  j  | d
 d k	 r|  j  | d
 j	 �  n d } d j | | � } | j |  j | � � |  j  | d d
 | � D]� \ }	 }
 |	 t | � d k r~d } n d } | j |  j �  � d j | |  j  | d |
 � } | j |  j | � � d j |
 � } | j |  j | � � qSWn  |  j  | d |  j  | d	 k  r� | j |  j �  � d } | j |  j | | � � t |  j  | d � d k  r�| j |  j �  � d j |  j  | d j d d � � } | j |  j | � � q�q� q� W| S(   s2   Return the dict to display in the curse interface.s   {:11}s
   RAID diskst   TITLEs   {:>6}t   Usedt   Availt   statust   usedt	   availablet   typet   UNKNOWNs
   {:<5}{:>6}t   activet   inactives   └─ Status {}t
   componentsi   s   └─s   ├─s      {} disk {}: s   {}s   └─ Degraded modet   configi   s      └─ {}t   _t   AN(
   raid_alertt   Nonet   uppert	   enumeratet   lent   replace(   R   R   t   rett   msgR   t   arrayR   t
   array_typeR!   t   it	   componentt	   tree_char(    (    sF   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_raid.pyt	   msg_curseM   sX    	

        [available/used] means that ideally the array may have _available_
        devices however, _used_ devices are in use.
        Obviously when used >= available then things are good.
        R    t   CRITICALt   DEFAULTt   WARNINGt   OKN(   R+   (   R   R   R   R   (    (    sF   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_raid.pyR*   �   s    N(   t   __name__t
   __module__t   __doc__R+   R   R
   R   t   _check_decoratort   _log_result_decoratorR   R7   R*   (    (    (    sF   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_raid.pyR   !   s   
	<N(   R>   t   glances.compatR    t   glances.loggerR   t   glances.plugins.glances_pluginR   t   pymdstatR   t   ImportErrorR   R   (    (    (    sF   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_raid.pyt   <module>   s   
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

from datetime import datetime

from glances.plugins.glances_plugin import GlancesPlugin


class Plugin(GlancesPlugin):

    """Plugin to get the current date/time.

    stats is (string)
    """

    def __init__(self, args=None):
        """Init the plugin."""
        super(Plugin, self).__init__(args=args)

        # We want to display the stat in the curse interface
        self.display_curse = True

        # Set the message position
        self.align = 'bottom'

    def reset(self):
        """Reset/init the stats."""
        self.stats = ''

    def update(self):
        """Update current date/time."""
        # Had to convert it to string because datetime is not JSON serializable
        self.stats = datetime.now().strftime('%Y-%m-%d %H:%M:%S')

        return self.stats

    def msg_curse(self, args=None):
        """Return the string to display in the curse interface."""
        # Init the return message
        ret = []

        # Build the string message
        # 23 is the padding for the process list
        msg = '{:23}'.format(self.stats)
        ret.append(self.curse_add_line(msg))

        return ret
                                                                                                                                                       ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_uptime.py                           0000664 0000000 0000000 00000005341 13066703446 023525  0                                                                                                    ustar                                                                                                                                                                                                                                                          # -*- coding: utf-8 -*-
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""Uptime plugin."""

from datetime import datetime, timedelta

from glances.plugins.glances_plugin import GlancesPlugin

import psutil

# SNMP OID
snmp_oid = {'_uptime': '1.3.6.1.2.1.1.3.0'}


class Plugin(GlancesPlugin):

    """Glances uptime plugin.

    stats is date (string)
    """

    def __init__(self, args=None):
        """Init the plugin."""
        super(Plugin, self).__init__(args=args)

        # We want to display the stat in the curse interface
        self.display_curse = True

        # Set the message position
        self.align = 'right'

        # Init the stats
        self.uptime = datetime.now() - datetime.fromtimestamp(psutil.boot_time())
        self.reset()

    def reset(self):
        """Reset/init the stats."""
        self.stats = {}

    def get_export(self):
        """Overwrite the default export method.

        Export uptime in seconds.
        """
        return {'seconds': self.uptime.seconds}

    @GlancesPlugin._check_decorator
    @GlancesPlugin._log_result_decorator
    def update(self):
        """Update uptime stat using the input method."""
        # Reset stats
        self.reset()

        if self.input_method == 'local':
            # Update stats using the standard system lib
            self.uptime = datetime.now() - datetime.fromtimestamp(psutil.boot_time())

            # Convert uptime to string (because datetime is not JSONifi)
            self.stats = str(self.uptime).split('.')[0]
        elif self.input_method == 'snmp':
            # Update stats using SNMP
            uptime = self.get_stats_snmp(snmp_oid=snmp_oid)['_uptime']
            try:
                # In hundredths of seconds
                self.stats = str(timedelta(seconds=int(uptime) / 100))
            except Exception:
                pass

        # Return the result
        return self.stats

    def msg_curse(self, args=None):
        """Return the string to display in the curse interface."""
        return [self.curse_add_line('Uptime: {}'.format(self.stats))]
                                                                                                                                                                                                                                                                                               ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_now.pyc                             0000664 0000000 0000000 00000003361 13070471670 023164  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   s:   d  d l  m  Z  d  d l m Z d e f d �  �  YZ d S(   i����(   t   datetime(   t

    stats is (string)
    c         C   s/   t  t |  � j d | � t |  _ d |  _ d S(   s   Init the plugin.t   argst   bottomN(   t   superR   t   __init__t   Truet
   (    (    sE   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_now.pyt   reset*   s    c         C   s   t  j �  j d � |  _ |  j S(   s   Update current date/time.s   %Y-%m-%d %H:%M:%S(   R    t   nowt   strftimeR   (   R
   (    (    sE   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_now.pyt   update.   s    c         C   s2   g  } d j  |  j � } | j |  j | � � | S(   s4   Return the string to display in the curse interface.s   {:23}(   t   formatR   t   appendt   curse_add_line(   R
   R   t   rett   msg(    (    sE   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_now.pyt	   msg_curse5   s    N(   t   __name__t
   __module__t   __doc__t   NoneR   R
   
		N(   R    t   glances.plugins.glances_pluginR   R   (    (    (    sE   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_now.pyt   <module>   s                                                                                                                                                                                                                                                                                  ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_cpu.pyc                             0000664 0000000 0000000 00000020177 13070471670 023154  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   s*  d  Z  d d l m Z d d l m Z d d l m Z d d l m Z d d l	 m
 Z d d l m
 6d d 6d
 d 6d d 6d d 6d d 6i d d 6d  d 6d! d 6d d 6g Z d" e
 d S($   s   CPU plugin.i����(   t   getTimeSinceLastUpdate(   t   iterkeys(   t   cpu_percent(   t   LINUX(   t   Plugin(   t
 d �  Z d �  Z d d � Z

    'stats' is a dictionary that contains the system-wide CPU utilization as a
    percentage.
    c         C   sv   t  t |  � j d | d t � t |  _ |  j �  y# t d |  j � j	 �  d |  _
 Wn t k
 rq d |  _
 n Xd S(   s   Init the CPU plugin.t   argst   items_history_listt   logi   N(   t   superR   t   __init__R   t   Truet
   CorePluginR   t   updateR
#

   C   sC  t  j �  |  j d <t j d d � } xT d d d d d d	 d
 d d d
 D]. } t | | � rJ t | | � |  j | <qJ qJ Wy t j �  } Wn t k
 r� n� Xt	 d � } t |  d � s� | |  _
 nx xO | j D]D } t | | � d k	 r� t | | � t |  j
 | � |  j | <q� q� W| |  j d <|  j
 d S(   s   Update CPU stats using PSUtil.t   totalt   intervalg        R   R   R   t   nicet   iowaitt   irqt   softirqt   stealt   guestt
   guest_nicet   cput
 rO |  j �  n Xd |  j d <d |  j d <xP | D]H } | j d � rq |  j d c t | d	 � 7<|  j d c d
 7<qq qq W|  j d d k r� |  j d |  j d |  j d <n  d |  j d |  j d <d |  j d |  j d <n� y  |  j d t |  j  � |  _ Wn* t k
 rq|  j d t d
   s	   percent.3i   id   R&   R	   t    N(   R   R   (
   t   short_system_namet   get_stats_snmpR=   R   t   KeyErrorR   R    t
   startswitht   floatR   (   R   R8   t   ct   key(    (    sE   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_cpu.pyR%   �   s:    
c         C   sd  t  t |  � j �  xP d d d g D]? } | |  j k r# |  j |  j | d | �|  j | d <q# q# WxM d d g D]? } | |  j k rs |  j |  j | d | �|  j | d <qs qs Wx[ d g D]P } | |  j k r� |  j |  j | d	 d
 |  j d d | �|  j | d <q� q� WxI d d
   decorationR,   R&   t   ctx_switchest   maximumid   R2   R(   R*   t
   interruptst   soft_interruptst   syscallst   optionalN(   R   R   t   update_viewsR    t
   C   s+  g  } |  j  s |  j �  r  | Sd |  j  k } d j d � } | j |  j | d � � d j |  j  d � } | r� | j |  j | |  j d d d d	 � � � n | j |  j | � � d
 |  j  k rJd j d � } | j |  j | d
 d d
 � } | j |  j | d
 d d
   is_disablet   formatt   appendt   curse_add_linet	   get_viewst   intt   curse_new_lineR   (   R   R   t   rett   idle_tagt   msg(    (    sE   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_cpu.pyt	   msg_curse�   s�    ".1.'".1.'1"..'1..'1N(   t   __name__t
   __module__t   __doc__R;   R   R   R   t   _check_decoratort   _log_result_decoratorR   R$   R%   RO   R`   (    (    (    sE   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_cpu.pyR   ;   s   		/	,	(   Rc   t



&��Xc           @   s�   d  Z  d d l m Z d d l m Z d d l m Z d d l Z e Z	 y d d l
 m
 Z
 Wn e k
 ro n Xe Z	 d e f d �  �  YZ
 d	 d d � Z d �  Z d �  Z
   s<   Glances quicklook plugin.

    'stats' is a dictionary.
    c         C   s0   t  t |  � j d | � t |  _ |  j �  d S(   s   Init the quicklook plugin.t   argsN(   t   superR   t   __init__t   Truet
   8   s    c         C   s�   |  j  �  |  j d k rt t j �  |  j d <t j d t � |  j d <t j �  j |  j d <t j	 �  j |  j d <n |  j d k r� n  t
 r� t j �  } | d k	 r� | d |  j d <| d	 d
 |  j d <| d d
 |  j d
   t   input_methodR    t   getR   R   t   psutilt   virtual_memoryt   percentt   swap_memoryt   cpuinfo_tagR   t   get_cpu_infot   None(   R   t   cpu_info(    (    sK   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_quicklook.pyt   update<   s    
c         C   sj   t  t |  � j �  xP d d d g D]? } | |  j k r# |  j |  j | d | �|  j | d <q# q# Wd S(   s   Update stats views.R   R   R   t   headert
   decorationN(   R   R   t   update_viewsR   t	   get_alertt   views(   R   t   key(    (    sK   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_quicklook.pyR&   [   s    i
   c   
      C   s.  g  } |  j  s |  j �  r  | St | � } d |  j  k r d |  j  k r d |  j  k r d j |  j  d � } d j |  j |  j  d � |  j |  j  d � � } t | | � d | k r� | j |  j | � � n  | j |  j | � � | j |  j �  � n  xd d d	 g D]} | d k r�| j	 r�x� |  j  d
 D]� } | d | _
 | | d d
 d j | j �  � }	 | j |  j
   s   {:3}{} t
   cpu_numbers   {:4} (   R   t
   is_disableR   t   formatt
   _hz_to_ghzt   lent   appendt   curse_add_linet   curse_new_lineR   R   t   uppert   extendt   _msg_create_linet   pop(
   R   R   t	   max_widtht   rett   bart   msg_namet   msg_freqR)   R   t   msg(    (    sK   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_quicklook.pyt	   msg_cursef   s6    -
c         C   s�   g  } | j  |  j | � � | j  |  j | j d d �� | j  |  j t | � |  j d | d d � � � | j  |  j | j d d �� | j  |  j d � � | S(   s"   Create a new line to the QuickviewR%   t   BOLDR)   t   options     (   R0   R1   t   pre_chart   strt	   get_viewst	   post_char(   R   R<   R9   R)   R8   (    (    sK   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_quicklook.pyR5   �   s    1c         C   s   | d S(   s   Convert Hz to Ghzg    e��A(    (   R   t   hz(    (    sK   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_quicklook.pyR.   �   s    N(   t   __name__t
   __module__t   __doc__R!   R   R
   R   t   _check_decoratort   _log_result_decoratorR#   R&   R=   R5   R.   (    (    (    sK   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_quicklook.pyR   '   s   
		+	(   RG   t   glances.cpu_percentR    t   glances.outputs.glances_barsR   t   glances.plugins.glances_pluginR   R   t   FalseR   R   t   ImportErrorR   R   (    (    (    sK   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_quicklook.pyt   <module>   s   
&��Xc           @   s�   d  Z  d d l Z d d l m Z d d l m Z d d l Z i d d 6d d 6d	 d
 6d d 6i d
 6d d 6g Z d e f d �  �  YZ d S(   s   Disk I/O plugin.i����N(   t   getTimeSinceLastUpdate(   t
   read_bytest   names   Bytes read per secondt   descriptions   #00FF00t   colors   B/st   y_unitt   write_bytess   Bytes write per seconds   #FF0000t   Pluginc           B   s\   e  Z d  Z d d � Z d �  Z d �  Z e j e j	 d �  � � Z
 d �  Z d d � Z RS(   s3   Glances disks I/O plugin.

    stats is a list
    c         C   s6   t  t |  � j d | d t � t |  _ |  j �  d S(   s   Init the plugin.t   argst   items_history_listN(   t   superR   t   __init__R
   t   Truet
      C   s  |  j  �  |  j d k r�y t j d t � } Wn t k
 rF |  j SXt |  d � s� y
 f k
 r| q�Xq	t d � } | } xV| D]N} |  j d k	 r� |  j j r� | j d � r� q� n  |  j | � r� q� n  y� | | j |  j | j } | | j |  j | j } | | j |  j | j } | | j |  j | j } i | d 6| d 6| d 6| d	 6| d
 6| d 6}	 |  j | � d k	 r�|  j | � |	 d <n  Wn t k
 r�q� q� X|  j �  |	 d
   diskio_oldt   diskt   ramt   time_since_updateR   t
   read_countt   write_countR   R   t   aliast   keyt   snmpN(   R   t   input_methodt   psutilt   disk_io_countersR
   startswitht   is_hideR   R   R   R   t	   has_aliast   KeyErrorR   t   append(
   R   t   diskiocountersR   t
   diskio_newR   R   R   R   R   t   diskstat(    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_diskio.pyt   updateD   sX    
	





   s   Update stats views.R   R   R   t   headert   _rxt
   decorationR   t   _txN(   R   R   t   update_viewsR   t	   get_alertt   intt   viewsR   (   R   t   it   disk_real_name(    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_diskio.pyR5   �   s    
&c   	      C   s`  g  } |  j  s |  j �  r  | Sd j d � } | j |  j | d � � | j r� d j d � } | j |  j | � � d j d � } | j |  j | � � nJ d j d � } | j |  j | � � d j d � } | j |  j | � � xqt |  j  d	 t j |  j	 �  � �D]K} | d
 } |  j
 | d
 � } | d k rE| } n  | j |  j �  � t
   is_disablet   formatR,   t   curse_add_linet   diskio_iopst   sortedt   operatort
   itemgetterR   R*   R&   t   curse_new_linet   lent	   auto_unitR7   t	   get_views(	   R   R	   t   rett   msgR9   R:   R   t   txpst   rxps(    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_diskio.pyt	   msg_curse�   sl    	+
		
   __module__t   __doc__R&   R   R   R   R   t   _check_decoratort   _log_result_decoratorR0   R5   RN   (    (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_diskio.pyR   +   s   
		N	(	   RQ   RD   t
   R   (    (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_diskio.pyt   <module>   s   


#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""IP plugin."""

import threading
from json import loads

from glances.compat import iterkeys, urlopen, queue
from glances.globals import BSD
from glances.logger import logger
from glances.timer import Timer
from glances.plugins.glances_plugin import GlancesPlugin

# XXX *BSDs: Segmentation fault (core dumped)
# -- https://bitbucket.org/al45tair/netifaces/issues/15
# Also used in the ports_list script
if not BSD:
    try:
        import netifaces
        netifaces_tag = True
    except ImportError:
        netifaces_tag = False
else:
    netifaces_tag = False

# List of online services to retreive public IP address
# List of tuple (url, json, key)
# - url: URL of the Web site
# - json: service return a JSON (True) or string (False)
# - key: key of the IP addresse in the JSON structure
urls = [('http://ip.42.pl/raw', False, None),
        ('http://httpbin.org/ip', True, 'origin'),
        ('http://jsonip.com', True, 'ip'),
        ('https://api.ipify.org/?format=json', True, 'ip')]


class Plugin(GlancesPlugin):

    """Glances IP Plugin.

    stats is a dict
    """

    def __init__(self, args=None):
        """Init the plugin."""
        super(Plugin, self).__init__(args=args)

        # We want to display the stat in the curse interface
        self.display_curse = True

        # Get the public IP address once
        self.public_address = PublicIpAddress().get()

        # Init the stats
        self.reset()

    def reset(self):
        """Reset/init the stats."""
        self.stats = {}

    @GlancesPlugin._check_decorator
    @GlancesPlugin._log_result_decorator
    def update(self):
        """Update IP stats using the input method.

        Stats is dict
        """
        # Reset stats
        self.reset()

        if self.input_method == 'local' and netifaces_tag:
            # Update stats using the netifaces lib
            try:
                default_gw = netifaces.gateways()['default'][netifaces.AF_INET]
            except (KeyError, AttributeError) as e:
                logger.debug("Cannot grab the default gateway ({})".format(e))
            else:
                try:
                    self.stats['address'] = netifaces.ifaddresses(default_gw[1])[netifaces.AF_INET][0]['addr']
                    self.stats['mask'] = netifaces.ifaddresses(default_gw[1])[netifaces.AF_INET][0]['netmask']
                    self.stats['mask_cidr'] = self.ip_to_cidr(self.stats['mask'])
                    self.stats['gateway'] = netifaces.gateways()['default'][netifaces.AF_INET][0]
                    # !!! SHOULD be done once, not on each refresh
                    self.stats['public_address'] = self.public_address
                except (KeyError, AttributeError) as e:
                    logger.debug("Cannot grab IP information: {}".format(e))
        elif self.input_method == 'snmp':
            # Not implemented yet
            pass

        return self.stats

    def update_views(self):
        """Update stats views."""
        # Call the father's method
        super(Plugin, self).update_views()

        # Add specifics informations
        # Optional
        for key in iterkeys(self.stats):
            self.views[key]['optional'] = True

    def msg_curse(self, args=None):
        """Return the dict to display in the curse interface."""
        # Init the return message
        ret = []

        # Only process if stats exist and display plugin enable...
        if not self.stats or self.is_disable():
            return ret

        # Build the string message
        msg = ' - '
        ret.append(self.curse_add_line(msg))
        msg = 'IP '
        ret.append(self.curse_add_line(msg, 'TITLE'))
        msg = '{}'.format(self.stats['address'])
        ret.append(self.curse_add_line(msg))
        if 'mask_cidr' in self.stats:
            # VPN with no internet access (issue #842)
            msg = '/{}'.format(self.stats['mask_cidr'])
            ret.append(self.curse_add_line(msg))
        try:
            msg_pub = '{}'.format(self.stats['public_address'])
        except UnicodeEncodeError:
            pass
        else:
            if self.stats['public_address'] is not None:
                msg = ' Pub '
                ret.append(self.curse_add_line(msg, 'TITLE'))
                ret.append(self.curse_add_line(msg_pub))

        return ret

    @staticmethod
    def ip_to_cidr(ip):
        """Convert IP address to CIDR.

        Example: '255.255.255.0' will return 24
        """
        return sum([int(x) << 8 for x in ip.split('.')]) // 8128


class PublicIpAddress(object):
    """Get public IP address from online services"""

    def __init__(self, timeout=2):
        self.timeout = timeout

    def get(self):
        """Get the first public IP address returned by one of the online services"""
        q = queue.Queue()

        for u, j, k in urls:
            t = threading.Thread(target=self._get_ip_public, args=(q, u, j, k))
            t.daemon = True
            t.start()

        timer = Timer(self.timeout)
        ip = None
        while not timer.finished() and ip is None:
            if q.qsize() > 0:
                ip = q.get()

        return ip

    def _get_ip_public(self, queue_target, url, json=False, key=None):
        """Request the url service and put the result in the queue_target"""
        try:
            response = urlopen(url, timeout=self.timeout).read().decode('utf-8')
        except Exception as e:
            logger.debug("IP plugin - Cannot open URL {} ({})".format(url, e))
            queue_target.put(None)
        else:
            # Request depend on service
            try:
                if not json:
                    queue_target.put(response)
                else:
                    queue_target.put(loads(response)[key])
            except ValueError:
                queue_target.put(None)
                                       ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_percpu.py                           0000664 0000000 0000000 00000007007 13066703446 023521  0                                                                                                    ustar                                                                                                                                                                                                                                                          # -*- coding: utf-8 -*-
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""Per-CPU plugin."""

from glances.cpu_percent import cpu_percent
from glances.plugins.glances_plugin import GlancesPlugin


class Plugin(GlancesPlugin):

    """Glances per-CPU plugin.

    'stats' is a list of dictionaries that contain the utilization percentages
    for each CPU.
    """

    def __init__(self, args=None):
        """Init the plugin."""
        super(Plugin, self).__init__(args=args)

        # We want to display the stat in the curse interface
        self.display_curse = True

        # Init stats
        self.reset()

    def get_key(self):
        """Return the key of the list."""
        return 'cpu_number'

    def reset(self):
        """Reset/init the stats."""
        self.stats = []

    @GlancesPlugin._check_decorator
    @GlancesPlugin._log_result_decorator
    def update(self):
        """Update per-CPU stats using the input method."""
        # Reset stats
        self.reset()

        # Grab per-CPU stats using psutil's cpu_percent(percpu=True) and
        # cpu_times_percent(percpu=True) methods
        if self.input_method == 'local':
            self.stats = cpu_percent.get(percpu=True)
        else:
            # Update stats using SNMP
            pass

        return self.stats

    def msg_curse(self, args=None):
        """Return the dict to display in the curse interface."""
        # Init the return message
        ret = []

        # No per CPU stat ? Exit...
        if not self.stats:
            msg = 'PER CPU not available'
            ret.append(self.curse_add_line(msg, "TITLE"))
            return ret

        # Build the string message
        # Header
        msg = '{:8}'.format('PER CPU')
        ret.append(self.curse_add_line(msg, "TITLE"))

        # Total per-CPU usage
        for cpu in self.stats:
            try:
                msg = '{:6.1f}%'.format(cpu['total'])
            except TypeError:
                # TypeError: string indices must be integers (issue #1027)
                msg = '{:>6}%'.format('?')
            ret.append(self.curse_add_line(msg))

        # Stats per-CPU
        for stat in ['user', 'system', 'idle', 'iowait', 'steal']:
            if stat not in self.stats[0]:
                continue

            ret.append(self.curse_new_line())
            msg = '{:8}'.format(stat + ':')
            ret.append(self.curse_add_line(msg))
            for cpu in self.stats:
                try:
                    msg = '{:6.1f}%'.format(cpu[stat])
                except TypeError:
                    # TypeError: string indices must be integers (issue #1027)
                    msg = '{:>6}%'.format('?')
                ret.append(self.curse_add_line(msg,
                                               self.get_alert(cpu[stat], header=stat)))

        # Return the message with decoration
        return ret
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_core.pyc                            0000664 0000000 0000000 00000003326 13070471670 023312  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   s<   d  Z  d d l m Z d d l Z d e f d �  �  YZ d S(   s   CPU core plugin.i����(   t

    Get stats about CPU core number.

    stats is integer (number of core)
    c         C   s0   t  t |  � j d | � t |  _ |  j �  d S(   s   Init the plugin.t   argsN(   t   superR   t   __init__t   Falset
 rf |  j  �  q| Xn |  j d k r| n  |  j S(   sr   Update core stats.

        Stats is a dict (with both physical and log cpu number) instead of a integer.
        t   localt   logicalt   physt   logt   snmp(   R   t   input_methodt   psutilt	   cpu_countR   R	   t	   NameError(   R   (    (    sF   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_core.pyt   update3   s    

   __module__t   __doc__t   NoneR   R   R   (    (    (    sF   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_core.pyR      s   	(   R   t   glances.plugins.glances_pluginR    R   R   (    (    (    sF   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_core.pyt   <module>   s                                                                                                                                                                                                                                                                                                             ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_cloud.pyc                           0000664 0000000 0000000 00000013054 13070471670 023467  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   s�   d  Z  y d d l Z Wn e k
 r/ e Z n Xe Z d d l Z d d l m Z m	 Z	 d d l
 m Z d d l m
   sV   Cloud plugin.

Supported Cloud API:
- AWS EC2 (class ThreadAwsEc2Grabber, see bellow)
i����N(   t	   iteritemst   to_ascii(   t
 d d � Z RS(   s�   Glances' cloud plugin.

    The goal of this plugin is to retreive additional information
    concerning the datacenter where the host is connected.

    See https://github.com/nicolargo/glances/issues/1029

    stats is a dict
    c         C   sI   t  t |  � j d | � t |  _ |  j �  t �  |  _ |  j j �  d S(   s   Init the plugin.t   argsN(	   t   superR   t   __init__t   Truet
    	
c         C   s
   D   s    c         C   s$   |  j  j �  t t |  � j �  d S(   s*   Overwrite the exit method to close threadsN(   R   t   stopR   R   t   exit(   R   (    (    sG   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_cloud.pyR   H   s    

        Return the stats (dict)
        t   local(   R
   t	   cloud_tagR   t   input_methodR   (   R   (    (    sG   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_cloud.pyt   updateN   s    
c         C   s�   g  } |  j  s+ |  j  i  k s+ |  j �  r/ | Sd |  j  k r� d |  j  k r� d } | j |  j | d � � d j t |  j  d � t |  j  d � t |  j  d � � } | j |  j | � � n  t j | � | S(   s4   Return the string to display in the curse interface.s   ami-idt   regions   AWS EC2t   TITLEs    {} instance {} ({})s
   is_disablet   appendt   curse_add_linet   formatR   R   t   info(   R   R   t   rett   msg(    (    sG   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_cloud.pyt	   msg_cursef   s    %
   __module__t   __doc__t   NoneR   R
   R   R   t   _check_decoratort   _log_result_decoratorR   R   (    (    (    sG   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_cloud.pyR   (   s   
		R   c           B   s~   e  Z d  Z d Z i d d 6d d 6d d 6d d 6Z d �  Z d �  Z e d	 �  � Z e j	 d
 �  � Z d
    Specific thread to grab AWS EC2 stats.

    stats is a dict
    s'   http://169.254.169.254/latest/meta-datas   ami-ids   instance-ids
 | d d �} Wn- t k
 r� } t j d j | | � � Pq1 X| j r1 | j
        Infinite loop, should be stopped by calling the stop() methods,   cloud plugin - Requests lib is not installeds   {}/{}t   timeouti   s7   cloud plugin - Cannot connect to the AWS EC2 API {}: {}(   R   R   R&   R   t   FalseR    t   AWS_EC2_API_METADATAR   t   AWS_EC2_API_URLt   requestst   gett	   Exceptiont   okt   contentR*   R   (   R   t   kt   vt   r_urlt   rt   e(    (    sG   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_cloud.pyt   run�   s    
	c         C   s   |  j  S(   s   Stats getter(   R*   (   R   (    (    sG   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_cloud.pyR   �   s    c         C   s

			(   R"   R/   t   ImportErrorR,   R   R   R'   t   glances.compatR    R   t   glances.plugins.glances_pluginR   t   glances.loggerR   R   t   ThreadR   (    (    (    sG   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_cloud.pyt   <module>   s   
T                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_mem.py                              0000664 0000000 0000000 00000025647 13066703446 023013  0                                                                                                    ustar                                                                                                                                                                                                                                                          # -*- coding: utf-8 -*-
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""Virtual memory plugin."""

from glances.compat import iterkeys
from glances.plugins.glances_plugin import GlancesPlugin

import psutil

# SNMP OID
# Total RAM in machine: .1.3.6.1.4.1.2021.4.5.0
# Total RAM used: .1.3.6.1.4.1.2021.4.6.0
# Total RAM Free: .1.3.6.1.4.1.2021.4.11.0
# Total RAM Shared: .1.3.6.1.4.1.2021.4.13.0
# Total RAM Buffered: .1.3.6.1.4.1.2021.4.14.0
# Total Cached Memory: .1.3.6.1.4.1.2021.4.15.0
# Note: For Windows, stats are in the FS table
snmp_oid = {'default': {'total': '1.3.6.1.4.1.2021.4.5.0',
                        'free': '1.3.6.1.4.1.2021.4.11.0',
                        'shared': '1.3.6.1.4.1.2021.4.13.0',
                        'buffers': '1.3.6.1.4.1.2021.4.14.0',
                        'cached': '1.3.6.1.4.1.2021.4.15.0'},
            'windows': {'mnt_point': '1.3.6.1.2.1.25.2.3.1.3',
                        'alloc_unit': '1.3.6.1.2.1.25.2.3.1.4',
                        'size': '1.3.6.1.2.1.25.2.3.1.5',
                        'used': '1.3.6.1.2.1.25.2.3.1.6'},
            'esxi': {'mnt_point': '1.3.6.1.2.1.25.2.3.1.3',
                     'alloc_unit': '1.3.6.1.2.1.25.2.3.1.4',
                     'size': '1.3.6.1.2.1.25.2.3.1.5',
                     'used': '1.3.6.1.2.1.25.2.3.1.6'}}

# Define the history items list
# All items in this list will be historised if the --enable-history tag is set
# 'color' define the graph color in #RGB format
items_history_list = [{'name': 'percent',
                       'description': 'RAM memory usage',
                       'color': '#00FF00',
                       'y_unit': '%'}]


class Plugin(GlancesPlugin):

    """Glances' memory plugin.

    stats is a dict
    """

    def __init__(self, args=None):
        """Init the plugin."""
        super(Plugin, self).__init__(args=args, items_history_list=items_history_list)

        # We want to display the stat in the curse interface
        self.display_curse = True

        # Init the stats
        self.reset()

    def reset(self):
        """Reset/init the stats."""
        self.stats = {}

    @GlancesPlugin._check_decorator
    @GlancesPlugin._log_result_decorator
    def update(self):
        """Update RAM memory stats using the input method."""
        # Reset stats
        self.reset()

        if self.input_method == 'local':
            # Update stats using the standard system lib
            # Grab MEM using the PSUtil virtual_memory method
            vm_stats = psutil.virtual_memory()

            # Get all the memory stats (copy/paste of the PsUtil documentation)
            # total: total physical memory available.
            # available: the actual amount of available memory that can be given instantly to processes that request more memory in bytes; this is calculated by summing different memory values depending on the platform (e.g. free + buffers + cached on Linux) and it is supposed to be used to monitor actual memory usage in a cross platform fashion.
            # percent: the percentage usage calculated as (total - available) / total * 100.
            # used: memory used, calculated differently depending on the platform and designed for informational purposes only.
            # free: memory not being used at all (zeroed) that is readily available; note that this doesn’t reflect the actual memory available (use ‘available’ instead).
            # Platform-specific fields:
            # active: (UNIX): memory currently in use or very recently used, and so it is in RAM.
            # inactive: (UNIX): memory that is marked as not used.
            # buffers: (Linux, BSD): cache for things like file system metadata.
            # cached: (Linux, BSD): cache for various things.
            # wired: (BSD, macOS): memory that is marked to always stay in RAM. It is never moved to disk.
            # shared: (BSD): memory that may be simultaneously accessed by multiple processes.
            self.reset()
            for mem in ['total', 'available', 'percent', 'used', 'free',
                        'active', 'inactive', 'buffers', 'cached',
                        'wired', 'shared']:
                if hasattr(vm_stats, mem):
                    self.stats[mem] = getattr(vm_stats, mem)

            # Use the 'free'/htop calculation
            # free=available+buffer+cached
            self.stats['free'] = self.stats['available']
            if hasattr(self.stats, 'buffers'):
                self.stats['free'] += self.stats['buffers']
            if hasattr(self.stats, 'cached'):
                self.stats['free'] += self.stats['cached']
            # used=total-free
            self.stats['used'] = self.stats['total'] - self.stats['free']
        elif self.input_method == 'snmp':
            # Update stats using SNMP
            if self.short_system_name in ('windows', 'esxi'):
                # Mem stats for Windows|Vmware Esxi are stored in the FS table
                try:
                    fs_stat = self.get_stats_snmp(snmp_oid=snmp_oid[self.short_system_name],
                                                  bulk=True)
                except KeyError:
                    self.reset()
                else:
                    for fs in fs_stat:
                        # The Physical Memory (Windows) or Real Memory (VMware)
                        # gives statistics on RAM usage and availability.
                        if fs in ('Physical Memory', 'Real Memory'):
                            self.stats['total'] = int(fs_stat[fs]['size']) * int(fs_stat[fs]['alloc_unit'])
                            self.stats['used'] = int(fs_stat[fs]['used']) * int(fs_stat[fs]['alloc_unit'])
                            self.stats['percent'] = float(self.stats['used'] * 100 / self.stats['total'])
                            self.stats['free'] = self.stats['total'] - self.stats['used']
                            break
            else:
                # Default behavor for others OS
                self.stats = self.get_stats_snmp(snmp_oid=snmp_oid['default'])

                if self.stats['total'] == '':
                    self.reset()
                    return self.stats

                for key in iterkeys(self.stats):
                    if self.stats[key] != '':
                        self.stats[key] = float(self.stats[key]) * 1024

                # Use the 'free'/htop calculation
                self.stats['free'] = self.stats['free'] - self.stats['total'] + (self.stats['buffers'] + self.stats['cached'])

                # used=total-free
                self.stats['used'] = self.stats['total'] - self.stats['free']

                # percent: the percentage usage calculated as (total - available) / total * 100.
                self.stats['percent'] = float((self.stats['total'] - self.stats['free']) / self.stats['total'] * 100)

        return self.stats

    def update_views(self):
        """Update stats views."""
        # Call the father's method
        super(Plugin, self).update_views()

        # Add specifics informations
        # Alert and log
        self.views['used']['decoration'] = self.get_alert_log(self.stats['used'], maximum=self.stats['total'])
        # Optional
        for key in ['active', 'inactive', 'buffers', 'cached']:
            if key in self.stats:
                self.views[key]['optional'] = True

    def msg_curse(self, args=None):
        """Return the dict to display in the curse interface."""
        # Init the return message
        ret = []

        # Only process if stats exist and plugin not disabled
        if not self.stats or self.is_disable():
            return ret

        # Build the string message
        # Header
        msg = '{:5} '.format('MEM')
        ret.append(self.curse_add_line(msg, "TITLE"))
        # Percent memory usage
        msg = '{:>7.1%}'.format(self.stats['percent'] / 100)
        ret.append(self.curse_add_line(msg))
        # Active memory usage
        if 'active' in self.stats:
            msg = '  {:9}'.format('active:')
            ret.append(self.curse_add_line(msg, optional=self.get_views(key='active', option='optional')))
            msg = '{:>7}'.format(self.auto_unit(self.stats['active']))
            ret.append(self.curse_add_line(msg, optional=self.get_views(key='active', option='optional')))
        # New line
        ret.append(self.curse_new_line())
        # Total memory usage
        msg = '{:6}'.format('total:')
        ret.append(self.curse_add_line(msg))
        msg = '{:>7}'.format(self.auto_unit(self.stats['total']))
        ret.append(self.curse_add_line(msg))
        # Inactive memory usage
        if 'inactive' in self.stats:
            msg = '  {:9}'.format('inactive:')
            ret.append(self.curse_add_line(msg, optional=self.get_views(key='inactive', option='optional')))
            msg = '{:>7}'.format(self.auto_unit(self.stats['inactive']))
            ret.append(self.curse_add_line(msg, optional=self.get_views(key='inactive', option='optional')))
        # New line
        ret.append(self.curse_new_line())
        # Used memory usage
        msg = '{:6}'.format('used:')
        ret.append(self.curse_add_line(msg))
        msg = '{:>7}'.format(self.auto_unit(self.stats['used']))
        ret.append(self.curse_add_line(
            msg, self.get_views(key='used', option='decoration')))
        # Buffers memory usage
        if 'buffers' in self.stats:
            msg = '  {:9}'.format('buffers:')
            ret.append(self.curse_add_line(msg, optional=self.get_views(key='buffers', option='optional')))
            msg = '{:>7}'.format(self.auto_unit(self.stats['buffers']))
            ret.append(self.curse_add_line(msg, optional=self.get_views(key='buffers', option='optional')))
        # New line
        ret.append(self.curse_new_line())
        # Free memory usage
        msg = '{:6}'.format('free:')
        ret.append(self.curse_add_line(msg))
        msg = '{:>7}'.format(self.auto_unit(self.stats['free']))
        ret.append(self.curse_add_line(msg))
        # Cached memory usage
        if 'cached' in self.stats:
            msg = '  {:9}'.format('cached:')
            ret.append(self.curse_add_line(msg, optional=self.get_views(key='cached', option='optional')))
            msg = '{:>7}'.format(self.auto_unit(self.stats['cached']))
            ret.append(self.curse_add_line(msg, optional=self.get_views(key='cached', option='optional')))

        return ret
                                                                                         ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_gpu.pyc                             0000664 0000000 0000000 00000017344 13070471670 023162  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   s}   d  Z  d d l m Z d d l m Z y d d l Z Wn$ e k
 r\ e j d � e Z	 n Xe
 Z	 d e f d �  �  YZ d S(   s'   GPU plugin (limited to NVIDIA chipsets)i����(   t   logger(   t
 d �  � � Z d �  Z d d � Z
 �  Z d �  Z d �  Z d

    stats is a list of dictionaries with one entry per GPU
    c         C   s:   t  t |  � j d | � |  j �  t |  _ |  j �  d S(   s   Init the plugint   argsN(   t   superR   t   __init__t   init_nvidiat   Truet
	c         C   s
   (    (    sE   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_gpu.pyR	   6   s    c         C   si   t  s t |  _ n  y& t j �  |  j �  |  _ t |  _ Wn' t k
 ra t	 j
 d � t |  _ n X|  j S(   s   Init the NVIDIA APIs    pynvml could not be initialized.(   t   gpu_nvidia_tagt   Falset
   nvml_readyt   pynvmlt   nvmlInitt   get_device_handlest   device_handlesR   t	   ExceptionR    t   debug(   R
   (    (    sE   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_gpu.pyR   :   s    

   (    (    sE   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_gpu.pyt   get_keyI   s    c         C   sT   |  j  �  |  j s |  j S|  j d k r; |  j �  |  _ n |  j d k rM n  |  j S(   s   Update the GPU statst   localt   snmp(   R	   R   R   t   input_methodt   get_device_stats(   R
   (    (    sE   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_gpu.pyt   updateM   s    

   decoration(   R   R   t   update_viewsR   t   viewsR   t	   get_alertR   (   R
   t   it   alert(    (    sE   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_gpu.pyR    j   s    %"&c      
      s�  g  } �  j  s+ �  j  g  k s+ �  j �  r/ | St �  f d �  �  j  D� � } �  j  d } d } t �  j  � d k r� | d j t �  j  � � 7} n  | r� | d j d | d � 7} n | d	 j d � 7} | d
  } | j �  j | d � � t �  j  � d k s| j r�| j �  j �  � y* t	 d �  �  j  D� � t �  j  � } Wn  t
 k
 rkd
 k
 rad
 n Xd j |	 � }
 t �  j  � d k r�d j d � } n d j d � } | j �  j | � � | j �  j |
 �  j d | �  j �  d d d d � � � n� x� �  j  D]� } | j �  j �  � d	 j | d � } y d j | d � } Wn  t
 rjd
 r�d
   (    sE   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_gpu.pys	   <genexpr>�   s    i    t    i   s   {} s   {} {}t   GPUR%   s   {}i   t   TITLEc         s   s%   |  ] } | d k	 r | d  Vq d S(   R   N(   t   None(   R&   R'   (    (    sE   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_gpu.pys	   <genexpr>�   s    s   {:>4}s   N/As	   {:>3.0f}%s   {:13}s
   proc mean:s   proc:t   itemt   keyR   t   optionR   c         s   s%   |  ] } | d k	 r | d  Vq d S(   R   N(   R+   (   R&   R'   (    (    sE   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_gpu.pys	   <genexpr>�   s    s	   mem mean:s   mem:R   R   s   {}: {} mem: {}(   R   t
   is_disablet   allt   lent   formatt   appendt   curse_add_linet   meangput   curse_new_linet   sumt	   TypeErrort	   get_viewsR   t
   ValueError(   R
   R   t   rett	   same_namet	   gpu_statsR   t   msgt	   mean_proct
   sE   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_gpu.pyt	   msg_curse   sp    %
*
        Returns a list of NVML device handles, one per device.  Can throw NVMLError.
        (   t   rangeR   t   nvmlDeviceGetCountt   nvmlDeviceGetHandleByIndex(   R
   R#   (    (    sE   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_gpu.pyR   �   s    c         C   s�   g  } x� t  |  j � D]r \ } } i  } |  j �  | d <| | d <|  j | � | d <|  j | � | d <|  j | � | d <| j | � q W| S(   s
   R   t   indext
c         C   s-   y t  j | � SWn t  j k
 r( d SXd S(   s   Get GPU device namet   NVIDIAN(   R   t   nvmlDeviceGetNamet	   NVMlError(   R
   RO   (    (    sE   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_gpu.pyRK   �   s    c         C   sA   y% t  j | � } | j d | j SWn t  j k
 r< d SXd S(   s,   Get GPU device memory consumption in percentg      Y@N(   R   t   nvmlDeviceGetMemoryInfot   usedt   totalt	   NVMLErrorR+   (   R
   RO   t   memory_info(    (    sE   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_gpu.pyRL   �   s
    c         C   s0   y t  j | � j SWn t  j k
 r+ d SXd S(   s)   Get GPU device CPU consumption in percentN(   R   t   nvmlDeviceGetUtilizationRatest   gpuRW   R+   (   R
   RO   (    (    sE   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_gpu.pyRM   �   s    c         C   s]   |  j  rF y t j �  WqF t k
 rB } t j d j | � � qF Xn  t t |  � j	 �  d S(   s.   Overwrite the exit method to close the GPU APIs(   pynvml failed to shutdown correctly ({})N(
   R   R   t   nvmlShutdownR   R    R   R2   R   R   t   exit(   R
   t   e(    (    sE   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_gpu.pyR\     s    	N(   t   __name__t
   __module__t   __doc__R+   R   R	   R   R   R   t   _check_decoratort   _log_result_decoratorR   R    RF   R   R   RK   RL   RM   R\   (    (    (    sE   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_gpu.pyR   "   s   
                                                                                                                                                                                                                                                                                            ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_processcount.pyc                    0000664 0000000 0000000 00000006241 13070471670 025110  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   s@   d  Z  d d l m Z d d l m Z d e f d �  �  YZ d S(   s   Process count plugin.i����(   t   glances_processes(   t

    stats is a list
    c         C   s&   t  t |  � j d | � t |  _ d S(   s   Init the plugin.t   argsN(   t   superR   t   __init__t   Truet
   t   input_methodR    t   updatet   getcountR	   (   R   (    (    sN   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_processcount.pyR   1   s    

c         C   s�  g  } | j  r/ d } | j |  j | � � | S|  j s< | St j d k	 r� d } | j |  j | d � � d j t j � } t j d k	 r� | d j t j � 7} n  | j |  j | d � � d } | j |  j | � � | j |  j	 �  � n  d } | j |  j | d � � |  j d	 } d
 j |  j d	 � } | j |  j | � � d |  j k r�d j |  j d � } | j |  j | � � n  d
 r�d } | j |  j | � � d j t j � } | j |  j | � � n( d j t j � } | j |  j | � � | d d c d t j �  r�d n d 7<| S(   s2   Return the dict to display in the curse interface.s)   PROCESSES DISABLED (press 'z' to display)s   Processes filter:t   TITLEs    {} s
    ({} thr),t   runnings    {} run,t   sleepings    {} slp,s    {} oth s   sorted automaticallys    by {}s   sorted by {}i����t   msgs	   , %s viewt   treet   flatN(
   __module__t   __doc__R   R   R
   R   R'   (    (    (    sN   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_processcount.pyR      s
   			N(   R*   t   glances.processesR    t   glances.plugins.glances_pluginR   R   (    (    (    sN   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_processcount.pyt   <module>   s                                                                                                                                                                                                                                                                                                                                                                  ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_plugin.py                           0000664 0000000 0000000 00000072631 13066703446 023526  0                                                                                                    ustar                                                                                                                                                                                                                                                          # -*- coding: utf-8 -*-
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""
I am your father...

...for all Glances plugins.
"""

import re
import json
from operator import itemgetter

from glances.compat import iterkeys, itervalues, listkeys, map
from glances.actions import GlancesActions
from glances.history import GlancesHistory
from glances.logger import logger
from glances.logs import glances_logs


class GlancesPlugin(object):

    """Main class for Glances plugin."""

    def __init__(self, args=None, items_history_list=None):
        """Init the plugin of plugins class."""
        # Plugin name (= module name without glances_)
        self.plugin_name = self.__class__.__module__[len('glances_'):]
        # logger.debug("Init plugin %s" % self.plugin_name)

        # Init the args
        self.args = args

        # Init the default alignement (for curses)
        self._align = 'left'

        # Init the input method
        self._input_method = 'local'
        self._short_system_name = None

        # Init the stats list
        self.stats = None

        # Init the history list
        self.items_history_list = items_history_list
        self.stats_history = self.init_stats_history()

        # Init the limits dictionnary
        self._limits = dict()

        # Init the actions
        self.actions = GlancesActions(args=args)

        # Init the views
        self.views = dict()

    def exit(self):
        """Method to be called when Glances exit"""
        logger.debug("Stop the {} plugin".format(self.plugin_name))

    def __repr__(self):
        """Return the raw stats."""
        return self.stats

    def __str__(self):
        """Return the human-readable stats."""
        return str(self.stats)

    def get_key(self):
        """Return the key of the list."""
        return None

    def is_enable(self):
        """Return true if plugin is enabled"""
        try:
            d = getattr(self.args, 'disable_' + self.plugin_name)
        except AttributeError:
            return True
        else:
            return d is False

    def is_disable(self):
        """Return true if plugin is disabled"""
        return not self.is_enable()

    def _json_dumps(self, d):
        """Return the object 'd' in a JSON format
        Manage the issue #815 for Windows OS"""
        try:
            return json.dumps(d)
        except UnicodeDecodeError:
            return json.dumps(d, ensure_ascii=False)

    def _history_enable(self):
        return self.args is not None and not self.args.disable_history and self.get_items_history_list() is not None

    def init_stats_history(self):
        """Init the stats history (dict of GlancesAttribute)."""
        if self._history_enable():
            init_list = [a['name'] for a in self.get_items_history_list()]
            logger.debug("Stats history activated for plugin {} (items: {})".format(self.plugin_name, init_list))
        return GlancesHistory()

    def reset_stats_history(self):
        """Reset the stats history (dict of GlancesAttribute)."""
        if self._history_enable():
            reset_list = [a['name'] for a in self.get_items_history_list()]
            logger.debug("Reset history for plugin {} (items: {})".format(self.plugin_name, reset_list))
            self.stats_history.reset()

    def update_stats_history(self):
        """Update stats history."""
        # If the plugin data is a dict, the dict's key should be used
        if self.get_key() is None:
            item_name = ''
        else:
            item_name = self.get_key()
        # Build the history
        if self.stats and self._history_enable():
            for i in self.get_items_history_list():
                if isinstance(self.stats, list):
                    # Stats is a list of data
                    # Iter throught it (for exemple, iter throught network
                    # interface)
                    for l in self.stats:
                        self.stats_history.add(
                            l[item_name] + '_' + i['name'],
                            l[i['name']],
                            description=i['description'],
                            history_max_size=self._limits['history_size'])
                else:
                    # Stats is not a list
                    # Add the item to the history directly
                    self.stats_history.add(i['name'],
                                           self.stats[i['name']],
                                           description=i['description'],
                                           history_max_size=self._limits['history_size'])

    def get_items_history_list(self):
        """Return the items history list."""
        return self.items_history_list

    def get_raw_history(self, item=None):
        """Return
        - the stats history (dict of list) if item is None
        - the stats history for the given item (list) instead
        - None if item did not exist in the history"""
        s = self.stats_history.get()
        if item is None:
            return s
        else:
            if item in s:
                return s[item]
            else:
                return None

    def get_json_history(self, item=None, nb=0):
        """Return:
        - the stats history (dict of list) if item is None
        - the stats history for the given item (list) instead
        - None if item did not exist in the history
        Limit to lasts nb items (all if nb=0)"""
        s = self.stats_history.get_json(nb=nb)
        if item is None:
            return s
        else:
            if item in s:
                return s[item]
            else:
                return None

    def get_export_history(self, item=None):
        """Return the stats history object to export.
        See get_raw_history for a full description"""
        return self.get_raw_history(item=item)

    def get_stats_history(self, item=None, nb=0):
        """Return the stats history as a JSON object (dict or None).
        Limit to lasts nb items (all if nb=0)"""
        s = self.get_json_history(nb=nb)

        if item is None:
            return self._json_dumps(s)

        if isinstance(s, dict):
            try:
                return self._json_dumps({item: s[item]})
            except KeyError as e:
                logger.error("Cannot get item history {} ({})".format(item, e))
                return None
        elif isinstance(s, list):
            try:
                # Source:
                # http://stackoverflow.com/questions/4573875/python-get-index-of-dictionary-item-in-list
                return self._json_dumps({item: map(itemgetter(item), s)})
            except (KeyError, ValueError) as e:
                logger.error("Cannot get item history {} ({})".format(item, e))
                return None
        else:
            return None

    @property
    def input_method(self):
        """Get the input method."""
        return self._input_method

    @input_method.setter
    def input_method(self, input_method):
        """Set the input method.

        * local: system local grab (psutil or direct access)
        * snmp: Client server mode via SNMP
        * glances: Client server mode via Glances API
        """
        self._input_method = input_method

    @property
    def short_system_name(self):
        """Get the short detected OS name (SNMP)."""
        return self._short_system_name

    @short_system_name.setter
    def short_system_name(self, short_name):
        """Set the short detected OS name (SNMP)."""
        self._short_system_name = short_name

    def set_stats(self, input_stats):
        """Set the stats to input_stats."""
        self.stats = input_stats

    def get_stats_snmp(self, bulk=False, snmp_oid=None):
        """Update stats using SNMP.

        If bulk=True, use a bulk request instead of a get request.
        """
        snmp_oid = snmp_oid or {}

        from glances.snmp import GlancesSNMPClient

        # Init the SNMP request
        clientsnmp = GlancesSNMPClient(host=self.args.client,
                                       port=self.args.snmp_port,
                                       version=self.args.snmp_version,
                                       community=self.args.snmp_community)

        # Process the SNMP request
        ret = {}
        if bulk:
            # Bulk request
            snmpresult = clientsnmp.getbulk_by_oid(0, 10, itervalues(*snmp_oid))

            if len(snmp_oid) == 1:
                # Bulk command for only one OID
                # Note: key is the item indexed but the OID result
                for item in snmpresult:
                    if iterkeys(item)[0].startswith(itervalues(snmp_oid)[0]):
                        ret[iterkeys(snmp_oid)[0] + iterkeys(item)
                            [0].split(itervalues(snmp_oid)[0])[1]] = itervalues(item)[0]
            else:
                # Build the internal dict with the SNMP result
                # Note: key is the first item in the snmp_oid
                index = 1
                for item in snmpresult:
                    item_stats = {}
                    item_key = None
                    for key in iterkeys(snmp_oid):
                        oid = snmp_oid[key] + '.' + str(index)
                        if oid in item:
                            if item_key is None:
                                item_key = item[oid]
                            else:
                                item_stats[key] = item[oid]
                    if item_stats:
                        ret[item_key] = item_stats
                    index += 1
        else:
            # Simple get request
            snmpresult = clientsnmp.get_by_oid(itervalues(*snmp_oid))

            # Build the internal dict with the SNMP result
            for key in iterkeys(snmp_oid):
                ret[key] = snmpresult[snmp_oid[key]]

        return ret

    def get_raw(self):
        """Return the stats object."""
        return self.stats

    def get_export(self):
        """Return the stats object to export."""
        return self.get_raw()

    def get_stats(self):
        """Return the stats object in JSON format."""
        return self._json_dumps(self.stats)

    def get_stats_item(self, item):
        """Return the stats object for a specific item in JSON format.

        Stats should be a list of dict (processlist, network...)
        """
        if isinstance(self.stats, dict):
            try:
                return self._json_dumps({item: self.stats[item]})
            except KeyError as e:
                logger.error("Cannot get item {} ({})".format(item, e))
                return None
        elif isinstance(self.stats, list):
            try:
                # Source:
                # http://stackoverflow.com/questions/4573875/python-get-index-of-dictionary-item-in-list
                return self._json_dumps({item: map(itemgetter(item), self.stats)})
            except (KeyError, ValueError) as e:
                logger.error("Cannot get item {} ({})".format(item, e))
                return None
        else:
            return None

    def get_stats_value(self, item, value):
        """Return the stats object for a specific item=value in JSON format.

        Stats should be a list of dict (processlist, network...)
        """
        if not isinstance(self.stats, list):
            return None
        else:
            if value.isdigit():
                value = int(value)
            try:
                return self._json_dumps({value: [i for i in self.stats if i[item] == value]})
            except (KeyError, ValueError) as e:
                logger.error(
                    "Cannot get item({})=value({}) ({})".format(item, value, e))
                return None

    def update_views(self):
        """Default builder fo the stats views.

        The V of MVC
        A dict of dict with the needed information to display the stats.
        Example for the stat xxx:
        'xxx': {'decoration': 'DEFAULT',
                'optional': False,
                'additional': False,
                'splittable': False}
        """
        ret = {}

        if (isinstance(self.get_raw(), list) and
                self.get_raw() is not None and
                self.get_key() is not None):
            # Stats are stored in a list of dict (ex: NETWORK, FS...)
            for i in self.get_raw():
                ret[i[self.get_key()]] = {}
                for key in listkeys(i):
                    value = {'decoration': 'DEFAULT',
                             'optional': False,
                             'additional': False,
                             'splittable': False}
                    ret[i[self.get_key()]][key] = value
        elif isinstance(self.get_raw(), dict) and self.get_raw() is not None:
            # Stats are stored in a dict (ex: CPU, LOAD...)
            for key in listkeys(self.get_raw()):
                value = {'decoration': 'DEFAULT',
                         'optional': False,
                         'additional': False,
                         'splittable': False}
                ret[key] = value

        self.views = ret

        return self.views

    def set_views(self, input_views):
        """Set the views to input_views."""
        self.views = input_views

    def get_views(self, item=None, key=None, option=None):
        """Return the views object.

        If key is None, return all the view for the current plugin
        else if option is None return the view for the specific key (all option)
        else return the view fo the specific key/option

        Specify item if the stats are stored in a dict of dict (ex: NETWORK, FS...)
        """
        if item is None:
            item_views = self.views
        else:
            item_views = self.views[item]

        if key is None:
            return item_views
        else:
            if option is None:
                return item_views[key]
            else:
                if option in item_views[key]:
                    return item_views[key][option]
                else:
                    return 'DEFAULT'

    def load_limits(self, config):
        """Load limits from the configuration file, if it exists."""

        # By default set the history length to 3 points per second during one day
        self._limits['history_size'] = 28800

        if not hasattr(config, 'has_section'):
            return False

        # Read the global section
        if config.has_section('global'):
            self._limits['history_size'] = config.get_float_value('global', 'history_size', default=28800)
            logger.debug("Load configuration key: {} = {}".format('history_size', self._limits['history_size']))

        # Read the plugin specific section
        if config.has_section(self.plugin_name):
            for level, _ in config.items(self.plugin_name):
                # Read limits
                limit = '_'.join([self.plugin_name, level])
                try:
                    self._limits[limit] = config.get_float_value(self.plugin_name, level)
                except ValueError:
                    self._limits[limit] = config.get_value(self.plugin_name, level).split(",")
                logger.debug("Load limit: {} = {}".format(limit, self._limits[limit]))

        return True

    @property
    def limits(self):
        """Return the limits object."""
        return self._limits

    @limits.setter
    def limits(self, input_limits):
        """Set the limits to input_limits."""
        self._limits = input_limits

    def get_stats_action(self):
        """Return stats for the action
        By default return all the stats.
        Can be overwrite by plugins implementation.
        For example, Docker will return self.stats['containers']"""
        return self.stats

    def get_alert(self,
                  current=0,
                  minimum=0,
                  maximum=100,
                  highlight_zero=True,
                  is_max=False,
                  header="",
                  action_key=None,
                  log=False):
        """Return the alert status relative to a current value.

        Use this function for minor stats.

        If current < CAREFUL of max then alert = OK
        If current > CAREFUL of max then alert = CAREFUL
        If current > WARNING of max then alert = WARNING
        If current > CRITICAL of max then alert = CRITICAL

        If highlight=True than 0.0 is highlighted

        If defined 'header' is added between the plugin name and the status.
        Only useful for stats with several alert status.

        If defined, 'action_key' define the key for the actions.
        By default, the action_key is equal to the header.

        If log=True than add log if necessary
        elif log=False than do not log
        elif log=None than apply the config given in the conf file
        """
        # Manage 0 (0.0) value if highlight_zero is not True
        if not highlight_zero and current == 0:
            return 'DEFAULT'

        # Compute the %
        try:
            value = (current * 100) / maximum
        except ZeroDivisionError:
            return 'DEFAULT'
        except TypeError:
            return 'DEFAULT'

        # Build the stat_name = plugin_name + header
        if header == "":
            stat_name = self.plugin_name
        else:
            stat_name = self.plugin_name + '_' + header

        # Manage limits
        # If is_max is set then display the value in MAX
        ret = 'MAX' if is_max else 'OK'
        try:
            if value >= self.get_limit('critical', stat_name=stat_name):
                ret = 'CRITICAL'
            elif value >= self.get_limit('warning', stat_name=stat_name):
                ret = 'WARNING'
            elif value >= self.get_limit('careful', stat_name=stat_name):
                ret = 'CAREFUL'
            elif current < minimum:
                ret = 'CAREFUL'
        except KeyError:
            return 'DEFAULT'

        # Manage log
        log_str = ""
        if self.get_limit_log(stat_name=stat_name, default_action=log):
            # Add _LOG to the return string
            # So stats will be highlited with a specific color
            log_str = "_LOG"
            # Add the log to the list
            glances_logs.add(ret, stat_name.upper(), value)

        # Manage action
        self.manage_action(stat_name, ret.lower(), header, action_key)

        # Default is ok
        return ret + log_str

    def manage_action(self,
                      stat_name,
                      trigger,
                      header,
                      action_key):
        """Manage the action for the current stat"""
        # Here is a command line for the current trigger ?
        try:
            command = self.get_limit_action(trigger, stat_name=stat_name)
        except KeyError:
            # Reset the trigger
            self.actions.set(stat_name, trigger)
        else:
            # Define the action key for the stats dict
            # If not define, then it sets to header
            if action_key is None:
                action_key = header

            # A command line is available for the current alert
            # 1) Build the {{mustache}} dictionnary
            if isinstance(self.get_stats_action(), list):
                # If the stats are stored in a list of dict (fs plugin for exemple)
                # Return the dict for the current header
                mustache_dict = {}
                for item in self.get_stats_action():
                    if item[self.get_key()] == action_key:
                        mustache_dict = item
                        break
            else:
                # Use the stats dict
                mustache_dict = self.get_stats_action()
            # 2) Run the action
            self.actions.run(
                stat_name, trigger, command, mustache_dict=mustache_dict)

    def get_alert_log(self,
                      current=0,
                      minimum=0,
                      maximum=100,
                      header="",
                      action_key=None):
        """Get the alert log."""
        return self.get_alert(current=current,
                              minimum=minimum,
                              maximum=maximum,
                              header=header,
                              action_key=action_key,
                              log=True)

    def get_limit(self, criticity, stat_name=""):
        """Return the limit value for the alert."""
        # Get the limit for stat + header
        # Exemple: network_wlan0_rx_careful
        try:
            limit = self._limits[stat_name + '_' + criticity]
        except KeyError:
            # Try fallback to plugin default limit
            # Exemple: network_careful
            limit = self._limits[self.plugin_name + '_' + criticity]

        # logger.debug("{} {} value is {}".format(stat_name, criticity, limit))

        # Return the limit
        return limit

    def get_limit_action(self, criticity, stat_name=""):
        """Return the action for the alert."""
        # Get the action for stat + header
        # Exemple: network_wlan0_rx_careful_action
        try:
            ret = self._limits[stat_name + '_' + criticity + '_action']
        except KeyError:
            # Try fallback to plugin default limit
            # Exemple: network_careful_action
            ret = self._limits[self.plugin_name + '_' + criticity + '_action']

        # Return the action list
        return ret

    def get_limit_log(self, stat_name, default_action=False):
        """Return the log tag for the alert."""
        # Get the log tag for stat + header
        # Exemple: network_wlan0_rx_log
        try:
            log_tag = self._limits[stat_name + '_log']
        except KeyError:
            # Try fallback to plugin default log
            # Exemple: network_log
            try:
                log_tag = self._limits[self.plugin_name + '_log']
            except KeyError:
                # By defaukt, log are disabled
                return default_action

        # Return the action list
        return log_tag[0].lower() == 'true'

    def get_conf_value(self, value, header="", plugin_name=None):
        """Return the configuration (header_) value for the current plugin.

        ...or the one given by the plugin_name var.
        """
        if plugin_name is None:
            # If not default use the current plugin name
            plugin_name = self.plugin_name

        if header != "":
            # Add the header
            plugin_name = plugin_name + '_' + header

        try:
            return self._limits[plugin_name + '_' + value]
        except KeyError:
            return []

    def is_hide(self, value, header=""):
        """
        Return True if the value is in the hide configuration list.
        The hide configuration list is defined in the glances.conf file.
        It is a comma separed list of regexp.
        Example for diskio:
        hide=sda2,sda5,loop.*
        """
        # TODO: possible optimisation: create a re.compile list
        return not all(j is None for j in [re.match(i, value) for i in self.get_conf_value('hide', header=header)])

    def has_alias(self, header):
        """Return the alias name for the relative header or None if nonexist."""
        try:
            return self._limits[self.plugin_name + '_' + header + '_' + 'alias'][0]
        except (KeyError, IndexError):
            return None

    def msg_curse(self, args=None, max_width=None):
        """Return default string to display in the curse interface."""
        return [self.curse_add_line(str(self.stats))]

    def get_stats_display(self, args=None, max_width=None):
        """Return a dict with all the information needed to display the stat.

        key     | description
        ----------------------------
        display | Display the stat (True or False)
        msgdict | Message to display (list of dict [{ 'msg': msg, 'decoration': decoration } ... ])
        align   | Message position
        """
        display_curse = False

        if hasattr(self, 'display_curse'):
            display_curse = self.display_curse
        if hasattr(self, 'align'):
            align_curse = self._align

        if max_width is not None:
            ret = {'display': display_curse,
                   'msgdict': self.msg_curse(args, max_width=max_width),
                   'align': align_curse}
        else:
            ret = {'display': display_curse,
                   'msgdict': self.msg_curse(args),
                   'align': align_curse}

        return ret

    def curse_add_line(self, msg, decoration="DEFAULT",
                       optional=False, additional=False,
                       splittable=False):
        """Return a dict with.

        Where:
            msg: string
            decoration:
                DEFAULT: no decoration
                UNDERLINE: underline
                BOLD: bold
                TITLE: for stat title
                PROCESS: for process name
                STATUS: for process status
                NICE: for process niceness
                CPU_TIME: for process cpu time
                OK: Value is OK and non logged
                OK_LOG: Value is OK and logged
                CAREFUL: Value is CAREFUL and non logged
                CAREFUL_LOG: Value is CAREFUL and logged
                WARNING: Value is WARINING and non logged
                WARNING_LOG: Value is WARINING and logged
                CRITICAL: Value is CRITICAL and non logged
                CRITICAL_LOG: Value is CRITICAL and logged
            optional: True if the stat is optional (display only if space is available)
            additional: True if the stat is additional (display only if space is available after optional)
            spittable: Line can be splitted to fit on the screen (default is not)
        """
        return {'msg': msg, 'decoration': decoration, 'optional': optional, 'additional': additional, 'splittable': splittable}

    def curse_new_line(self):
        """Go to a new line."""
        return self.curse_add_line('\n')

    @property
    def align(self):
        """Get the curse align."""
        return self._align

    @align.setter
    def align(self, value):
        """Set the curse align.

        value: left, right, bottom.
        """
        self._align = value

    def auto_unit(self, number, low_precision=False):
        """Make a nice human-readable string out of number.

        Number of decimal places increases as quantity approaches 1.

        examples:
        CASE: 613421788        RESULT:       585M low_precision:       585M
        CASE: 5307033647       RESULT:      4.94G low_precision:       4.9G
        CASE: 44968414685      RESULT:      41.9G low_precision:      41.9G
        CASE: 838471403472     RESULT:       781G low_precision:       781G
        CASE: 9683209690677    RESULT:      8.81T low_precision:       8.8T
        CASE: 1073741824       RESULT:      1024M low_precision:      1024M
        CASE: 1181116006       RESULT:      1.10G low_precision:       1.1G

        'low_precision=True' returns less decimal places potentially
        sacrificing precision for more readability.
        """
        symbols = ('K', 'M', 'G', 'T', 'P', 'E', 'Z', 'Y')
        prefix = {
            'Y': 1208925819614629174706176,
            'Z': 1180591620717411303424,
            'E': 1152921504606846976,
            'P': 1125899906842624,
            'T': 1099511627776,
            'G': 1073741824,
            'M': 1048576,
            'K': 1024
        }

        for symbol in reversed(symbols):
            value = float(number) / prefix[symbol]
            if value > 1:
                decimal_precision = 0
                if value < 10:
                    decimal_precision = 2
                elif value < 100:
                    decimal_precision = 1
                if low_precision:
                    if symbol in 'MK':
                        decimal_precision = 0
                    else:
                        decimal_precision = min(1, decimal_precision)
                elif symbol in 'K':
                    decimal_precision = 0
                return '{:.{decimal}f}{symbol}'.format(
                    value, decimal=decimal_precision, symbol=symbol)
        return '{!s}'.format(number)

    def _check_decorator(fct):
        """Check if the plugin is enabled."""
        def wrapper(self, *args, **kw):
            if self.is_enable():
                ret = fct(self, *args, **kw)
            else:
                ret = self.stats
            return ret
        return wrapper

    def _log_result_decorator(fct):
        """Log (DEBUG) the result of the function fct."""
        def wrapper(*args, **kw):
            ret = fct(*args, **kw)
            logger.debug("%s %s %s return %s" % (
                args[0].__class__.__name__,
                args[0].__class__.__module__[len('glances_'):],
                fct.__name__, ret))
            return ret
        return wrapper

    # Mandatory to call the decorator in childs' classes
    _check_decorator = staticmethod(_check_decorator)
    _log_result_decorator = staticmethod(_log_result_decorator)
                                                                                                       ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_docker.pyc                          0000664 0000000 0000000 00000043675 13070471670 023644  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   s  d  Z  d d l Z d d l Z d d l Z d d l Z d d l m Z m Z d d l m	 Z	 d d l
 m Z d d l m
 r� Z e	 j d e � e a n Xe a d	 e
 �  �  YZ d e j f d �  �  YZ d S(
   itervalues(   t   logger(   t   getTimeSinceLastUpdate(   t
 e j e j
 �  Z d �  Z d �  Z d

    stats is a list
    c         C   sK   t  t |  � j d | � | |  _ t |  _ t |  _ i  |  _ |  j	 �  d S(   s   Init the plugin.t   argsN(
   t   superR   t   __init__R   t   Truet
 rB } t j d j | � � n X| S(   s~   Overwrite the default export method.

        - Only exports containers
        - The key is the first container name
        t
   containerss&   docker plugin - Docker export error {}(   t   statst   KeyErrorR   t   debugt   format(   R   t   rett   e(    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_docker.pyt
   get_exportU   s    c         C   s�   t  t d � r t j } n, t  t d � r6 t j } n t j d � d SyL t rY d } n d } | d k r} | d | � } n | d | d | � } Wn t k
 r� d SX| S(	   s9   Connect to the Docker server with the 'old school' methodt	   APIClientt   Clients<   docker plugin - Can not found any way to init the Docker APIs   npipe:////./pipe/docker_engines   unix://var/run/docker.sockt   base_urlt   versionN(	   t   hasattrt   dockerR   R   R   t   errort   NoneR   t	   NameError(   R   R!   t   init_dockert   urlR   (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_docker.pyt
 k	 r* t j �  } n |  j d | � } y | j �  Wnt j j k
 rw } t	 j
 d | � d
 St j j k
 r/} | d
 k rt	 j
 d | � t
 d | j d � � |  j d | j d � � } q,t	 j
 d � d
 } qYt	 j d | � d
 } n* t k
 rX} t	 j d | � d
 } n X| d
 k rut	 j
 d	 � n  | S(   s   Connect to the Docker server.t   from_envR!   s7   docker plugin - Can't connect to the Docker server (%s)s%   docker plugin - Docker API error (%s)s,   (?:server API version|server)\:\ (.*)\)".*\)s9   docker plugin - Try connection with Docker API version %si   s6   docker plugin - Can not retreive Docker server versionsK   docker plugin - Docker plugin is disable because an error has been detectedN(   R"   R#   R%   R*   t   _Plugin__connect_oldR!   t   requestst
   exceptionst   ConnectionErrorR   R   t   errorst   APIErrort   ret   searcht   strt   groupt   connectR$   t	   Exception(   R   R!   R   R   (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_docker.pyR5   �   s2    
c         C   s
 r? t a q[ X|  j d k r[ t a q[ n  t sh |  j S|  j d k r
y |  j j	 �  |  j d <Wn3 t k
 r� } t
 j d j |  j
 r} t
 j d j |  j
 j d j |  j
 j d	 j |  j
 <| d d d
   docker_tagR%   R   t   input_methodR!   R   R$   R   t   plugin_nameR   R   R   t   ThreadDockerGrabbert   startt   setR    R   R   t   get_docker_cput   get_docker_memoryt   get_docker_networkt
	

 r� } t j d
 j | | � � t j | � n
Xt |  d � s� i  |  _ y | |  j | <Wq� t t f k
 r� q� Xn  | |  j k r y | |  j | <Wq�t t f k
 rq�Xn� t	 | d |  j | d � } t	 | d |  j | d � } | d k r�| d k r�| | t	 | d	 � d | d <n  | |  j | <| S(

        Input: id is the full container id
               all_stats is the output of the stats method of the Docker API
        Output: a dict {'total': 1.49}
        g        t   totalt	   cpu_statst	   cpu_usaget   total_usaget   system_cpu_usaget   systemt   percpu_usaget   nb_cores;   docker plugin - Cannot grab CPU usage for container {} ({})t   cpu_oldid   (
   t   lenR   R   R   R   R"   RW   t   IOErrort   UnboundLocalErrort   float(   R   RM   t	   all_statst   cpu_newR   R   t	   cpu_deltat   system_delta(    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_docker.pyRF     s4    
 r� } t j d j | | � � t j | � n X| S(   s�   Return the container MEMORY.

        Input: id is the full container id
               all_stats is the output of the stats method of the Docker API
        Output: a dict {'rss': 1015808, 'cache': 356352,  'usage': ..., 'max_usage': ...}
        t   memory_statst   usaget   limitt	   max_usages;   docker plugin - Cannot grab MEM usage for container {} ({})(   R   t	   TypeErrorR   R   R   (   R   RM   R\   R   R   (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_docker.pyRG   I  s    c         C   s�  i  } y | d } Wn: t  k
 rP } t j d j | | � � t j | � | SXt |  d � s� i  |  _ y | |  j | <Wq� t t f k
 r� q� Xn  | |  j k r� y | |  j | <Wq�t t f k
 r� q�Xn� y� t d j | � � | d <| d d |  j | d d | d <| d d	 |  j | d d	 | d
 <| d d | d <| d d	 | d <Wn9 t  k
 r�} t j d

        Input: id is the full container id
        Output: a dict {'time_since_update': 3000, 'rx': 10, 'tx': 65}.
        with:
            time_since_update: number of seconds elapsed between the latest grab
            rx: Number of byte received
            tx: Number of byte transmited
        t   networkss;   docker plugin - Cannot grab NET usage for container {} ({})t   inetcounters_olds
 rP } t j d j | | � � t j | � | SXt |  d � s� i  |  _ y | |  j | <Wq� t t f k
 r� q� Xn  | |  j k r� y | |  j | <WqEt t f k
 r� qEXnqy� g  | d D] } | d d k r� | ^ q� d d } g  | d D] } | d d	 k r| ^ qd d } g  |  j | d D] } | d d k rS| ^ qSd d }	 g  |  j | d D] } | d d	 k r�| ^ q�d d }
 Wn2 t t  f k
 r�} t j d j | | � � nW Xt	 d
 j | � � | d <| |	 | d <| |
 | d

        Input: id is the full container id
        Output: a dict {'time_since_update': 3000, 'ior': 10, 'iow': 65}.
        with:
            time_since_update: number of seconds elapsed between the latest grab
            ior: Number of byte readed
            iow: Number of byte written
        t   blkio_statss@   docker plugin - Cannot grab block IO usage for container {} ({})t   iocounters_oldt   io_service_bytes_recursivet   opt   Readi    t   valuet   Writes   docker_io_{}Rg   t   iort   iowt   cumulative_iort   cumulative_iow(
   R   R   R   R   R"   Rs   RY   RZ   t
   IndexErrorR   (   R   RM   R\   t   io_newt
   iocountersR   t   iRy   Rz   t   ior_oldt   iow_old(    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_docker.pyRI   �  s@    


   SC_CLK_TCK(   t   ost   sysconft
        Docker will return self.stats['containers']R   (   R   (   R   (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_docker.pyt   get_stats_action�  s    c      
   C   s�  t  t |  � j �  d |  j k r& t Sx�|  j d D]y} i i  d 6i  d 6|  j | |  j �  <d | k r� d | d k r� |  j | d d d | d d d | d �} | d	 k r� |  j | d d d d �} n  | |  j | |  j �  d d
 <n  d | k r4 d | d k r4 |  j | d d d
 <q4 q4 Wt S(   s   Update stats views.R   R;   t   memRO   t   headerR   t   _cput
   action_keyt   DEFAULTt
   decorationR<   Ra   t   maximumRb   t   _mem(	   R   R   t   update_viewsR   R   t   viewsR   t	   get_alertR
   (   R   R�   t   alert(    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_docker.pyR�   �  s.    %
 t t |  j  d d d �  �d
 | |  } d j | d | �} | j |  j | � � |  j	 | d � } | d j
 d  d! � } d j | d d" !� } | j |  j | | � � y d# j | d$ d% � } Wn  t k
 r�d j d& � } n X| j |  j | |  j d' | d
 r/d j d& � } n X| j |  j | |  j d' | d
 r�d j d& � } n X| j |  j | � � x� d. d/ g D]� } yD |  j
 r;d j d& � } n X| j |  j | � � q�W| j rnd }
 d4 } n d2 }
 d3 } x� d5 d6 g D]� } yD |  j
 � � | }	 d j |	 � } Wn  t k
 r�d j d& � } n X| j |  j | � � q�Wd j | d � } | j |  j | d8 t �� q�W| S(9   s2   Return the dict to display in the curse interface.R   i    s   {}t
   CONTAINERSt   TITLEs    {}s    (served by Docker {})R!   t   Versioni   R9   c         S   s   t  |  d � S(   NR   (   RX   (   t   x(    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_docker.pyt   <lambda>   s    R   s    {:{width}}t   Namet   widths   {:>26}t   Statuss   {:>6}s   CPU%s   {:>7}t   MEMs   /MAXs   IOR/ss   IOW/ss   Rx/ss   Tx/ss    {:8}t   Commandt   _i   t   minutet   mini   s   {:>6.1f}R;   RO   t   ?t   itemt   optionR�   R<   Ra   R�   Rb   Ry   Rz   R>   Rg   i   t   bt    Rj   Rl   R=   t
   splittable(   R   RX   t
   is_disableR   t   appendt   curse_add_linet   curse_new_lineR�   t   maxt   container_alertt   replaceR   t	   get_viewst	   auto_unitt   intt   byteR
   (   R   R   R   t   msgt   name_max_widthRJ   R   t   statust   rRw   t   to_bitt   unit(    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_docker.pyt	   msg_curse	  s�    //


   __module__t   __doc__R%   R	   R   R   R   R+   R5   R   R   t   _check_decoratort   _log_result_decoratorRN   RF   RG   RH   RI   R�   R�   R�   R�   R�   (    (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_docker.pyR   .   s&   			
 RS(   sD   
    Specific thread to grab docker stats.

    stats is a dict
    c         C   sj   t  j d j | d  � � t t |  � j �  t j �  |  _ | |  _	 | j
 | d t �|  _ i  |  _
        docker_client: instance of Docker-py client
        container_id: Id of the containers.   docker plugin - Create thread for container {}i   t   decodeN(   R   R   R   R   RC   R	   t	   threadingt   Eventt   _stoppert
   t
 Pq
 q
 Wd S(   sd   Function called to grab stats.
        Infinite loop, should be stopped by calling the stop() methodg�������?N(   R�   R�   t   timet   sleept   stopped(   R   R�   (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_docker.pyt   run�  s
    	
(   R�   R�   R1   R�   R�   t   glances.compatR    R   t   glances.loggerR   t
   R   t   ThreadRC   (    (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_docker.pyt   <module>   s(   
� � W                                                                   ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_quicklook.py                        0000664 0000000 0000000 00000012676 13066703446 024234  0                                                                                                    ustar                                                                                                                                                                                                                                                          # -*- coding: utf-8 -*-
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""Quicklook plugin."""

from glances.cpu_percent import cpu_percent
from glances.outputs.glances_bars import Bar
from glances.plugins.glances_plugin import GlancesPlugin

import psutil

cpuinfo_tag = False
try:
    from cpuinfo import cpuinfo
except ImportError:
    # Correct issue #754
    # Waiting for a correction on the upstream Cpuinfo lib
    pass
else:
    cpuinfo_tag = True


class Plugin(GlancesPlugin):

    """Glances quicklook plugin.

    'stats' is a dictionary.
    """

    def __init__(self, args=None):
        """Init the quicklook plugin."""
        super(Plugin, self).__init__(args=args)

        # We want to display the stat in the curse interface
        self.display_curse = True

        # Init stats
        self.reset()

    def reset(self):
        """Reset/init the stats."""
        self.stats = {}

    @GlancesPlugin._check_decorator
    @GlancesPlugin._log_result_decorator
    def update(self):
        """Update quicklook stats using the input method."""
        # Reset stats
        self.reset()

        # Grab quicklook stats: CPU, MEM and SWAP
        if self.input_method == 'local':
            # Get the latest CPU percent value
            self.stats['cpu'] = cpu_percent.get()
            self.stats['percpu'] = cpu_percent.get(percpu=True)
            # Use the PsUtil lib for the memory (virtual and swap)
            self.stats['mem'] = psutil.virtual_memory().percent
            self.stats['swap'] = psutil.swap_memory().percent
        elif self.input_method == 'snmp':
            # Not available
            pass

        # Optionnaly, get the CPU name/frequency
        # thanks to the cpuinfo lib: https://github.com/workhorsy/py-cpuinfo
        if cpuinfo_tag:
            cpu_info = cpuinfo.get_cpu_info()
            #  Check cpu_info (issue #881)
            if cpu_info is not None:
                self.stats['cpu_name'] = cpu_info['brand']
                self.stats['cpu_hz_current'] = cpu_info['hz_actual_raw'][0]
                self.stats['cpu_hz'] = cpu_info['hz_advertised_raw'][0]

        return self.stats

    def update_views(self):
        """Update stats views."""
        # Call the father's method
        super(Plugin, self).update_views()

        # Add specifics informations
        # Alert only
        for key in ['cpu', 'mem', 'swap']:
            if key in self.stats:
                self.views[key]['decoration'] = self.get_alert(self.stats[key], header=key)

    def msg_curse(self, args=None, max_width=10):
        """Return the list to display in the UI."""
        # Init the return message
        ret = []

        # Only process if stats exist...
        if not self.stats or self.is_disable():
            return ret

        # Define the bar
        bar = Bar(max_width)

        # Build the string message
        if 'cpu_name' in self.stats and 'cpu_hz_current' in self.stats and 'cpu_hz' in self.stats:
            msg_name = '{} - '.format(self.stats['cpu_name'])
            msg_freq = '{:.2f}/{:.2f}GHz'.format(self._hz_to_ghz(self.stats['cpu_hz_current']),
                                                 self._hz_to_ghz(self.stats['cpu_hz']))
            if len(msg_name + msg_freq) - 6 <= max_width:
                ret.append(self.curse_add_line(msg_name))
            ret.append(self.curse_add_line(msg_freq))
            ret.append(self.curse_new_line())
        for key in ['cpu', 'mem', 'swap']:
            if key == 'cpu' and args.percpu:
                for cpu in self.stats['percpu']:
                    bar.percent = cpu['total']
                    if cpu[cpu['key']] < 10:
                        msg = '{:3}{} '.format(key.upper(), cpu['cpu_number'])
                    else:
                        msg = '{:4} '.format(cpu['cpu_number'])
                    ret.extend(self._msg_create_line(msg, bar, key))
                    ret.append(self.curse_new_line())
            else:
                bar.percent = self.stats[key]
                msg = '{:4} '.format(key.upper())
                ret.extend(self._msg_create_line(msg, bar, key))
                ret.append(self.curse_new_line())

        # Remove the last new line
        ret.pop()

        # Return the message with decoration
        return ret

    def _msg_create_line(self, msg, bar, key):
        """Create a new line to the Quickview"""
        ret = []

        ret.append(self.curse_add_line(msg))
        ret.append(self.curse_add_line(bar.pre_char, decoration='BOLD'))
        ret.append(self.curse_add_line(str(bar), self.get_views(key=key, option='decoration')))
        ret.append(self.curse_add_line(bar.post_char, decoration='BOLD'))
        ret.append(self.curse_add_line('  '))

        return ret

    def _hz_to_ghz(self, hz):
        """Convert Hz to Ghz"""
        return hz / 1000000000.0
                                                                  ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_gpu.py                              0000664 0000000 0000000 00000023102 13066703446 023010  0                                                                                                    ustar                                                                                                                                                                                                                                                          # -*- coding: utf-8 -*-
#
# This file is part of Glances.
#
# Copyright (C) 2017 Kirby Banman <kirby.banman@gmail.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""GPU plugin (limited to NVIDIA chipsets)"""

from glances.logger import logger
from glances.plugins.glances_plugin import GlancesPlugin

try:
    import pynvml
except ImportError:
    logger.debug("Could not import pynvml.  NVIDIA stats will not be collected.")
    gpu_nvidia_tag = False
else:
    gpu_nvidia_tag = True


class Plugin(GlancesPlugin):

    """Glances GPU plugin (limited to NVIDIA chipsets).

    stats is a list of dictionaries with one entry per GPU
    """

    def __init__(self, args=None):
        """Init the plugin"""
        super(Plugin, self).__init__(args=args)

        # Init the NVidia API
        self.init_nvidia()

        # We want to display the stat in the curse interface
        self.display_curse = True

        # Init the stats
        self.reset()

    def reset(self):
        """Reset/init the stats."""
        self.stats = []

    def init_nvidia(self):
        """Init the NVIDIA API"""
        if not gpu_nvidia_tag:
            self.nvml_ready = False

        try:
            pynvml.nvmlInit()
            self.device_handles = self.get_device_handles()
            self.nvml_ready = True
        except Exception:
            logger.debug("pynvml could not be initialized.")
            self.nvml_ready = False

        return self.nvml_ready

    def get_key(self):
        """Return the key of the list."""
        return 'gpu_id'

    @GlancesPlugin._check_decorator
    @GlancesPlugin._log_result_decorator
    def update(self):
        """Update the GPU stats"""

        self.reset()

        # !!! JUST FOR TEST
        # self.stats = [{"key": "gpu_id", "mem": None, "proc": 60, "gpu_id": 0, "name": "GeForce GTX 560 Ti"}]
        # self.stats = [{"key": "gpu_id", "mem": 10, "proc": 60, "gpu_id": 0, "name": "GeForce GTX 560 Ti"}]
        # self.stats = [{"key": "gpu_id", "mem": 48.64645, "proc": 60.73, "gpu_id": 0, "name": "GeForce GTX 560 Ti"},
        #               {"key": "gpu_id", "mem": 70.743, "proc": 80.28, "gpu_id": 1, "name": "GeForce GTX 560 Ti"},
        #               {"key": "gpu_id", "mem": 0, "proc": 0, "gpu_id": 2, "name": "GeForce GTX 560 Ti"}]
        # self.stats = [{"key": "gpu_id", "mem": 48.64645, "proc": 60.73, "gpu_id": 0, "name": "GeForce GTX 560 Ti"},
        #               {"key": "gpu_id", "mem": None, "proc": 80.28, "gpu_id": 1, "name": "GeForce GTX 560 Ti"},
        #               {"key": "gpu_id", "mem": 0, "proc": 0, "gpu_id": 2, "name": "ANOTHER GPU"}]
        # !!! TO BE COMMENTED

        if not self.nvml_ready:
            return self.stats

        if self.input_method == 'local':
            self.stats = self.get_device_stats()
        elif self.input_method == 'snmp':
            # not available
            pass

        return self.stats

    def update_views(self):
        """Update stats views."""
        # Call the father's method
        super(Plugin, self).update_views()

        # Add specifics informations
        # Alert
        for i in self.stats:
            # Init the views for the current GPU
            self.views[i[self.get_key()]] = {'proc': {}, 'mem': {}}
            # Processor alert
            if 'proc' in i:
                alert = self.get_alert(i['proc'], header='proc')
                self.views[i[self.get_key()]]['proc']['decoration'] = alert
            # Memory alert
            if 'mem' in i:
                alert = self.get_alert(i['mem'], header='mem')
                self.views[i[self.get_key()]]['mem']['decoration'] = alert

        return True

    def msg_curse(self, args=None):
        """Return the dict to display in the curse interface."""
        # Init the return message
        ret = []

        # Only process if stats exist, not empty (issue #871) and plugin not disabled
        if not self.stats or (self.stats == []) or self.is_disable():
            return ret

        # Check if all GPU have the same name
        same_name = all(s['name'] == self.stats[0]['name'] for s in self.stats)

        # gpu_stats contain the first GPU in the list
        gpu_stats = self.stats[0]

        # Header
        header = ''
        if len(self.stats) > 1:
            header += '{} '.format(len(self.stats))
        if same_name:
            header += '{} {}'.format('GPU', gpu_stats['name'])
        else:
            header += '{}'.format('GPU')
        msg = header[:17]
        ret.append(self.curse_add_line(msg, "TITLE"))

        # Build the string message
        if len(self.stats) == 1 or args.meangpu:
            # GPU stat summary or mono GPU
            # New line
            ret.append(self.curse_new_line())
            # GPU PROC
            try:
                mean_proc = sum(s['proc'] for s in self.stats if s is not None) / len(self.stats)
            except TypeError:
                mean_proc_msg = '{:>4}'.format('N/A')
            else:
                mean_proc_msg = '{:>3.0f}%'.format(mean_proc)
            if len(self.stats) > 1:
                msg = '{:13}'.format('proc mean:')
            else:
                msg = '{:13}'.format('proc:')
            ret.append(self.curse_add_line(msg))
            ret.append(self.curse_add_line(
                mean_proc_msg, self.get_views(item=gpu_stats[self.get_key()],
                                              key='proc',
                                              option='decoration')))
            # New line
            ret.append(self.curse_new_line())
            # GPU MEM
            try:
                mean_mem = sum(s['mem'] for s in self.stats if s is not None) / len(self.stats)
            except TypeError:
                mean_mem_msg = '{:>4}'.format('N/A')
            else:
                mean_mem_msg = '{:>3.0f}%'.format(mean_mem)
            if len(self.stats) > 1:
                msg = '{:13}'.format('mem mean:')
            else:
                msg = '{:13}'.format('mem:')
            ret.append(self.curse_add_line(msg))
            ret.append(self.curse_add_line(
                mean_mem_msg, self.get_views(item=gpu_stats[self.get_key()],
                                             key='mem',
                                             option='decoration')))
        else:
            # Multi GPU
            for gpu_stats in self.stats:
                # New line
                ret.append(self.curse_new_line())
                # GPU ID + PROC + MEM
                id_msg = '{}'.format(gpu_stats['gpu_id'])
                try:
                    proc_msg = '{:>3.0f}%'.format(gpu_stats['proc'])
                except ValueError:
                    proc_msg = '{:>4}'.format('N/A')
                try:
                    mem_msg = '{:>3.0f}%'.format(gpu_stats['mem'])
                except ValueError:
                    mem_msg = '{:>4}'.format('N/A')
                msg = '{}: {} mem: {}'.format(id_msg, proc_msg, mem_msg)
                ret.append(self.curse_add_line(msg))

        return ret

    def get_device_handles(self):
        """
        Returns a list of NVML device handles, one per device.  Can throw NVMLError.
        """
        return [pynvml.nvmlDeviceGetHandleByIndex(i) for i in range(pynvml.nvmlDeviceGetCount())]

    def get_device_stats(self):
        """Get GPU stats"""
        stats = []

        for index, device_handle in enumerate(self.device_handles):
            device_stats = {}
            # Dictionnary key is the GPU_ID
            device_stats['key'] = self.get_key()
            # GPU id (for multiple GPU, start at 0)
            device_stats['gpu_id'] = index
            # GPU name
            device_stats['name'] = self.get_device_name(device_handle)
            # Memory consumption in % (not available on all GPU)
            device_stats['mem'] = self.get_mem(device_handle)
            # Processor consumption in %
            device_stats['proc'] = self.get_proc(device_handle)
            stats.append(device_stats)

        return stats

    def get_device_name(self, device_handle):
        """Get GPU device name"""
        try:
            return pynvml.nvmlDeviceGetName(device_handle)
        except pynvml.NVMlError:
            return "NVIDIA"

    def get_mem(self, device_handle):
        """Get GPU device memory consumption in percent"""
        try:
            memory_info = pynvml.nvmlDeviceGetMemoryInfo(device_handle)
            return memory_info.used * 100.0 / memory_info.total
        except pynvml.NVMLError:
            return None

    def get_proc(self, device_handle):
        """Get GPU device CPU consumption in percent"""
        try:
            return pynvml.nvmlDeviceGetUtilizationRates(device_handle).gpu
        except pynvml.NVMLError:
            return None

    def exit(self):
        """Overwrite the exit method to close the GPU API"""
        if self.nvml_ready:
            try:
                pynvml.nvmlShutdown()
            except Exception as e:
                logger.debug("pynvml failed to shutdown correctly ({})".format(e))

        # Call the father exit method
        super(Plugin, self).exit()
                                                                                                                                                                                                                                                                                                                                                                                                                                                              ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_processlist.pyc                     0000664 0000000 0000000 00000043774 13070471670 024747  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   s�   d  Z  d d l Z d d l m Z d d l m Z d d l m Z m Z d d l	 m
 Z
 d d l m Z m
 �  Z d �  Z d e f d
   sort_stats(   t   Plugin(   t
   R
 r� d	 } q� Xn  | | | f S(
   s5   Return path, cmd and arguments for a process cmdline.i    t    i   s   
c         3   s   |  ] } | �  d  k Vq d S(   i    N(    (   t   .0t   x(   t   cmdline(    sM   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_processlist.pys	   <genexpr>1   s    t   chromet   chromium(   R   R   N(	   t   ost   patht   splitt   joint   replaceR   t   anyt
   ValueErrort   None(   R   R   t   cmdt	   argumentst   exe(    (   R   sM   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_processlist.pyt
 d �  Z d d � Z d d	 � Z
 d d d � Z d �  Z d

    stats is a list
    c         C   s�   t  t |  � j d | � t |  _ t |  _ y# t d |  j � j �  d |  _	 Wn t
 k
 rj d |  _	 n Xt j �  |  _ t j
   CorePluginR%   t   updatet   nb_log_coret	   ExceptionR   t
   max_valuest   pid_max(   t   selfR%   (    (    sM   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_processlist.pyR(   B   s    		#
c         C   sJ  g  } d } | j  r` | d k s. | d k r` |  j | j t | � } | d 7} | j | � n  x� | j �  D]� } | d k	 r� | | k r� Pn  | d k r� d }	 n
 | | }	 |  j | | d | j  d |	 �}
 | d k r� | t | � 7} n | t	 |	 t | � � 7} | j  s5|  j
 |
 | | j d k | � }
 n  | j |
 � qm W| S(   s.   Get curses data to display for a process tree.i    i   t   first_levelt   max_node_counti����N(   t   is_rootR    t   get_process_curses_dataR5   t   Falset   extendt
   node_countt	   node_datat   childt   children_max_node_countt
   child_data(    (    sM   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_processlist.pyRD   z   s.    "
	
				%c         C   s�  g  } xC t  | � D]5 \ } } | j d t � r | d =| j | � q q Wg  } g  } xm t  | � D]_ \ } } | | k r� | j t | � � | j |  j d � � t | d d <n  | j | � qe W| } | } | r�| r� d }	 n d }	 |	 | | d d <xf | D]^ } d }
 | r#d	 }
 n | rB| | d k	 rBd
 }
 n  d d |
 | | d f | | d <qW| s�x` | d	 D]Q } | | d } | r�d
 | | d <q{Wq�n  | S(   s8   Add tree curses decoration and indentation to a subtree.t   _tree_decorationt    i����s   └─s   ├─i    t   msgi   i   i   s   %s%sR   s    │s   │(   t	   enumeratet   getRA   t   appendRE   t   curse_add_lineR)   (   R2   RO   t
 | | � � n% d	 j d
 � } | j	 |  j
 | � � d | k r�| d dV k	 r�| d d k r�d j | d � } |  j | d d t d | d |  j d k d d �} | j	 |  j
 | | � � n% d	 j d
 � } | j	 |  j
 | � � d
 | d t �� d	 j |  j | d
 | d t �� n; d	 j d
 � } | j	 |  j
 | � � | j	 |  j
 | � � d j | d d |  j
 | � � d | k rd j t | d � d  � } | j	 |  j
 | � � n% d j d
 � } | j	 |  j
 | � � d | k r�| d } | dV k rod
 } n  d j | � } t | t � r�t r�| d k s�t r�| d k r�| j	 |  j
 | d d �� q| j	 |  j
 | � � n% d j d
 � } | j	 |  j
 | � � d | k rx| d } d j | � } | d k r_| j	 |  j
 | d d �� q�| j	 |  j
 | � � n% d j d
 � } | j	 |  j
 | � � |  j r�y t d  t | d! � � }	 Wn8 t t f k
 r�}
 t j d" j |
 � � t |  _ q�Xt |	 � \ } } }
 | d d$ d t �� d% j t | � j d& � |
 � } | j	 |  j
 | d t �� d) | k r�t | d) d | d) d& | d* � } | d k rd	 j d+ � } n d	 j |  j | d t �� } | j	 |  j
 | d t d, t �� t | d) d | d) d- | d* � } | d k r�d	 j d+ � } n d	 j |  j | d t �� } | j	 |  j
 | d t d, t �� nS d	 j d
 � } | j	 |  j
 | d t d, t �� | j	 |  j
 | d t d, t �� | d. } yr| rn| d g k rnt | � \ } } } t j j | � r�| j r�d/ j | � t j  } | j	 |  j
 | d0 t �� t! j" �  r�t | d1 d2 <n  | j	 |  j
 | d d3 d0 t �� nN d/ j | � } | j	 |  j
 | d d3 d0 t �� t! j" �  r7t | d1 d2 <n  | r�d/ j | � } | j	 |  j
 | d0 t �� q�n/ d/ j | d4 � } | j	 |  j
 | d0 t �� Wn- t# k
 r�| j	 |  j
 d d0 t �� n X| rt
 | d0 t �� n  d
| d
| j	 |  j  �  � | d; } xd t% | d
| d> dV k	 r6
| d? |  j | d> d t �7} n  | j	 |  j
 | d0 t �� n  d } d@ | k r�
| d@ dV k	 r�
| dA t | d@ � d6 7} n  dB | k r�
| dB dV k	 r�
| dC t | dB � d6 7} n  dD | k r| dD dV k	 r| dE t | dD � d6 7} n  dF | k rG| dF dV k	 rG| dG t | dF � d6 7} n  dH | k r�| dH dV k	 r�| dI t | dH � d6 7} n  | d k r�| j	 |  j  �  � | dJ | } | j	 |  j
 | d0 t �� n  dK | k rt
 | d0 t �� qt
        - p is the process to display
        - first is a tag=True if the process is the first on the list
        t   cpu_percentRQ   i    s   {:>6.1f}t   highlight_zerot   is_maxt   headert   cpus   {:>6}t   ?t   memory_percentt   memt   memory_infoi   t
   decorationt   NICEt   statuss   {:>2}t   Rt   STATUSR
   t	   cpu_timess   Cannot get TIME+ ({})s   {:>4}ht   CPU_TIMEs   {}:{}i   s   {:>4}:{}.{}s   {:>10}t   io_counterst   time_since_updatet   0t
   additionali   R   s    {}t
   splittablei����RP   t   PROCESSt   namet   extended_statsR   i
   isinstancet   intR   R+   R    t   sumt
   R
	!
	
%"" 
#,$

 �� n� t	 } x9 |  j | � D]( } | j |  j | | | � � t } q� Wt j
	
 � } | j |  j | | d k r� | n d	 � � d j d � } | j |  j | d
        Build the header and add it to the ret dict
        t   SORTi    i
   s   {:>6}s   CPU%/s   CPU%/Cs   CPU%R`   t   DEFAULTs   MEM%Rf   t   VIRTRj   t   RESs   {:>{width}}t   PIDRk   i   s    {:10}t   USERRl   s   {:>4}t   NIs   {:>2}t   Ss   {:>10}s   TIME+Rs   s   R/sRu   Rx   s   W/ss    {:8}t   CommandR{   N(   R�   R.   R�   R   RU   RV   R)   R�   (   R2   RJ   R�   R%   t
   sort_styleRR   (    (    sM   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_processlist.pyt   __msg_curse_header�  s:    (+++177t   _c      	   C   s)  | j  |  j �  � | d k rO | j  |  j | d � � | j  |  j �  � n  d j |  j d d | �� } | j  |  j | d |  j | � �� d j |  j d d | �� } | j  |  j | d |  j | � �� d |  j d k r�|  j d d d k	 r�|  j d d d	 k r�d
 j |  j |  j d d d d | �d
 �� d
 j |  j |  j d d d d | �d
 �� n; d
 j d	 � } | j  |  j | � � | j  |  j | � � d
 j d	 � } | j  |  j | � � d j d	 � } | j  |  j | � � d j d	 � } | j  |  j | � � d j d	 � } | j  |  j | � � d j d	 � } | j  |  j | d t
 �� d |  j d k rK| d k rKt |  j d d � |  j d d d d | �|  j d d � } | d k rLd
 j d � } n d
 j |  j | d
 �� } | j  |  j | d |  j | � d t
 d t
 �� t |  j d d � |  j d d d d | �|  j d d � } | d k r�d
 j d � } n d
 j |  j | d
 �� } | j  |  j | d |  j | � d t
 d t
 �� nS d
 j d	 � } | j  |  j | d t
 d t
 �� | j  |  j | d t
 d t
 �� | d k r�d j d � } | j  |  j | d t
 �� nM d j | � } | j  |  j | d t
 �� d } | j  |  j | d t
 �� d S(   s$  
        Build the sum message (only when filter is on) and add it to the ret dict
        * ret: list of string where the message is added
        * sep_char: define the line separation char
        * mmm: display min, max, mean or current (if mmm=None)
        * args: Glances args
        iE   s   {:>6.1f}R`   R�   Rn   Rf   Rh   i    RQ   s   {:>6}t   indicei   Ri   Rj   s    {:9}s   {:>5}s   {:>2}s   {:>10}Ru   i   Rv   Rw   Rx   i   s    < {}t   currents    ('M' to reset)N(   RU   R�   R    RV   R�   t   _Plugin__sum_statst   _Plugin__mmm_decoR5   R�   RA   R)   R�   (   R2   RJ   t   sep_charR�   R%   RR   R�   R�   (    (    sM   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_processlist.pyt   __msg_curse_sum�  sr    A3
3
        Return the decoration string for the current mmm status
        R�   t   FILTERN(   R    (   R2   R�   (    (    sM   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_processlist.pyt
   __mmm_decoL  s    c         C   s   i  |  _  i  |  _ d S(   s%   
        Reset the MMM stats
        N(   t   mmm_mint   mmm_max(   R2   (    (    sM   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_processlist.pyt   __mmm_resetU  s    	c         C   s[  d } x@ |  j  D]5 } | d k r3 | | | 7} q | | | | 7} q W|  j | | � } | d k r� y' |  j | | k r� | |  j | <n  Wn8 t k
 r� i  |  _ d St k
 r� | |  j | <n X|  j | } n~ | d k rWy' |  j | | k  r| |  j | <n  Wn8 t k
 r)i  |  _ d St k
 rF| |  j | <n X|  j | } n  | S(   s�   
        Return the sum of the stats value for the given key
        * indice: If indice is set, get the p[key][indice]
        * mmm: display min, max, mean or current (if mmm=None)
        i    RF   R�   N(   R5   R    t   _Plugin__mmm_keyR�   t   AttributeErrort   KeyErrorR�   (   R2   t   keyR�   R�   RJ   R�   t   mmm_key(    (    sM   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_processlist.pyt   __sum_stats\  s6    
   __module__t   __doc__R    R(   R4   R6   R-   R)   RD   RG   R@   R�   R�   R�   R�   R�   R�   R�   R�   R�   (    (    (    sM   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_processlist.pyR   ;   s"   				2	�&$T			'	(   R�   R   t   datetimeR    t   glances.compatR   t   glances.globalsR   R   t   glances.loggerR   t   glances.processesR   R   t   glances.plugins.glances_coreR   R,   t   glances.plugins.glances_pluginR   R   R$   (    (    (    sM   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_processlist.pyt   <module>   s   		    ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_amps.py                             0000664 0000000 0000000 00000011021 13066703446 023152  0                                                                                                    ustar                                                                                                                                                                                                                                                          # -*- coding: utf-8 -*-
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""Monitor plugin."""

from glances.compat import iteritems
from glances.amps_list import AmpsList as glancesAmpsList
from glances.plugins.glances_plugin import GlancesPlugin


class Plugin(GlancesPlugin):

    """Glances AMPs plugin."""

    def __init__(self, args=None, config=None):
        """Init the plugin."""
        super(Plugin, self).__init__(args=args)
        self.args = args
        self.config = config

        # We want to display the stat in the curse interface
        self.display_curse = True

        # Init the list of AMP (classe define in the glances/amps_list.py script)
        self.glances_amps = glancesAmpsList(self.args, self.config)

        # Init stats
        self.reset()

    def reset(self):
        """Reset/init the stats."""
        self.stats = []

    @GlancesPlugin._check_decorator
    @GlancesPlugin._log_result_decorator
    def update(self):
        """Update the AMP list."""
        # Reset stats
        self.reset()

        if self.input_method == 'local':
            for k, v in iteritems(self.glances_amps.update()):
                # self.stats.append({k: v.result()})
                self.stats.append({'key': k,
                                   'name': v.NAME,
                                   'result': v.result(),
                                   'refresh': v.refresh(),
                                   'timer': v.time_until_refresh(),
                                   'count': v.count(),
                                   'countmin': v.count_min(),
                                   'countmax': v.count_max()})
        else:
            # Not available in SNMP mode
            pass

        return self.stats

    def get_alert(self, nbprocess=0, countmin=None, countmax=None, header="", log=False):
        """Return the alert status relative to the process number."""
        if nbprocess is None:
            return 'OK'
        if countmin is None:
            countmin = nbprocess
        if countmax is None:
            countmax = nbprocess
        if nbprocess > 0:
            if int(countmin) <= int(nbprocess) <= int(countmax):
                return 'OK'
            else:
                return 'WARNING'
        else:
            if int(countmin) == 0:
                return 'OK'
            else:
                return 'CRITICAL'

    def msg_curse(self, args=None):
        """Return the dict to display in the curse interface."""
        # Init the return message
        # Only process if stats exist and display plugin enable...
        ret = []

        if not self.stats or args.disable_process or self.is_disable():
            return ret

        # Build the string message
        for m in self.stats:
            # Only display AMP if a result exist
            if m['result'] is None:
                continue
            # Display AMP
            first_column = '{}'.format(m['name'])
            first_column_style = self.get_alert(m['count'], m['countmin'], m['countmax'])
            second_column = '{}'.format(m['count'])
            for l in m['result'].split('\n'):
                # Display first column with the process name...
                msg = '{:<16} '.format(first_column)
                ret.append(self.curse_add_line(msg, first_column_style))
                # ... and second column with the number of matching processes...
                msg = '{:<4} '.format(second_column)
                ret.append(self.curse_add_line(msg))
                # ... only on the first line
                first_column = second_column = ''
                # Display AMP result in the third column
                ret.append(self.curse_add_line(l, splittable=True))
                ret.append(self.curse_new_line())

        # Delete the last empty line
        try:
            ret.pop()
        except IndexError:
            pass

        return ret
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_sensors.py                          0000664 0000000 0000000 00000025650 13066703446 023723  0                                                                                                    ustar                                                                                                                                                                                                                                                          # -*- coding: utf-8 -*-
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""Sensors plugin."""

import psutil

from glances.logger import logger
from glances.compat import iteritems
from glances.plugins.glances_batpercent import Plugin as BatPercentPlugin
from glances.plugins.glances_hddtemp import Plugin as HddTempPlugin
from glances.plugins.glances_plugin import GlancesPlugin

SENSOR_TEMP_UNIT = 'C'
SENSOR_FAN_UNIT = 'rpm'


def to_fahrenheit(celsius):
    """Convert Celsius to Fahrenheit."""
    return celsius * 1.8 + 32


class Plugin(GlancesPlugin):

    """Glances sensors plugin.

    The stats list includes both sensors and hard disks stats, if any.
    The sensors are already grouped by chip type and then sorted by name.
    The hard disks are already sorted by name.
    """

    def __init__(self, args=None):
        """Init the plugin."""
        super(Plugin, self).__init__(args=args)

        # Init the sensor class
        self.glancesgrabsensors = GlancesGrabSensors()

        # Instance for the HDDTemp Plugin in order to display the hard disks
        # temperatures
        self.hddtemp_plugin = HddTempPlugin(args=args)

        # Instance for the BatPercent in order to display the batteries
        # capacities
        self.batpercent_plugin = BatPercentPlugin(args=args)

        # We want to display the stat in the curse interface
        self.display_curse = True

        # Init the stats
        self.reset()

    def get_key(self):
        """Return the key of the list."""
        return 'label'

    def reset(self):
        """Reset/init the stats."""
        self.stats = []

    @GlancesPlugin._check_decorator
    @GlancesPlugin._log_result_decorator
    def update(self):
        """Update sensors stats using the input method."""
        # Reset the stats
        self.reset()

        if self.input_method == 'local':
            # Update stats using the dedicated lib
            self.stats = []
            # Get the temperature
            try:
                temperature = self.__set_type(self.glancesgrabsensors.get('temperature_core'),
                                              'temperature_core')
            except Exception as e:
                logger.error("Cannot grab sensors temperatures (%s)" % e)
            else:
                # Append temperature
                self.stats.extend(temperature)
            # Get the FAN speed
            try:
                fan_speed = self.__set_type(self.glancesgrabsensors.get('fan_speed'),
                                            'fan_speed')
            except Exception as e:
                logger.error("Cannot grab FAN speed (%s)" % e)
            else:
                # Append FAN speed
                self.stats.extend(fan_speed)
            # Update HDDtemp stats
            try:
                hddtemp = self.__set_type(self.hddtemp_plugin.update(),
                                          'temperature_hdd')
            except Exception as e:
                logger.error("Cannot grab HDD temperature (%s)" % e)
            else:
                # Append HDD temperature
                self.stats.extend(hddtemp)
            # Update batteries stats
            try:
                batpercent = self.__set_type(self.batpercent_plugin.update(),
                                             'battery')
            except Exception as e:
                logger.error("Cannot grab battery percent (%s)" % e)
            else:
                # Append Batteries %
                self.stats.extend(batpercent)

        elif self.input_method == 'snmp':
            # Update stats using SNMP
            # No standard:
            # http://www.net-snmp.org/wiki/index.php/Net-SNMP_and_lm-sensors_on_Ubuntu_10.04

            pass

        return self.stats

    def __set_type(self, stats, sensor_type):
        """Set the plugin type.

        4 types of stats is possible in the sensors plugin:
        - Core temperature: 'temperature_core'
        - Fan speed: 'fan_speed'
        - HDD temperature: 'temperature_hdd'
        - Battery capacity: 'battery'
        """
        for i in stats:
            # Set the sensors type
            i.update({'type': sensor_type})
            # also add the key name
            i.update({'key': self.get_key()})

        return stats

    def update_views(self):
        """Update stats views."""
        # Call the father's method
        super(Plugin, self).update_views()

        # Add specifics informations
        # Alert
        for i in self.stats:
            if not i['value']:
                continue
            if i['type'] == 'battery':
                self.views[i[self.get_key()]]['value']['decoration'] = self.get_alert(100 - i['value'], header=i['type'])
            else:
                self.views[i[self.get_key()]]['value']['decoration'] = self.get_alert(i['value'], header=i['type'])

    def msg_curse(self, args=None):
        """Return the dict to display in the curse interface."""
        # Init the return message
        ret = []

        # Only process if stats exist and display plugin enable...
        if not self.stats or args.disable_sensors:
            return ret

        # Build the string message
        # Header
        msg = '{:18}'.format('SENSORS')
        ret.append(self.curse_add_line(msg, "TITLE"))

        for i in self.stats:
            # Do not display anything if no battery are detected
            if i['type'] == 'battery' and i['value'] == []:
                continue
            # New line
            ret.append(self.curse_new_line())
            # Alias for the lable name ?
            label = self.has_alias(i['label'].lower())
            if label is None:
                label = i['label']
            if i['type'] != 'fan_speed':
                msg = '{:15}'.format(label[:15])
            else:
                msg = '{:13}'.format(label[:13])
            ret.append(self.curse_add_line(msg))
            if i['value'] in (b'ERR', b'SLP', b'UNK', b'NOS'):
                msg = '{:>8}'.format(i['value'])
                ret.append(self.curse_add_line(
                    msg, self.get_views(item=i[self.get_key()],
                                        key='value',
                                        option='decoration')))
            else:
                if (args.fahrenheit and i['type'] != 'battery' and
                        i['type'] != 'fan_speed'):
                    value = to_fahrenheit(i['value'])
                    unit = 'F'
                else:
                    value = i['value']
                    unit = i['unit']
                try:
                    msg = '{:>7.0f}{}'.format(value, unit)
                    ret.append(self.curse_add_line(
                        msg, self.get_views(item=i[self.get_key()],
                                            key='value',
                                            option='decoration')))
                except (TypeError, ValueError):
                    pass

        return ret


class GlancesGrabSensors(object):

    """Get sensors stats."""

    def __init__(self):
        """Init sensors stats."""
        # Temperatures
        self.init_temp = False
        self.stemps = {}
        try:
            # psutil>=5.1.0 is required
            self.stemps = psutil.sensors_temperatures()
        except AttributeError:
            logger.warning("PsUtil 5.1.0 or higher is needed to grab temperatures sensors")
        except OSError as e:
            # FreeBSD: If oid 'hw.acpi.battery' not present, Glances wont start #1055
            logger.error("Can not grab temperatures sensors ({})".format(e))
        else:
            self.init_temp = True

        # Fans
        self.init_fan = False
        self.sfans = {}
        try:
            # psutil>=5.2.0 is required
            self.sfans = psutil.sensors_fans()
        except AttributeError:
            logger.warning("PsUtil 5.2.0 or higher is needed to grab fans sensors")
        except OSError as e:
            logger.error("Can not grab fans sensors ({})".format(e))
        else:
            self.init_fan = True

        # !!! Disable Fan: High CPU consumption is PSUtil 5.2.0
        # Delete the following line when corrected
        self.init_fan = False

        # Init the stats
        self.reset()

    def reset(self):
        """Reset/init the stats."""
        self.sensors_list = []

    def __update__(self):
        """Update the stats."""
        # Reset the list
        self.reset()

        if not self.init_temp:
            return self.sensors_list

        # Temperatures sensors
        self.sensors_list.extend(self.build_sensors_list(SENSOR_TEMP_UNIT))

        # Fans sensors
        self.sensors_list.extend(self.build_sensors_list(SENSOR_FAN_UNIT))

        return self.sensors_list

    def build_sensors_list(self, type):
        """Build the sensors list depending of the type.

        type: SENSOR_TEMP_UNIT or SENSOR_FAN_UNIT

        output: a list"""
        ret = []
        if type == SENSOR_TEMP_UNIT and self.init_temp:
            input_list = self.stemps
            self.stemps = psutil.sensors_temperatures()
        elif type == SENSOR_FAN_UNIT and self.init_fan:
            input_list = self.sfans
            self.sfans = psutil.sensors_fans()
        else:
            return ret
        for chipname, chip in iteritems(input_list):
            i = 1
            for feature in chip:
                sensors_current = {}
                # Sensor name
                if feature.label == '':
                    sensors_current['label'] = chipname + ' ' + str(i)
                else:
                    sensors_current['label'] = feature.label
                # Fan speed and unit
                sensors_current['value'] = int(feature.current)
                sensors_current['unit'] = type
                # Add sensor to the list
                ret.append(sensors_current)
                i += 1
        return ret

    def get(self, sensor_type='temperature_core'):
        """Get sensors list."""
        self.__update__()
        if sensor_type == 'temperature_core':
            ret = [s for s in self.sensors_list if s['unit'] == SENSOR_TEMP_UNIT]
        elif sensor_type == 'fan_speed':
            ret = [s for s in self.sensors_list if s['unit'] == SENSOR_FAN_UNIT]
        else:
            # Unknown type
            logger.debug("Unknown sensor type %s" % sensor_type)
            ret = []
        return ret
                                                                                        ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_help.py                             0000664 0000000 0000000 00000023605 13066703446 023155  0                                                                                                    ustar                                                                                                                                                                                                                                                          # -*- coding: utf-8 -*-
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""
Help plugin.

Just a stupid plugin to display the help screen.
"""

from glances import __version__, psutil_version
from glances.plugins.glances_plugin import GlancesPlugin


class Plugin(GlancesPlugin):

    """Glances help plugin."""

    def __init__(self, args=None, config=None):
        """Init the plugin."""
        super(Plugin, self).__init__(args=args)

        # Set the config instance
        self.config = config

        # We want to display the stat in the curse interface
        self.display_curse = True

        # init data dictionary
        self.view_data = {}
        self.generate_view_data()

    def reset(self):
        """No stats. It is just a plugin to display the help."""
        pass

    def update(self):
        """No stats. It is just a plugin to display the help."""
        pass

    def generate_view_data(self):
        self.view_data['version'] = '{} {}'.format('Glances', __version__)
        self.view_data['psutil_version'] = ' with PSutil {}'.format(psutil_version)

        try:
            self.view_data['configuration_file'] = 'Configuration file: {}'.format(self.config.loaded_config_file)
        except AttributeError:
            pass

        msg_col = ' {0:1}  {1:35}'
        msg_col2 = '   {0:1}  {1:35}'
        self.view_data['sort_auto'] = msg_col.format('a', 'Sort processes automatically')
        self.view_data['sort_network'] = msg_col2.format('b', 'Bytes or bits for network I/O')
        self.view_data['sort_cpu'] = msg_col.format('c', 'Sort processes by CPU%')
        self.view_data['show_hide_alert'] = msg_col2.format('l', 'Show/hide alert logs')
        self.view_data['sort_mem'] = msg_col.format('m', 'Sort processes by MEM%')
        self.view_data['sort_user'] = msg_col.format('u', 'Sort processes by USER')
        self.view_data['delete_warning_alerts'] = msg_col2.format('w', 'Delete warning alerts')
        self.view_data['sort_proc'] = msg_col.format('p', 'Sort processes by name')
        self.view_data['delete_warning_critical_alerts'] = msg_col2.format('x', 'Delete warning and critical alerts')
        self.view_data['sort_io'] = msg_col.format('i', 'Sort processes by I/O rate')
        self.view_data['percpu'] = msg_col2.format('1', 'Global CPU or per-CPU stats')
        self.view_data['sort_cpu_times'] = msg_col.format('t', 'Sort processes by TIME')
        self.view_data['show_hide_help'] = msg_col2.format('h', 'Show/hide this help screen')
        self.view_data['show_hide_diskio'] = msg_col.format('d', 'Show/hide disk I/O stats')
        self.view_data['show_hide_irq'] = msg_col2.format('Q', 'Show/hide IRQ stats')
        self.view_data['view_network_io_combination'] = msg_col2.format('T', 'View network I/O as combination')
        self.view_data['show_hide_filesystem'] = msg_col.format('f', 'Show/hide filesystem stats')
        self.view_data['view_cumulative_network'] = msg_col2.format('U', 'View cumulative network I/O')
        self.view_data['show_hide_network'] = msg_col.format('n', 'Show/hide network stats')
        self.view_data['show_hide_filesytem_freespace'] = msg_col2.format('F', 'Show filesystem free space')
        self.view_data['show_hide_sensors'] = msg_col.format('s', 'Show/hide sensors stats')
        self.view_data['generate_graphs'] = msg_col2.format('g', 'Generate graphs for current history')
        self.view_data['show_hide_left_sidebar'] = msg_col.format('2', 'Show/hide left sidebar')
        self.view_data['reset_history'] = msg_col2.format('r', 'Reset history')
        self.view_data['enable_disable_process_stats'] = msg_col.format('z', 'Enable/disable processes stats')
        self.view_data['quit'] = msg_col2.format('q', 'Quit (Esc and Ctrl-C also work)')
        self.view_data['enable_disable_top_extends_stats'] = msg_col.format('e', 'Enable/disable top extended stats')
        self.view_data['enable_disable_short_processname'] = msg_col.format('/', 'Enable/disable short processes name')
        self.view_data['enable_disable_irix'] = msg_col.format('0', 'Enable/disable Irix process CPU')
        self.view_data['enable_disable_docker'] = msg_col2.format('D', 'Enable/disable Docker stats')
        self.view_data['enable_disable_quick_look'] = msg_col.format('3', 'Enable/disable quick look plugin')
        self.view_data['show_hide_ip'] = msg_col2.format('I', 'Show/hide IP module')
        self.view_data['diskio_iops'] = msg_col2.format('B', 'Count/rate for Disk I/O')
        self.view_data['show_hide_top_menu'] = msg_col2.format('5', 'Show/hide top menu (QL, CPU, MEM, SWAP and LOAD)')
        self.view_data['enable_disable_gpu'] = msg_col.format('G', 'Enable/disable gpu plugin')
        self.view_data['enable_disable_mean_gpu'] = msg_col2.format('6', 'Enable/disable mean gpu')
        self.view_data['edit_pattern_filter'] = 'ENTER: Edit the process filter pattern'

    def get_view_data(self, args=None):
        return self.view_data

    def msg_curse(self, args=None):
        """Return the list to display in the curse interface."""
        # Init the return message
        ret = []

        # Build the string message
        # Header
        ret.append(self.curse_add_line(self.view_data['version'], 'TITLE'))
        ret.append(self.curse_add_line(self.view_data['psutil_version']))
        ret.append(self.curse_new_line())

        # Configuration file path
        if 'configuration_file' in self.view_data:
            ret.append(self.curse_new_line())
            ret.append(self.curse_add_line(self.view_data['configuration_file']))
            ret.append(self.curse_new_line())

        # Keys
        ret.append(self.curse_new_line())
        ret.append(self.curse_add_line(self.view_data['sort_auto']))
        ret.append(self.curse_add_line(self.view_data['sort_network']))
        ret.append(self.curse_new_line())
        ret.append(self.curse_add_line(self.view_data['sort_cpu']))
        ret.append(self.curse_add_line(self.view_data['show_hide_alert']))
        ret.append(self.curse_new_line())

        ret.append(self.curse_add_line(self.view_data['sort_mem']))
        ret.append(self.curse_add_line(self.view_data['delete_warning_alerts']))
        ret.append(self.curse_new_line())
        ret.append(self.curse_add_line(self.view_data['sort_user']))
        ret.append(self.curse_add_line(self.view_data['delete_warning_critical_alerts']))
        ret.append(self.curse_new_line())
        ret.append(self.curse_add_line(self.view_data['sort_proc']))
        ret.append(self.curse_add_line(self.view_data['percpu']))
        ret.append(self.curse_new_line())
        ret.append(self.curse_add_line(self.view_data['sort_io']))
        ret.append(self.curse_add_line(self.view_data['show_hide_ip']))
        ret.append(self.curse_new_line())
        ret.append(self.curse_add_line(self.view_data['sort_cpu_times']))
        ret.append(self.curse_add_line(self.view_data['enable_disable_docker']))
        ret.append(self.curse_new_line())
        ret.append(self.curse_add_line(self.view_data['show_hide_diskio']))
        ret.append(self.curse_add_line(self.view_data['view_network_io_combination']))
        ret.append(self.curse_new_line())
        ret.append(self.curse_add_line(self.view_data['show_hide_filesystem']))
        ret.append(self.curse_add_line(self.view_data['view_cumulative_network']))
        ret.append(self.curse_new_line())
        ret.append(self.curse_add_line(self.view_data['show_hide_network']))
        ret.append(self.curse_add_line(self.view_data['show_hide_filesytem_freespace']))
        ret.append(self.curse_new_line())
        ret.append(self.curse_add_line(self.view_data['show_hide_sensors']))
        ret.append(self.curse_add_line(self.view_data['generate_graphs']))
        ret.append(self.curse_new_line())
        ret.append(self.curse_add_line(self.view_data['show_hide_left_sidebar']))
        ret.append(self.curse_add_line(self.view_data['reset_history']))
        ret.append(self.curse_new_line())
        ret.append(self.curse_add_line(self.view_data['enable_disable_process_stats']))
        ret.append(self.curse_add_line(self.view_data['show_hide_help']))
        ret.append(self.curse_new_line())
        ret.append(self.curse_add_line(self.view_data['enable_disable_quick_look']))
        ret.append(self.curse_add_line(self.view_data['diskio_iops']))
        ret.append(self.curse_new_line())
        ret.append(self.curse_add_line(self.view_data['enable_disable_top_extends_stats']))
        ret.append(self.curse_add_line(self.view_data['show_hide_top_menu']))
        ret.append(self.curse_new_line())
        ret.append(self.curse_add_line(self.view_data['enable_disable_short_processname']))
        ret.append(self.curse_add_line(self.view_data['show_hide_irq']))
        ret.append(self.curse_new_line())
        ret.append(self.curse_add_line(self.view_data['enable_disable_gpu']))
        ret.append(self.curse_add_line(self.view_data['enable_disable_mean_gpu']))
        ret.append(self.curse_new_line())
        ret.append(self.curse_add_line(self.view_data['enable_disable_irix']))
        ret.append(self.curse_add_line(self.view_data['quit']))
        ret.append(self.curse_new_line())

        ret.append(self.curse_new_line())

        ret.append(self.curse_add_line(self.view_data['edit_pattern_filter']))

        # Return the message with decoration
        return ret
                                                                                                                           ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_memswap.pyc                         0000664 0000000 0000000 00000010514 13070471670 024030  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   s�   d  Z  d d l m Z d d l m Z d d l Z i i d d 6d d 6d	 6i d
 d 6d d
   alloc_units   1.3.6.1.2.1.25.2.3.1.5t   sizes   1.3.6.1.2.1.25.2.3.1.6t   usedt   windowst   percentt   names   Swap memory usaget   descriptions   #00FF00t   colort   %t   y_unitt   Pluginc           B   sS   e  Z d  Z d d � Z d �  Z e j e j d �  � � Z	 d �  Z
 d d � Z RS(   s5   Glances swap memory plugin.

    stats is a dict
    c         C   s6   t  t |  � j d | d t � t |  _ |  j �  d S(   s   Init the plugin.t   argst   items_history_listN(   t   superR   t   __init__R   t   Truet
 t	 |  j d t
 � } Wn t k
 r� |  j  �  qvXx�| D]� } | d k r� t | | d
 t	 d � |  _ |  j d d k r�|  j  �  |  j SxK t |  j � D]: } |  j | d k r�t
   t   sint   soutt   snmpR	   t   snmp_oidt   bulks   Virtual MemoryR   R   id   R   t    i   (   R   t   input_methodt   psutilt   swap_memoryt   hasattrt   getattrR   t   short_system_namet   get_stats_snmpR   R   t   KeyErrort   intt   floatR    (   R   t   sm_statst   swapt   fs_statt   fst   key(    (    sI   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_memswap.pyt   updateC   sH    

 
%4c         C   sE   t  t |  � j �  |  j |  j d d |  j d �|  j d d <d S(   s   Update stats views.R   t   maximumR   t
   decorationN(   R   R   t   update_viewst
 � � } | j |  j | � � | j |  j �  � d j d � } | j |  j | � � d	 j |  j |  j  d � � } | j |  j | |  j d
   id   s   {:8}s   total:s   {:>6}R   s   used:R   R/   t   optionR2   s   free:R   (   R   t
   is_disablet   formatt   appendt   curse_add_linet   curse_new_linet	   auto_unitt	   get_views(   R   R   t   rett   msg(    (    sI   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_memswap.pyt	   msg_curse�   s0    N(   t   __name__t
   __module__t   __doc__t   NoneR   R   R   t   _check_decoratort   _log_result_decoratorR0   R3   RB   (    (    (    sI   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_memswap.pyR   .   s   
	E		(	   RE   t   glances.compatR    t   glances.plugins.glances_pluginR   R"   R   R   R   (    (    (    sI   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_memswap.pyt   <module>   s   


#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

from glances import psutil_version_info
from glances.plugins.glances_plugin import GlancesPlugin


class Plugin(GlancesPlugin):
    """Get the psutil version for client/server purposes.

    stats is a tuple
    """

    def __init__(self, args=None):
        """Init the plugin."""
        super(Plugin, self).__init__(args=args)

        self.reset()

    def reset(self):
        """Reset/init the stats."""
        self.stats = None

    @GlancesPlugin._check_decorator
    @GlancesPlugin._log_result_decorator
    def update(self):
        """Update the stats."""
        # Reset stats
        self.reset()

        # Return PsUtil version as a tuple
        if self.input_method == 'local':
            # PsUtil version only available in local
            try:
                self.stats = psutil_version_info
            except NameError:
                pass
        else:
            pass

        return self.stats
                                                                                                                                                                                                                                                                                                                                                                          ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_diskio.py                           0000664 0000000 0000000 00000023146 13066703446 023507  0                                                                                                    ustar                                                                                                                                                                                                                                                          # -*- coding: utf-8 -*-
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""Disk I/O plugin."""

import operator

from glances.timer import getTimeSinceLastUpdate
from glances.plugins.glances_plugin import GlancesPlugin

import psutil


# Define the history items list
# All items in this list will be historised if the --enable-history tag is set
# 'color' define the graph color in #RGB format
items_history_list = [{'name': 'read_bytes',
                       'description': 'Bytes read per second',
                       'color': '#00FF00',
                       'y_unit': 'B/s'},
                      {'name': 'write_bytes',
                       'description': 'Bytes write per second',
                       'color': '#FF0000',
                       'y_unit': 'B/s'}]


class Plugin(GlancesPlugin):

    """Glances disks I/O plugin.

    stats is a list
    """

    def __init__(self, args=None):
        """Init the plugin."""
        super(Plugin, self).__init__(args=args, items_history_list=items_history_list)

        # We want to display the stat in the curse interface
        self.display_curse = True

        # Init the stats
        self.reset()

    def get_key(self):
        """Return the key of the list."""
        return 'disk_name'

    def reset(self):
        """Reset/init the stats."""
        self.stats = []

    @GlancesPlugin._check_decorator
    @GlancesPlugin._log_result_decorator
    def update(self):
        """Update disk I/O stats using the input method."""
        # Reset stats
        self.reset()

        if self.input_method == 'local':
            # Update stats using the standard system lib
            # Grab the stat using the PsUtil disk_io_counters method
            # read_count: number of reads
            # write_count: number of writes
            # read_bytes: number of bytes read
            # write_bytes: number of bytes written
            # read_time: time spent reading from disk (in milliseconds)
            # write_time: time spent writing to disk (in milliseconds)
            try:
                diskiocounters = psutil.disk_io_counters(perdisk=True)
            except Exception:
                return self.stats

            # Previous disk IO stats are stored in the diskio_old variable
            if not hasattr(self, 'diskio_old'):
                # First call, we init the diskio_old var
                try:
                    self.diskio_old = diskiocounters
                except (IOError, UnboundLocalError):
                    pass
            else:
                # By storing time data we enable Rx/s and Tx/s calculations in the
                # XML/RPC API, which would otherwise be overly difficult work
                # for users of the API
                time_since_update = getTimeSinceLastUpdate('disk')

                diskio_new = diskiocounters
                for disk in diskio_new:
                    # By default, RamFS is not displayed (issue #714)
                    if self.args is not None and not self.args.diskio_show_ramfs and disk.startswith('ram'):
                        continue

                    # Do not take hide disk into account
                    if self.is_hide(disk):
                        continue

                    # Compute count and bit rate
                    try:
                        read_count = (diskio_new[disk].read_count -
                                      self.diskio_old[disk].read_count)
                        write_count = (diskio_new[disk].write_count -
                                       self.diskio_old[disk].write_count)
                        read_bytes = (diskio_new[disk].read_bytes -
                                      self.diskio_old[disk].read_bytes)
                        write_bytes = (diskio_new[disk].write_bytes -
                                       self.diskio_old[disk].write_bytes)
                        diskstat = {
                            'time_since_update': time_since_update,
                            'disk_name': disk,
                            'read_count': read_count,
                            'write_count': write_count,
                            'read_bytes': read_bytes,
                            'write_bytes': write_bytes}
                        # Add alias if exist (define in the configuration file)
                        if self.has_alias(disk) is not None:
                            diskstat['alias'] = self.has_alias(disk)
                    except KeyError:
                        continue
                    else:
                        diskstat['key'] = self.get_key()
                        self.stats.append(diskstat)

                # Save stats to compute next bitrate
                self.diskio_old = diskio_new
        elif self.input_method == 'snmp':
            # Update stats using SNMP
            # No standard way for the moment...
            pass

        return self.stats

    def update_views(self):
        """Update stats views."""
        # Call the father's method
        super(Plugin, self).update_views()

        # Add specifics informations
        # Alert
        for i in self.stats:
            disk_real_name = i['disk_name']
            self.views[i[self.get_key()]]['read_bytes']['decoration'] = self.get_alert(int(i['read_bytes'] // i['time_since_update']),
                                                                                       header=disk_real_name + '_rx')
            self.views[i[self.get_key()]]['write_bytes']['decoration'] = self.get_alert(int(i['write_bytes'] // i['time_since_update']),
                                                                                        header=disk_real_name + '_tx')

    def msg_curse(self, args=None):
        """Return the dict to display in the curse interface."""
        # Init the return message
        ret = []

        # Only process if stats exist and display plugin enable...
        if not self.stats or self.is_disable():
            return ret

        # Build the string message
        # Header
        msg = '{:9}'.format('DISK I/O')
        ret.append(self.curse_add_line(msg, "TITLE"))
        if args.diskio_iops:
            msg = '{:>7}'.format('IOR/s')
            ret.append(self.curse_add_line(msg))
            msg = '{:>7}'.format('IOW/s')
            ret.append(self.curse_add_line(msg))
        else:
            msg = '{:>7}'.format('R/s')
            ret.append(self.curse_add_line(msg))
            msg = '{:>7}'.format('W/s')
            ret.append(self.curse_add_line(msg))
        # Disk list (sorted by name)
        for i in sorted(self.stats, key=operator.itemgetter(self.get_key())):
            # Is there an alias for the disk name ?
            disk_real_name = i['disk_name']
            disk_name = self.has_alias(i['disk_name'])
            if disk_name is None:
                disk_name = disk_real_name
            # New line
            ret.append(self.curse_new_line())
            if len(disk_name) > 9:
                # Cut disk name if it is too long
                disk_name = '_' + disk_name[-8:]
            msg = '{:9}'.format(disk_name)
            ret.append(self.curse_add_line(msg))
            if args.diskio_iops:
                # count
                txps = self.auto_unit(
                    int(i['read_count'] // i['time_since_update']))
                rxps = self.auto_unit(
                    int(i['write_count'] // i['time_since_update']))
                msg = '{:>7}'.format(txps)
                ret.append(self.curse_add_line(msg,
                                               self.get_views(item=i[self.get_key()],
                                                              key='read_count',
                                                              option='decoration')))
                msg = '{:>7}'.format(rxps)
                ret.append(self.curse_add_line(msg,
                                               self.get_views(item=i[self.get_key()],
                                                              key='write_count',
                                                              option='decoration')))
            else:
                # Bitrate
                txps = self.auto_unit(
                    int(i['read_bytes'] // i['time_since_update']))
                rxps = self.auto_unit(
                    int(i['write_bytes'] // i['time_since_update']))
                msg = '{:>7}'.format(txps)
                ret.append(self.curse_add_line(msg,
                                               self.get_views(item=i[self.get_key()],
                                                              key='read_bytes',
                                                              option='decoration')))
                msg = '{:>7}'.format(rxps)
                ret.append(self.curse_add_line(msg,
                                               self.get_views(item=i[self.get_key()],
                                                              key='write_bytes',
                                                              option='decoration')))

        return ret
                                                                                                                                                                                                                                                                                                                                                                                                                          ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_wifi.pyc                            0000664 0000000 0000000 00000012217 13070471670 023317  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   s�   d  Z  d d l Z d d l m Z d d l m Z d d l Z y$ d d l m Z d d l	 m
 Z
 Wn$ e k
 r� e j d � e
   s   Wifi plugin.i����N(   t   logger(   t
 d �  Z d �  Z d d d � Z
    Get stats of the current Wifi hotspots.
    c         C   s0   t  t |  � j d | � t |  _ |  j �  d S(   s   Init the plugin.t   argsN(   t   superR   t   __init__t   Truet

        :returns: string -- SSID is the dict key
        t   ssid(    (   R   (    (    sF   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_wifi.pyt   get_key8   s    c         C   s

        :returns: None
        N(   t   stats(   R   (    (    sF   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_wifi.pyR
   ?   s    c         C   sZ  |  j  �  t s |  j S|  j d k rAy t j d t � } Wn t k
 rS |  j SXx� | D]� } |  j | � rv q[ n  y t	 j
 | � } Wn9 t k
 r� q[ t k
 r� } t
 k rSn  |  j S(   s�   Update Wifi stats using the input method.

        Stats is a list of dict (one dict per hotspot)

        :returns: list -- Stats is a list of dict (hotspot)
        t   localt   pernics,   WIFI plugin: Can not grab cellule stats ({})t   keyR   t   signalt   qualityt	   encryptedt   encryption_typet   snmpN(   R
   t   wifi_tagR   t   input_methodt   psutilt   net_io_countersR   t   UnicodeDecodeErrort   is_hideR   t   allR   t	   ExceptionR    t   debugt   formatR
   wifi_cellst   et	   wifi_cellt   hotspot(    (    sF   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_wifi.pyt   updateF   s<    





c         C   s�   d } yy | |  j  d d |  j �k r0 d } nN | |  j  d d |  j �k rW d } n' | |  j  d d |  j �k r~ d } n  Wn t k
 r� d	 } n X| S(
   s�   Overwrite the default get_alert method.
        Alert is on signal quality where lower is better...

        :returns: string -- Signal alert
        t   OKt   criticalt	   stat_namet   CRITICALt   warningt   WARNINGt   carefult   CAREFULt   DEFAULT(   t	   get_limitt   plugin_namet   KeyError(   R   t   valuet   ret(    (    sF   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_wifi.pyt	   get_alert�   s    		
c         C   s�   t  t |  � j �  xu |  j D]j } |  j | d � |  j | |  j �  d d <|  j | |  j �  d d |  j | |  j �  d d <q Wd S(   s   Update stats views.R   t
   decorationR   N(   R   R   t   update_viewsR   R8   t   viewsR
 t j	 |  j
 �  � �D]} | d d k r� q� n  | j |  j �  � | d } | d
 �  d
 d d d � � � q� W| S(   s2   Return the dict to display in the curse interface.i   i   i   s
   {:{width}}t   WIFIt   widtht   TITLEs   {:>7}t   dBmR   R   t    R   s    {}R   t   _i   R   t   itemt   optionR9   N(   R   t   disable_wifiR   R!   R    R"   t   curse_add_linet   sortedt   operatort
   itemgetterR

N(   t   __name__t
   __module__t   __doc__R!   R   R
   R   t   _check_decoratort   _log_result_decoratorR)   R8   R:   RQ   (    (    (    sF   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_wifi.pyR   (   s   
		<		(   RT   RH   t   glances.loggerR    t   glances.plugins.glances_pluginR   R   t	   wifi.scanR   t   wifi.exceptionsR   t   ImportErrorR   t   FalseR   R   R   (    (    (    sF   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_wifi.pyt   <module>   s   
                                                                                                                                                                                                                                                                                                                                                                                 ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_ports.pyc                           0000664 0000000 0000000 00000021076 13070471670 023533  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   s�   d  Z  d d l Z d d l Z d d l Z d d l Z d d l Z d d l m Z d d l m	 Z	 d d l
 m Z m Z d d l
 �  �  YZ d e j f d �  �  YZ d S(
 d � Z d	 d � Z d �  Z
   s   Glances ports scanner plugin.c         C   sn   t  t |  � j d | � | |  _ | |  _ t |  _ t d | d | � j �  |  _	 t
 d � |  _ d |  _
   R   t   exit(   R   (    (    sG   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_ports.pyR   :   s    c         C   s
 |  j � d k r� t |  j d d � |  _ q� t d � |  _ q� n  |  j S(   s   Update the ports list.t   locali    t   refreshN(   t   input_methodR   R   t   Falset   isAliveR   t   finishedt
   isinstancet   floatt   int(   R   t   portt   headert   log(    (    sG   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_ports.pyt	   get_alert`   s    c         C   sR  g  } |  j  s | j r | Sx|  j  D]} | d d
 j | d � } | j |  j | � � d j | � } | j |  j | |  j	 | � � � | j |  j
 �  � q' Wy | j �  Wn t k
 rMn X| S(   s2   Return the dict to display in the curse interface.t   hostR   R#   t   Scanningt   Openi    t   Timeouts	   {0:.0f}msg     @�@s	   {:14.14} t   descriptions   {:>8}N(
   IndexError(   R   R   t   rett   pR#   t   msg(    (    sG   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_ports.pyt	   msg_cursen   s.    		#		"
   _port_scant   timet   sleep(   R   R   R=   (    (    sG   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_ports.pyt   _port_scan_all�   s    
   __module__t   __doc__R   R   R   R   R   t   _log_result_decoratorR!   R   R/   R?   RC   (    (    (    sG   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_ports.pyR   $   s   		%R   c           B   sz   e  Z d  Z d �  Z d �  Z e d �  � Z e j d �  � Z d d � Z	 d �  Z
 d �  Z d �  Z d	 �  Z
 �  Z RS(   sL   
    Specific thread for the port scanner.

    stats is a list of dict
    c         C   sN   t  j d j | � � t t |  � j �  t j �  |  _ | |  _	 d |  _
 d S(   s   Init the classs-   ports plugin - Create thread for scan list {}t   portsN(   R   t   debugR6   R
   R   R   t	   threadingt   Eventt   _stoppert   _statst   plugin_name(   R   R   (    (    sG   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_ports.pyR   �   s
    	c         C   sB   x; |  j  D]0 } |  j | � |  j �  r- Pn  t j d � q
 Wd S(   sd   Function called to grab stats.
        Infinite loop, should be stopped by calling the stop() methodi   N(   RM   R@   t   stoppedRA   RB   (   R   R=   (    (    sG   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_ports.pyt   run�   s
    
 rM } t j d j |  j | | � � n X| S(   s   Convert hostname to IP addresss(   {}: Cannot convert {} to IP address ({})(   t   sockett
 k r� | j
 �  | d <n
 t | d <Wn6 t k
 r� } t
   subprocesst
   check_callR   t   getR   RY   R   RI   R6   RN   (   R   R,   R<   t   cmdt   fnullt   counterR\   (    (    sG   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_ports.pyRU   �   s    +	!'c         C   s  d } y- t j | d � t j t j t j � } Wn, t k
 ra } t j d j |  j	 � � n X|  j
 | d � } t �  } z� y# | j | t
 r� } t j d j |  j	 | | � � n* X| d k r� | j �  | d <n
 t | d <Wd | j �  X| S(	   s>   Scan the (TCP) port structure (dict) and update the status keyRS   s(   {}: Error while creating scanning socketR0   R,   s%   {}: Error while scanning port {} ({})i    R#   N(   R   RW   t   setdefaulttimeoutt   AF_INETt   SOCK_STREAMRY   R   RI   R6   RN   R]   R   t
   connect_exR+   Ri   R   t   close(   R   R,   R<   t   _socketR\   R[   Rl   (    (    sG   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_ports.pyRV   �   s$    	 ##N(   RD   RE   RF   R   RP   t   propertyR   t   setterR   R   RO   R@   R]   RU   RV   (    (    (    sG   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_ports.pyR   �   s   							(   RF   Re   Rg   RJ   RW   RA   t   glances.globalsR    t   glances.ports_listR   t
&��Xc           @   s_   d  Z  d d l m Z m Z d d l m Z d d l Z i d d 6Z d e f d �  �  YZ d S(	   s   Uptime plugin.i����(   t   datetimet	   timedelta(   t
 d d � Z RS(   s7   Glances uptime plugin.

    stats is date (string)
    c         C   s[   t  t |  � j d | � t |  _ d |  _ t j �  t j t	 j
 �  � |  _ |  j �  d S(   s   Init the plugin.t   argst   rightN(
    		"c         C   s

        Export uptime in seconds.
        t   seconds(   R   R   (   R   (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_uptime.pyt
   get_export9   s    c         C   s�   |  j  �  |  j d k r] t j �  t j t j �  � |  _ t |  j � j	 d � d |  _
 nb |  j d k r� |  j d t � d } y& t t
 Wq� t k
 r� q� Xn  |  j
 S(	   s*   Update uptime stat using the input method.t   localt   .i    t   snmpt   snmp_oidR   R   id   (   R   t   input_methodR    R   R
""&
   Uptime: {}(   t   curse_add_linet   formatR   (   R   R   (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_uptime.pyt	   msg_curseY   s    N(   t   __name__t
   __module__t   __doc__t   NoneR   R   R   R   t   _check_decoratort   _log_result_decoratorR    R#   (    (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_uptime.pyR       s   		(   R&   R    R   t   glances.plugins.glances_pluginR   R   R   R   (    (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_uptime.pyt   <module>   s
   
&��Xc           @   s   d  S(   N(    (    (    (    sB   /usr/local/lib/python2.7/dist-packages/glances/plugins/__init__.pyt   <module>   s                                                                                                                                                                                                                                                                                                                                                                           ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_raid.py                             0000664 0000000 0000000 00000013123 13066703446 023136  0                                                                                                    ustar                                                                                                                                                                                                                                                          # -*- coding: utf-8 -*-
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""RAID plugin."""

from glances.compat import iterkeys
from glances.logger import logger
from glances.plugins.glances_plugin import GlancesPlugin

# pymdstat only available on GNU/Linux OS
try:
    from pymdstat import MdStat
except ImportError:
    logger.debug("pymdstat library not found. Glances cannot grab RAID info.")


class Plugin(GlancesPlugin):

    """Glances RAID plugin.

    stats is a dict (see pymdstat documentation)
    """

    def __init__(self, args=None):
        """Init the plugin."""
        super(Plugin, self).__init__(args=args)

        # We want to display the stat in the curse interface
        self.display_curse = True

        # Init the stats
        self.reset()

    def reset(self):
        """Reset/init the stats."""
        self.stats = {}

    @GlancesPlugin._check_decorator
    @GlancesPlugin._log_result_decorator
    def update(self):
        """Update RAID stats using the input method."""
        # Reset stats
        self.reset()

        if self.input_method == 'local':
            # Update stats using the PyMDstat lib (https://github.com/nicolargo/pymdstat)
            try:
                mds = MdStat()
                self.stats = mds.get_stats()['arrays']
            except Exception as e:
                logger.debug("Can not grab RAID stats (%s)" % e)
                return self.stats

        elif self.input_method == 'snmp':
            # Update stats using SNMP
            # No standard way for the moment...
            pass

        return self.stats

    def msg_curse(self, args=None):
        """Return the dict to display in the curse interface."""
        # Init the return message
        ret = []

        # Only process if stats exist...
        if not self.stats:
            return ret

        # Build the string message
        # Header
        msg = '{:11}'.format('RAID disks')
        ret.append(self.curse_add_line(msg, "TITLE"))
        msg = '{:>6}'.format('Used')
        ret.append(self.curse_add_line(msg))
        msg = '{:>6}'.format('Avail')
        ret.append(self.curse_add_line(msg))
        # Data
        arrays = sorted(iterkeys(self.stats))
        for array in arrays:
            # New line
            ret.append(self.curse_new_line())
            # Display the current status
            status = self.raid_alert(self.stats[array]['status'], self.stats[array]['used'], self.stats[array]['available'])
            # Data: RAID type name | disk used | disk available
            array_type = self.stats[array]['type'].upper() if self.stats[array]['type'] is not None else 'UNKNOWN'
            msg = '{:<5}{:>6}'.format(array_type, array)
            ret.append(self.curse_add_line(msg))
            if self.stats[array]['status'] == 'active':
                msg = '{:>6}'.format(self.stats[array]['used'])
                ret.append(self.curse_add_line(msg, status))
                msg = '{:>6}'.format(self.stats[array]['available'])
                ret.append(self.curse_add_line(msg, status))
            elif self.stats[array]['status'] == 'inactive':
                ret.append(self.curse_new_line())
                msg = '└─ Status {}'.format(self.stats[array]['status'])
                ret.append(self.curse_add_line(msg, status))
                components = sorted(iterkeys(self.stats[array]['components']))
                for i, component in enumerate(components):
                    if i == len(components) - 1:
                        tree_char = '└─'
                    else:
                        tree_char = '├─'
                    ret.append(self.curse_new_line())
                    msg = '   {} disk {}: '.format(tree_char, self.stats[array]['components'][component])
                    ret.append(self.curse_add_line(msg))
                    msg = '{}'.format(component)
                    ret.append(self.curse_add_line(msg))
            if self.stats[array]['used'] < self.stats[array]['available']:
                # Display current array configuration
                ret.append(self.curse_new_line())
                msg = '└─ Degraded mode'
                ret.append(self.curse_add_line(msg, status))
                if len(self.stats[array]['config']) < 17:
                    ret.append(self.curse_new_line())
                    msg = '   └─ {}'.format(self.stats[array]['config'].replace('_', 'A'))
                    ret.append(self.curse_add_line(msg))

        return ret

    def raid_alert(self, status, used, available):
        """RAID alert messages.

        [available/used] means that ideally the array may have _available_
        devices however, _used_ devices are in use.
        Obviously when used >= available then things are good.
        """
        if status == 'inactive':
            return 'CRITICAL'
        if used is None or available is None:
            return 'DEFAULT'
        elif used < available:
            return 'WARNING'
        return 'OK'
                                                                                                                                                                                                                                                                                                                                                                                                                                             ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_fs.pyc                              0000664 0000000 0000000 00000013562 13070471670 022775  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   s�   d  Z  d d l Z d d l m Z d d l Z i i d d 6d d 6d d	 6d
 d 6d d
   alloc_units   1.3.6.1.2.1.25.2.3.1.5s   1.3.6.1.2.1.25.2.3.1.6t   windowss   1.3.6.1.4.1.789.1.5.4.1.2s   1.3.6.1.4.1.789.1.5.4.1.10s   1.3.6.1.4.1.789.1.5.4.1.3s   1.3.6.1.4.1.789.1.5.4.1.4s   1.3.6.1.4.1.789.1.5.4.1.6t   netappt   esxit   names   File system usage in percentt   descriptions   #00FF00t   colort   Pluginc           B   s_   e  Z d  Z d d � Z d �  Z d �  Z e j e j	 d �  � � Z
 d �  Z d d d � Z RS(   s5   Glances file system plugin.

    stats is a list
    c         C   s6   t  t |  � j d | d t � t |  _ |  j �  d S(   s   Init the plugin.t   argst   items_history_listN(   t   superR   t   __init__R   t   Truet
      C   s}  |  j  �  |  j d k r�y t j d t � } Wn t k
 rF |  j SXxt |  j d � D]c } yE | g  t j d t � D]$ } | j	 j
 | � d k rv | ^ qv 7} WqW t k
 r� |  j SXqW Wx�| D]� } |  j | j � r� q� n  y t j
 rq� n Xi | j d 6| j	 d 6| j d 6| j d 6| j d	 6| j d
 6| j d 6|  j �  d 6} |  j j | � q� Wn�|  j d
 r�|  j d t d d t � } n X|  j d k r�x| D]� } | d k s�| d k s�| d k r(q�n  t | | d � t | | d � } t | | d	 � t | | d � } t | d | � }	 i d d 6| j d � d d 6| d 6| d	 6|	 d 6|  j �  d 6} |  j j | � q�Wqvx� | D]� } i | | d d 6| d 6t | | d � d d 6t | | d	 � d d	 6t | | d � d 6|  j �  d 6} |  j j | � q�Wn  |  j S(   s+   Update the FS stats using the input method.t   localt   allt   allowi    R   t   fs_typeR   R   R   t   freeR   t   keyt   snmpt   snmp_oidt   bulkR   R   R
   s   Virtual Memorys   Physical Memorys   Real MemoryR   id   t    t    i   (   R   R
   (   R   t   input_methodt   psutilt   disk_partitionst   Falset   UnicodeDecodeErrorR   t   get_conf_valueR   t   fstypet   findt   is_hidet
   mountpointt
   disk_usaget   OSErrort   devicet   totalR   R   R   R   t   appendt   get_stats_snmpR    t   short_system_namet   KeyErrort   intt   floatt	   partition(
   R   t   fs_statR*   t   ft   fst   fs_usaget
   fs_currentR   R   R   (    (    sD   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_fs.pyt   update\   sx    








   decorationN(   R   R   t   update_viewsR   t	   get_alertt   viewsR   (   R   t   i(    (    sD   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_fs.pyRB   �   s    c         C   s�  g  } |  j  s |  j �  r  | S| d k	 rE | d k rE | d } n d } d j d d | �} | j |  j | d � � | j r� d j d	 � } n d j d
 � } | j |  j | � � d j d � } | j |  j | � � x�t |  j  d t j	 |  j
 �  � �D]�} | j |  j �  � | d
 | d } d j | d | �} | j |  j | � � | j r>d j |  j | d � � } n d j |  j | d � � } | j |  j | |  j d | |  j
 �  d d d d � � � d j |  j | d � � } | j |  j | � � qW| S(   s2   Return the dict to display in the curse interface.i   i   i	   s
   {:{width}}s   FILE SYSt   widtht   TITLEs   {:>7}t   Freet   Usedt   TotalR   R   R"   t   noneR   i   t   /i����i   s    (t   )t   _R   R   t   itemt   optionRA   R   N(   R   t
   is_disablet   Nonet   formatR2   t   curse_add_linet
   itemgetterR   t   curse_new_linet   lent   splitt	   auto_unitt	   get_views(   R   R   t	   max_widtht   rett   fsname_max_widtht   msgRE   R   (    (    sD   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_fs.pyt	   msg_curse�   sD    
	(
   __module__t   __doc__RR   R   R   R   R    t   _check_decoratort   _log_result_decoratorR>   RB   Rb   (    (    (    sD   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_fs.pyR   C   s   
		\	(   Re   RW   t   glances.plugins.glances_pluginR    R%   R    R   R   (    (    (    sD   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_fs.pyt   <module>   s,   



#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""Process count plugin."""

from glances.processes import glances_processes
from glances.plugins.glances_plugin import GlancesPlugin

# Note: history items list is not compliant with process count
#       if a filter is applyed, the graph will show the filtered processes count


class Plugin(GlancesPlugin):

    """Glances process count plugin.

    stats is a list
    """

    def __init__(self, args=None):
        """Init the plugin."""
        super(Plugin, self).__init__(args=args)

        # We want to display the stat in the curse interface
        self.display_curse = True

        # Note: 'glances_processes' is already init in the glances_processes.py script

    def reset(self):
        """Reset/init the stats."""
        self.stats = {}

    def update(self):
        """Update processes stats using the input method."""
        # Reset stats
        self.reset()

        if self.input_method == 'local':
            # Update stats using the standard system lib
            # Here, update is call for processcount AND processlist
            glances_processes.update()

            # Return the processes count
            self.stats = glances_processes.getcount()
        elif self.input_method == 'snmp':
            # Update stats using SNMP
            # !!! TODO
            pass

        return self.stats

    def msg_curse(self, args=None):
        """Return the dict to display in the curse interface."""
        # Init the return message
        ret = []

        # Only process if stats exist and display plugin enable...
        if args.disable_process:
            msg = "PROCESSES DISABLED (press 'z' to display)"
            ret.append(self.curse_add_line(msg))
            return ret

        if not self.stats:
            return ret

        # Display the filter (if it exists)
        if glances_processes.process_filter is not None:
            msg = 'Processes filter:'
            ret.append(self.curse_add_line(msg, "TITLE"))
            msg = ' {} '.format(glances_processes.process_filter)
            if glances_processes.process_filter_key is not None:
                msg += 'on column {} '.format(glances_processes.process_filter_key)
            ret.append(self.curse_add_line(msg, "FILTER"))
            msg = '(\'ENTER\' to edit, \'E\' to reset)'
            ret.append(self.curse_add_line(msg))
            ret.append(self.curse_new_line())

        # Build the string message
        # Header
        msg = 'TASKS'
        ret.append(self.curse_add_line(msg, "TITLE"))
        # Compute processes
        other = self.stats['total']
        msg = '{:>4}'.format(self.stats['total'])
        ret.append(self.curse_add_line(msg))

        if 'thread' in self.stats:
            msg = ' ({} thr),'.format(self.stats['thread'])
            ret.append(self.curse_add_line(msg))

        if 'running' in self.stats:
            other -= self.stats['running']
            msg = ' {} run,'.format(self.stats['running'])
            ret.append(self.curse_add_line(msg))

        if 'sleeping' in self.stats:
            other -= self.stats['sleeping']
            msg = ' {} slp,'.format(self.stats['sleeping'])
            ret.append(self.curse_add_line(msg))

        msg = ' {} oth '.format(other)
        ret.append(self.curse_add_line(msg))

        # Display sort information
        if glances_processes.auto_sort:
            msg = 'sorted automatically'
            ret.append(self.curse_add_line(msg))
            msg = ' by {}'.format(glances_processes.sort_key)
            ret.append(self.curse_add_line(msg))
        else:
            msg = 'sorted by {}'.format(glances_processes.sort_key)
            ret.append(self.curse_add_line(msg))
        ret[-1]["msg"] += ", %s view" % ("tree" if glances_processes.is_tree_enabled() else "flat")
        # if args.disable_irix:
        #     ret[-1]["msg"] += " - IRIX off"

        # Return the message with decoration
        return ret
                                                                                                                                                                                                                                                                                                                                                                                                                               ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_batpercent.pyc                      0000664 0000000 0000000 00000007451 13070471670 024514  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   s�   d  Z  d d l Z d d l m Z d d l m Z e Z y d d l Z Wn$ e	 k
 rn e j
 d � e Z n Xe Z y e j
 r� e j
 d � e Z n Xd e f d �  �  YZ d	 e f d
 �  �  YZ d S(   s   Battery plugin.i����N(   t   logger(   t

    stats is a list
    c         C   s<   t  t |  � j d | � t �  |  _ t |  _ |  j �  d S(   s   Init the plugin.t   argsN(   t   superR   t   __init__t   GlancesGrabBatt   glancesgrabbatt   Falset
   A   s    c         C   sT   |  j  �  |  j d k r; |  j j �  |  j j �  |  _ n |  j d k rM n  |  j S(   s5   Update battery capacity stats using the input method.t   localt   snmp(   R
   t   input_methodR   t   updatet   getR   (   R   (    (    sL   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_batpercent.pyR   E   s    

   t   __name__t
   __module__t   __doc__t   NoneR   R
   R   t   _check_decoratort   _log_result_decoratorR   (    (    (    sL   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_batpercent.pyR   ,   s
   	R   c           B   s8   e  Z d  Z d �  Z d �  Z d �  Z e d �  � Z RS(   s.   Get batteries stats using the batinfo library.c         C   s@   g  |  _  t r! t j �  |  _ n t r3 t |  _ n	 d |  _ d S(   s   Init batteries stats.N(   t   bat_listt   batinfo_tagt   batinfot	   batteriest   batt
   psutil_tagt   psutilR   (   R   (    (    sL   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_batpercent.pyR   ]   s    	c         C   s�   t  r: |  j j �  i d d 6|  j d 6d d 6g |  _ n] t r� t |  j j �  d � r� i d d 6t |  j j �  j	 � d 6d d 6g |  _ n	 g  |  _ d S(   s   Update the stats.t   Batteryt   labelt   valuet   %t   unitt   percentN(
   R   R   R   t   battery_percentR   R   t   hasattrt   sensors_batteryt   intR$   (   R   (    (    sL   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_batpercent.pyR   h   s    
c         C   s   |  j  S(   s   Get the stats.(   R   (   R   (    (    sL   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_batpercent.pyR   }   s    c         C   s{   t  s |  j j r g  Sd } x@ |  j j D]2 } y | t | j � 7} Wq+ t k
 r\ g  SXq+ Wt | t |  j j � � S(   s   Get batteries capacity percent.i    (   R   R   t   statR(   t   capacityt
   ValueErrort   len(   R   t   bsumt   b(    (    sL   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_batpercent.pyR%   �   s    
   			(   R   R   t   glances.loggerR    t   glances.plugins.glances_pluginR   t   TrueR   R   t   ImportErrort   debugR   R   R'   t   AttributeErrorR   t   objectR   (    (    (    sL   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_batpercent.pyt   <module>   s"   

-                                                                                                                                                                                                                       ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_mem.pyc                             0000664 0000000 0000000 00000013267 13070471670 023145  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   s�   d  Z  d d l m Z d d l m Z d d l Z i i d d 6d d 6d	 d
 6d d 6d
   alloc_units   1.3.6.1.2.1.25.2.3.1.5t   sizes   1.3.6.1.2.1.25.2.3.1.6t   usedt   windowst   esxit   percentt   names   RAM memory usaget   descriptions   #00FF00t   colort   %t   y_unitt   Pluginc           B   sS   e  Z d  Z d d � Z d �  Z e j e j d �  � � Z	 d �  Z
 d d � Z RS(   s1   Glances' memory plugin.

    stats is a dict
    c         C   s6   t  t |  � j d | d t � t |  _ |  j �  d S(   s   Init the plugin.t   argst   items_history_listN(   t   superR   t   __init__R   t   Truet
 d d g D]. } t | | � rW t | | � |  j | <qW qW W|  j d |  j d <t |  j d	 � r� |  j d c |  j d	 7<n  t |  j d
 � r� |  j d c |  j d
 7<n  |  j d |  j d |  j d <n;|  j d
 � } Wn t k
 r{|  j  �  qUXx�| D]� } | d k r�t | | d � t | | d � |  j d <t | | d � t | | d � |  j d <t
 |  j d <|  j d |  j d |  j d <t
   R	   id   R   t    i   (   R   R

"
%57c         C   s�   t  t |  � j �  |  j |  j d d |  j d �|  j d d <x= d d d d g D]) } | |  j k rT t |  j | d	 <qT qT Wd
 S(   s   Update stats views.R   t   maximumR   t
   decorationR    R!   R   R   t   optionalN(   R   R   t   update_viewst
    .c      	   C   sH  g  } |  j  s |  j �  r  | Sd j d � } | j |  j | d � � d j |  j  d d � } | j |  j | � � d |  j  k rd j d	 � } | j |  j | d
 |  j d d d d
 � �� d
 |  j d d d d
 � �� n  | j |  j �  � d j d � } | j |  j | � � d
 |  j d d d d
 � �� d
 |  j d d d d
 � �� n  | j |  j �  � d j d � } | j |  j | � � d
 |  j d d d d
 � �� d
 |  j d d d d
 � �� n  | j |  j �  � d j d � } | j |  j | � � d
 |  j d d d d
 � �� d
 |  j d d d d
 � �� n  | S(   s2   Return the dict to display in the curse interface.s   {:5} t   MEMt   TITLEs   {:>7.1%}R   id   R    s     {:9}s   active:R9   R5   t   options   {:>7}s   {:6}s   total:R   R!   s	   inactive:s   used:R   R8   R   s   buffers:s   free:R   R   s   cached:(   R   t
   is_disablet   formatt   appendt   curse_add_linet	   get_viewst	   auto_unitt   curse_new_line(   R   R   t   rett   msg(    (    sE   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_mem.pyt	   msg_curse�   sX    .1.1.1.1N(   t   __name__t
   __module__t   __doc__t   NoneR   R   R   t   _check_decoratort   _log_result_decoratorR6   R:   RI   (    (    (    sE   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_mem.pyR   :   s   
	R	




#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""Network plugin."""

import base64
import operator

from glances.timer import getTimeSinceLastUpdate
from glances.plugins.glances_plugin import GlancesPlugin

import psutil

# SNMP OID
# http://www.net-snmp.org/docs/mibs/interfaces.html
# Dict key = interface_name
snmp_oid = {'default': {'interface_name': '1.3.6.1.2.1.2.2.1.2',
                        'cumulative_rx': '1.3.6.1.2.1.2.2.1.10',
                        'cumulative_tx': '1.3.6.1.2.1.2.2.1.16'}}

# Define the history items list
# All items in this list will be historised if the --enable-history tag is set
# 'color' define the graph color in #RGB format
items_history_list = [{'name': 'rx',
                       'description': 'Download rate per second',
                       'color': '#00FF00',
                       'y_unit': 'bit/s'},
                      {'name': 'tx',
                       'description': 'Upload rate per second',
                       'color': '#FF0000',
                       'y_unit': 'bit/s'}]


class Plugin(GlancesPlugin):

    """Glances network plugin.

    stats is a list
    """

    def __init__(self, args=None):
        """Init the plugin."""
        super(Plugin, self).__init__(args=args, items_history_list=items_history_list)

        # We want to display the stat in the curse interface
        self.display_curse = True

        # Init the stats
        self.reset()

    def get_key(self):
        """Return the key of the list."""
        return 'interface_name'

    def reset(self):
        """Reset/init the stats."""
        self.stats = []

    @GlancesPlugin._check_decorator
    @GlancesPlugin._log_result_decorator
    def update(self):
        """Update network stats using the input method.

        Stats is a list of dict (one dict per interface)
        """
        # Reset stats
        self.reset()

        if self.input_method == 'local':
            # Update stats using the standard system lib

            # Grab network interface stat using the PsUtil net_io_counter method
            try:
                netiocounters = psutil.net_io_counters(pernic=True)
            except UnicodeDecodeError:
                return self.stats

            # New in PsUtil 3.0
            # - import the interface's status (issue #765)
            # - import the interface's speed (issue #718)
            netstatus = {}
            try:
                netstatus = psutil.net_if_stats()
            except AttributeError:
                pass

            # Previous network interface stats are stored in the network_old variable
            if not hasattr(self, 'network_old'):
                # First call, we init the network_old var
                try:
                    self.network_old = netiocounters
                except (IOError, UnboundLocalError):
                    pass
            else:
                # By storing time data we enable Rx/s and Tx/s calculations in the
                # XML/RPC API, which would otherwise be overly difficult work
                # for users of the API
                time_since_update = getTimeSinceLastUpdate('net')

                # Loop over interfaces
                network_new = netiocounters
                for net in network_new:
                    # Do not take hidden interface into account
                    if self.is_hide(net):
                        continue
                    try:
                        cumulative_rx = network_new[net].bytes_recv
                        cumulative_tx = network_new[net].bytes_sent
                        cumulative_cx = cumulative_rx + cumulative_tx
                        rx = cumulative_rx - self.network_old[net].bytes_recv
                        tx = cumulative_tx - self.network_old[net].bytes_sent
                        cx = rx + tx
                        netstat = {
                            'interface_name': net,
                            'time_since_update': time_since_update,
                            'cumulative_rx': cumulative_rx,
                            'rx': rx,
                            'cumulative_tx': cumulative_tx,
                            'tx': tx,
                            'cumulative_cx': cumulative_cx,
                            'cx': cx}
                    except KeyError:
                        continue
                    else:
                        # Optional stats (only compliant with PsUtil 3.0+)
                        # Interface status
                        try:
                            netstat['is_up'] = netstatus[net].isup
                        except (KeyError, AttributeError):
                            pass
                        # Interface speed in Mbps, convert it to bps
                        # Can be always 0 on some OS
                        try:
                            netstat['speed'] = netstatus[net].speed * 1048576
                        except (KeyError, AttributeError):
                            pass

                        # Finaly, set the key
                        netstat['key'] = self.get_key()
                        self.stats.append(netstat)

                # Save stats to compute next bitrate
                self.network_old = network_new

        elif self.input_method == 'snmp':
            # Update stats using SNMP

            # SNMP bulk command to get all network interface in one shot
            try:
                netiocounters = self.get_stats_snmp(snmp_oid=snmp_oid[self.short_system_name],
                                                    bulk=True)
            except KeyError:
                netiocounters = self.get_stats_snmp(snmp_oid=snmp_oid['default'],
                                                    bulk=True)

            # Previous network interface stats are stored in the network_old variable
            if not hasattr(self, 'network_old'):
                # First call, we init the network_old var
                try:
                    self.network_old = netiocounters
                except (IOError, UnboundLocalError):
                    pass
            else:
                # See description in the 'local' block
                time_since_update = getTimeSinceLastUpdate('net')

                # Loop over interfaces
                network_new = netiocounters

                for net in network_new:
                    # Do not take hidden interface into account
                    if self.is_hide(net):
                        continue

                    try:
                        # Windows: a tips is needed to convert HEX to TXT
                        # http://blogs.technet.com/b/networking/archive/2009/12/18/how-to-query-the-list-of-network-interfaces-using-snmp-via-the-ifdescr-counter.aspx
                        if self.short_system_name == 'windows':
                            try:
                                interface_name = str(base64.b16decode(net[2:-2].upper()))
                            except TypeError:
                                interface_name = net
                        else:
                            interface_name = net

                        cumulative_rx = float(network_new[net]['cumulative_rx'])
                        cumulative_tx = float(network_new[net]['cumulative_tx'])
                        cumulative_cx = cumulative_rx + cumulative_tx
                        rx = cumulative_rx - float(self.network_old[net]['cumulative_rx'])
                        tx = cumulative_tx - float(self.network_old[net]['cumulative_tx'])
                        cx = rx + tx
                        netstat = {
                            'interface_name': interface_name,
                            'time_since_update': time_since_update,
                            'cumulative_rx': cumulative_rx,
                            'rx': rx,
                            'cumulative_tx': cumulative_tx,
                            'tx': tx,
                            'cumulative_cx': cumulative_cx,
                            'cx': cx}
                    except KeyError:
                        continue
                    else:
                        netstat['key'] = self.get_key()
                        self.stats.append(netstat)

                # Save stats to compute next bitrate
                self.network_old = network_new

        return self.stats

    def update_views(self):
        """Update stats views."""
        # Call the father's method
        super(Plugin, self).update_views()

        # Add specifics informations
        # Alert
        for i in self.stats:
            ifrealname = i['interface_name'].split(':')[0]
            # Convert rate in bps ( to be able to compare to interface speed)
            bps_rx = int(i['rx'] // i['time_since_update'] * 8)
            bps_tx = int(i['tx'] // i['time_since_update'] * 8)
            # Decorate the bitrate with the configuration file thresolds
            alert_rx = self.get_alert(bps_rx, header=ifrealname + '_rx')
            alert_tx = self.get_alert(bps_tx, header=ifrealname + '_tx')
            # If nothing is define in the configuration file...
            # ... then use the interface speed (not available on all systems)
            if alert_rx == 'DEFAULT' and 'speed' in i and i['speed'] != 0:
                alert_rx = self.get_alert(current=bps_rx,
                                          maximum=i['speed'],
                                          header='rx')
            if alert_tx == 'DEFAULT' and 'speed' in i and i['speed'] != 0:
                alert_tx = self.get_alert(current=bps_tx,
                                          maximum=i['speed'],
                                          header='tx')
            # then decorates
            self.views[i[self.get_key()]]['rx']['decoration'] = alert_rx
            self.views[i[self.get_key()]]['tx']['decoration'] = alert_tx

    def msg_curse(self, args=None, max_width=None):
        """Return the dict to display in the curse interface."""
        # Init the return message
        ret = []

        # Only process if stats exist and display plugin enable...
        if not self.stats or self.is_disable():
            return ret

        # Max size for the interface name
        if max_width is not None and max_width >= 23:
            # Interface size name = max_width - space for interfaces bitrate
            ifname_max_width = max_width - 14
        else:
            ifname_max_width = 9

        # Build the string message
        # Header
        msg = '{:{width}}'.format('NETWORK', width=ifname_max_width)
        ret.append(self.curse_add_line(msg, "TITLE"))
        if args.network_cumul:
            # Cumulative stats
            if args.network_sum:
                # Sum stats
                msg = '{:>14}'.format('Rx+Tx')
                ret.append(self.curse_add_line(msg))
            else:
                # Rx/Tx stats
                msg = '{:>7}'.format('Rx')
                ret.append(self.curse_add_line(msg))
                msg = '{:>7}'.format('Tx')
                ret.append(self.curse_add_line(msg))
        else:
            # Bitrate stats
            if args.network_sum:
                # Sum stats
                msg = '{:>14}'.format('Rx+Tx/s')
                ret.append(self.curse_add_line(msg))
            else:
                msg = '{:>7}'.format('Rx/s')
                ret.append(self.curse_add_line(msg))
                msg = '{:>7}'.format('Tx/s')
                ret.append(self.curse_add_line(msg))
        # Interface list (sorted by name)
        for i in sorted(self.stats, key=operator.itemgetter(self.get_key())):
            # Do not display interface in down state (issue #765)
            if ('is_up' in i) and (i['is_up'] is False):
                continue
            # Format stats
            # Is there an alias for the interface name ?
            ifrealname = i['interface_name'].split(':')[0]
            ifname = self.has_alias(i['interface_name'])
            if ifname is None:
                ifname = ifrealname
            if len(ifname) > ifname_max_width:
                # Cut interface name if it is too long
                ifname = '_' + ifname[-ifname_max_width + 1:]

            if args.byte:
                # Bytes per second (for dummy)
                to_bit = 1
                unit = ''
            else:
                # Bits per second (for real network administrator | Default)
                to_bit = 8
                unit = 'b'

            if args.network_cumul:
                rx = self.auto_unit(int(i['cumulative_rx'] * to_bit)) + unit
                tx = self.auto_unit(int(i['cumulative_tx'] * to_bit)) + unit
                sx = self.auto_unit(int(i['cumulative_rx'] * to_bit) +
                                    int(i['cumulative_tx'] * to_bit)) + unit
            else:
                rx = self.auto_unit(int(i['rx'] // i['time_since_update'] * to_bit)) + unit
                tx = self.auto_unit(int(i['tx'] // i['time_since_update'] * to_bit)) + unit
                sx = self.auto_unit(int(i['rx'] // i['time_since_update'] * to_bit) +
                                    int(i['tx'] // i['time_since_update'] * to_bit)) + unit

            # New line
            ret.append(self.curse_new_line())
            msg = '{:{width}}'.format(ifname, width=ifname_max_width)
            ret.append(self.curse_add_line(msg))
            if args.network_sum:
                msg = '{:>14}'.format(sx)
                ret.append(self.curse_add_line(msg))
            else:
                msg = '{:>7}'.format(rx)
                ret.append(self.curse_add_line(
                    msg, self.get_views(item=i[self.get_key()], key='rx', option='decoration')))
                msg = '{:>7}'.format(tx)
                ret.append(self.curse_add_line(
                    msg, self.get_views(item=i[self.get_key()], key='tx', option='decoration')))

        return ret
                                                                                                                                                                 ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_processlist.py                      0000664 0000000 0000000 00000067136 13066703446 024606  0                                                                                                    ustar                                                                                                                                                                                                                                                          # -*- coding: utf-8 -*-
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""Process list plugin."""

import os
from datetime import timedelta

from glances.compat import iteritems
from glances.globals import LINUX, WINDOWS
from glances.logger import logger
from glances.processes import glances_processes, sort_stats
from glances.plugins.glances_core import Plugin as CorePlugin
from glances.plugins.glances_plugin import GlancesPlugin


def convert_timedelta(delta):
    """Convert timedelta to human-readable time."""
    days, total_seconds = delta.days, delta.seconds
    hours = days * 24 + total_seconds // 3600
    minutes = (total_seconds % 3600) // 60
    seconds = str(total_seconds % 60).zfill(2)
    microseconds = str(delta.microseconds)[:2].zfill(2)

    return hours, minutes, seconds, microseconds


def split_cmdline(cmdline):
    """Return path, cmd and arguments for a process cmdline."""
    path, cmd = os.path.split(cmdline[0])
    arguments = ' '.join(cmdline[1:]).replace('\n', ' ')
    # XXX: workaround for psutil issue #742
    if LINUX and any(x in cmdline[0] for x in ('chrome', 'chromium')):
        try:
            exe, arguments = cmdline[0].split(' ', 1)
            path, cmd = os.path.split(exe)
        except ValueError:
            arguments = None

    return path, cmd, arguments


class Plugin(GlancesPlugin):

    """Glances' processes plugin.

    stats is a list
    """

    def __init__(self, args=None):
        """Init the plugin."""
        super(Plugin, self).__init__(args=args)

        # We want to display the stat in the curse interface
        self.display_curse = True

        # Trying to display proc time
        self.tag_proc_time = True

        # Call CorePlugin to get the core number (needed when not in IRIX mode / Solaris mode)
        try:
            self.nb_log_core = CorePlugin(args=self.args).update()["log"]
        except Exception:
            self.nb_log_core = 0

        # Get the max values (dict)
        self.max_values = glances_processes.max_values()

        # Get the maximum PID number
        # Use to optimize space (see https://github.com/nicolargo/glances/issues/959)
        self.pid_max = glances_processes.pid_max

        # Note: 'glances_processes' is already init in the processes.py script

    def get_key(self):
        """Return the key of the list."""
        return 'pid'

    def reset(self):
        """Reset/init the stats."""
        self.stats = []

    def update(self):
        """Update processes stats using the input method."""
        # Reset stats
        self.reset()

        if self.input_method == 'local':
            # Update stats using the standard system lib
            # Note: Update is done in the processcount plugin
            # Just return the processes list
            if glances_processes.is_tree_enabled():
                self.stats = glances_processes.gettree()
            else:
                self.stats = glances_processes.getlist()

            # Get the max values (dict)
            self.max_values = glances_processes.max_values()

        elif self.input_method == 'snmp':
            # No SNMP grab for processes
            pass

        return self.stats

    def get_process_tree_curses_data(self, node, args, first_level=True, max_node_count=None):
        """Get curses data to display for a process tree."""
        ret = []
        node_count = 0
        if not node.is_root and ((max_node_count is None) or (max_node_count > 0)):
            node_data = self.get_process_curses_data(node.stats, False, args)
            node_count += 1
            ret.extend(node_data)
        for child in node.iter_children():
            # stop if we have enough nodes to display
            if max_node_count is not None and node_count >= max_node_count:
                break

            if max_node_count is None:
                children_max_node_count = None
            else:
                children_max_node_count = max_node_count - node_count
            child_data = self.get_process_tree_curses_data(child,
                                                           args,
                                                           first_level=node.is_root,
                                                           max_node_count=children_max_node_count)
            if max_node_count is None:
                node_count += len(child)
            else:
                node_count += min(children_max_node_count, len(child))

            if not node.is_root:
                child_data = self.add_tree_decoration(child_data, child is node.children[-1], first_level)
            ret.extend(child_data)
        return ret

    def add_tree_decoration(self, child_data, is_last_child, first_level):
        """Add tree curses decoration and indentation to a subtree."""
        # find process command indices in messages
        pos = []
        for i, m in enumerate(child_data):
            if m.get("_tree_decoration", False):
                del m["_tree_decoration"]
                pos.append(i)

        # add new curses items for tree decoration
        new_child_data = []
        new_pos = []
        for i, m in enumerate(child_data):
            if i in pos:
                new_pos.append(len(new_child_data))
                new_child_data.append(self.curse_add_line(""))
                new_child_data[-1]["_tree_decoration"] = True
            new_child_data.append(m)
        child_data = new_child_data
        pos = new_pos

        if pos:
            # draw node prefix
            if is_last_child:
                prefix = "└─"
            else:
                prefix = "├─"
            child_data[pos[0]]["msg"] = prefix

            # add indentation
            for i in pos:
                spacing = 2
                if first_level:
                    spacing = 1
                elif is_last_child and (i is not pos[0]):
                    # compensate indentation for missing '│' char
                    spacing = 3
                child_data[i]["msg"] = "%s%s" % (" " * spacing, child_data[i]["msg"])

            if not is_last_child:
                # add '│' tree decoration
                for i in pos[1:]:
                    old_str = child_data[i]["msg"]
                    if first_level:
                        child_data[i]["msg"] = " │" + old_str[2:]
                    else:
                        child_data[i]["msg"] = old_str[:2] + "│" + old_str[3:]

        return child_data

    def get_process_curses_data(self, p, first, args):
        """Get curses data to display for a process.
        - p is the process to display
        - first is a tag=True if the process is the first on the list
        """
        ret = [self.curse_new_line()]
        # CPU
        if 'cpu_percent' in p and p['cpu_percent'] is not None and p['cpu_percent'] != '':
            if args.disable_irix and self.nb_log_core != 0:
                msg = '{:>6.1f}'.format(p['cpu_percent'] / float(self.nb_log_core))
            else:
                msg = '{:>6.1f}'.format(p['cpu_percent'])
            alert = self.get_alert(p['cpu_percent'],
                                   highlight_zero=False,
                                   is_max=(p['cpu_percent'] == self.max_values['cpu_percent']),
                                   header="cpu")
            ret.append(self.curse_add_line(msg, alert))
        else:
            msg = '{:>6}'.format('?')
            ret.append(self.curse_add_line(msg))
        # MEM
        if 'memory_percent' in p and p['memory_percent'] is not None and p['memory_percent'] != '':
            msg = '{:>6.1f}'.format(p['memory_percent'])
            alert = self.get_alert(p['memory_percent'],
                                   highlight_zero=False,
                                   is_max=(p['memory_percent'] == self.max_values['memory_percent']),
                                   header="mem")
            ret.append(self.curse_add_line(msg, alert))
        else:
            msg = '{:>6}'.format('?')
            ret.append(self.curse_add_line(msg))
        # VMS/RSS
        if 'memory_info' in p and p['memory_info'] is not None and p['memory_info'] != '':
            # VMS
            msg = '{:>6}'.format(self.auto_unit(p['memory_info'][1], low_precision=False))
            ret.append(self.curse_add_line(msg, optional=True))
            # RSS
            msg = '{:>6}'.format(self.auto_unit(p['memory_info'][0], low_precision=False))
            ret.append(self.curse_add_line(msg, optional=True))
        else:
            msg = '{:>6}'.format('?')
            ret.append(self.curse_add_line(msg))
            ret.append(self.curse_add_line(msg))
        # PID
        msg = '{:>{width}}'.format(p['pid'], width=self.__max_pid_size() + 1)
        ret.append(self.curse_add_line(msg))
        # USER
        if 'username' in p:
            # docker internal users are displayed as ints only, therefore str()
            # Correct issue #886 on Windows OS
            msg = ' {:9}'.format(str(p['username'])[:9])
            ret.append(self.curse_add_line(msg))
        else:
            msg = ' {:9}'.format('?')
            ret.append(self.curse_add_line(msg))
        # NICE
        if 'nice' in p:
            nice = p['nice']
            if nice is None:
                nice = '?'
            msg = '{:>5}'.format(nice)
            if isinstance(nice, int) and ((WINDOWS and nice != 32) or
                                          (not WINDOWS and nice != 0)):
                ret.append(self.curse_add_line(msg, decoration='NICE'))
            else:
                ret.append(self.curse_add_line(msg))
        else:
            msg = '{:>5}'.format('?')
            ret.append(self.curse_add_line(msg))
        # STATUS
        if 'status' in p:
            status = p['status']
            msg = '{:>2}'.format(status)
            if status == 'R':
                ret.append(self.curse_add_line(msg, decoration='STATUS'))
            else:
                ret.append(self.curse_add_line(msg))
        else:
            msg = '{:>2}'.format('?')
            ret.append(self.curse_add_line(msg))
        # TIME+
        if self.tag_proc_time:
            try:
                delta = timedelta(seconds=sum(p['cpu_times']))
            except (OverflowError, TypeError) as e:
                # Catch OverflowError on some Amazon EC2 server
                # See https://github.com/nicolargo/glances/issues/87
                # Also catch TypeError on macOS
                # See: https://github.com/nicolargo/glances/issues/622
                logger.debug("Cannot get TIME+ ({})".format(e))
                self.tag_proc_time = False
            else:
                hours, minutes, seconds, microseconds = convert_timedelta(delta)
                if hours:
                    msg = '{:>4}h'.format(hours)
                    ret.append(self.curse_add_line(msg, decoration='CPU_TIME', optional=True))
                    msg = '{}:{}'.format(str(minutes).zfill(2), seconds)
                else:
                    msg = '{:>4}:{}.{}'.format(minutes, seconds, microseconds)
        else:
            msg = '{:>10}'.format('?')
        ret.append(self.curse_add_line(msg, optional=True))
        # IO read/write
        if 'io_counters' in p:
            # IO read
            io_rs = int((p['io_counters'][0] - p['io_counters'][2]) / p['time_since_update'])
            if io_rs == 0:
                msg = '{:>6}'.format("0")
            else:
                msg = '{:>6}'.format(self.auto_unit(io_rs, low_precision=True))
            ret.append(self.curse_add_line(msg, optional=True, additional=True))
            # IO write
            io_ws = int((p['io_counters'][1] - p['io_counters'][3]) / p['time_since_update'])
            if io_ws == 0:
                msg = '{:>6}'.format("0")
            else:
                msg = '{:>6}'.format(self.auto_unit(io_ws, low_precision=True))
            ret.append(self.curse_add_line(msg, optional=True, additional=True))
        else:
            msg = '{:>6}'.format("?")
            ret.append(self.curse_add_line(msg, optional=True, additional=True))
            ret.append(self.curse_add_line(msg, optional=True, additional=True))

        # Command line
        # If no command line for the process is available, fallback to
        # the bare process name instead
        cmdline = p['cmdline']
        try:
            # XXX: remove `cmdline != ['']` when we'll drop support for psutil<4.0.0
            if cmdline and cmdline != ['']:
                path, cmd, arguments = split_cmdline(cmdline)
                if os.path.isdir(path) and not args.process_short_name:
                    msg = ' {}'.format(path) + os.sep
                    ret.append(self.curse_add_line(msg, splittable=True))
                    if glances_processes.is_tree_enabled():
                        # mark position to add tree decoration
                        ret[-1]["_tree_decoration"] = True
                    ret.append(self.curse_add_line(cmd, decoration='PROCESS', splittable=True))
                else:
                    msg = ' {}'.format(cmd)
                    ret.append(self.curse_add_line(msg, decoration='PROCESS', splittable=True))
                    if glances_processes.is_tree_enabled():
                        # mark position to add tree decoration
                        ret[-1]["_tree_decoration"] = True
                if arguments:
                    msg = ' {}'.format(arguments)
                    ret.append(self.curse_add_line(msg, splittable=True))
            else:
                msg = ' {}'.format(p['name'])
                ret.append(self.curse_add_line(msg, splittable=True))
        except UnicodeEncodeError:
            ret.append(self.curse_add_line('', splittable=True))

        # Add extended stats but only for the top processes
        # !!! CPU consumption ???
        # TODO: extended stats into the web interface
        if first and 'extended_stats' in p:
            # Left padding
            xpad = ' ' * 13
            # First line is CPU affinity
            if 'cpu_affinity' in p and p['cpu_affinity'] is not None:
                ret.append(self.curse_new_line())
                msg = xpad + 'CPU affinity: ' + str(len(p['cpu_affinity'])) + ' cores'
                ret.append(self.curse_add_line(msg, splittable=True))
            # Second line is memory info
            if 'memory_info' in p and p['memory_info'] is not None:
                ret.append(self.curse_new_line())
                msg = xpad + 'Memory info: '
                for k, v in iteritems(p['memory_info']._asdict()):
                    # Ignore rss and vms (already displayed)
                    if k not in ['rss', 'vms'] and v is not None:
                        msg += k + ' ' + self.auto_unit(v, low_precision=False) + ' '
                if 'memory_swap' in p and p['memory_swap'] is not None:
                    msg += 'swap ' + self.auto_unit(p['memory_swap'], low_precision=False)
                ret.append(self.curse_add_line(msg, splittable=True))
            # Third line is for open files/network sessions
            msg = ''
            if 'num_threads' in p and p['num_threads'] is not None:
                msg += 'threads ' + str(p['num_threads']) + ' '
            if 'num_fds' in p and p['num_fds'] is not None:
                msg += 'files ' + str(p['num_fds']) + ' '
            if 'num_handles' in p and p['num_handles'] is not None:
                msg += 'handles ' + str(p['num_handles']) + ' '
            if 'tcp' in p and p['tcp'] is not None:
                msg += 'TCP ' + str(p['tcp']) + ' '
            if 'udp' in p and p['udp'] is not None:
                msg += 'UDP ' + str(p['udp']) + ' '
            if msg != '':
                ret.append(self.curse_new_line())
                msg = xpad + 'Open: ' + msg
                ret.append(self.curse_add_line(msg, splittable=True))
            # Fouth line is IO nice level (only Linux and Windows OS)
            if 'ionice' in p and p['ionice'] is not None:
                ret.append(self.curse_new_line())
                msg = xpad + 'IO nice: '
                k = 'Class is '
                v = p['ionice'].ioclass
                # Linux: The scheduling class. 0 for none, 1 for real time, 2 for best-effort, 3 for idle.
                # Windows: On Windows only ioclass is used and it can be set to 2 (normal), 1 (low) or 0 (very low).
                if WINDOWS:
                    if v == 0:
                        msg += k + 'Very Low'
                    elif v == 1:
                        msg += k + 'Low'
                    elif v == 2:
                        msg += 'No specific I/O priority'
                    else:
                        msg += k + str(v)
                else:
                    if v == 0:
                        msg += 'No specific I/O priority'
                    elif v == 1:
                        msg += k + 'Real Time'
                    elif v == 2:
                        msg += k + 'Best Effort'
                    elif v == 3:
                        msg += k + 'IDLE'
                    else:
                        msg += k + str(v)
                #  value is a number which goes from 0 to 7.
                # The higher the value, the lower the I/O priority of the process.
                if hasattr(p['ionice'], 'value') and p['ionice'].value != 0:
                    msg += ' (value %s/7)' % str(p['ionice'].value)
                ret.append(self.curse_add_line(msg, splittable=True))

        return ret

    def msg_curse(self, args=None):
        """Return the dict to display in the curse interface."""
        # Init the return message
        ret = []

        # Only process if stats exist and display plugin enable...
        if not self.stats or args.disable_process:
            return ret

        # Compute the sort key
        process_sort_key = glances_processes.sort_key

        # Header
        self.__msg_curse_header(ret, process_sort_key, args)

        # Process list
        if glances_processes.is_tree_enabled():
            ret.extend(self.get_process_tree_curses_data(
                self.__sort_stats(process_sort_key), args, first_level=True,
                max_node_count=glances_processes.max_processes))
        else:
            # Loop over processes (sorted by the sort key previously compute)
            first = True
            for p in self.__sort_stats(process_sort_key):
                ret.extend(self.get_process_curses_data(p, first, args))
                # End of extended stats
                first = False
            if glances_processes.process_filter is not None:
                if args.reset_minmax_tag:
                    args.reset_minmax_tag = not args.reset_minmax_tag
                    self.__mmm_reset()
                self.__msg_curse_sum(ret, args=args)
                self.__msg_curse_sum(ret, mmm='min', args=args)
                self.__msg_curse_sum(ret, mmm='max', args=args)

        # Return the message with decoration
        return ret

    def __msg_curse_header(self, ret, process_sort_key, args=None):
        """
        Build the header and add it to the ret dict
        """
        sort_style = 'SORT'

        if args.disable_irix and 0 < self.nb_log_core < 10:
            msg = '{:>6}'.format('CPU%/' + str(self.nb_log_core))
        elif args.disable_irix and self.nb_log_core != 0:
            msg = '{:>6}'.format('CPU%/C')
        else:
            msg = '{:>6}'.format('CPU%')
        ret.append(self.curse_add_line(msg, sort_style if process_sort_key == 'cpu_percent' else 'DEFAULT'))
        msg = '{:>6}'.format('MEM%')
        ret.append(self.curse_add_line(msg, sort_style if process_sort_key == 'memory_percent' else 'DEFAULT'))
        msg = '{:>6}'.format('VIRT')
        ret.append(self.curse_add_line(msg, optional=True))
        msg = '{:>6}'.format('RES')
        ret.append(self.curse_add_line(msg, optional=True))
        msg = '{:>{width}}'.format('PID', width=self.__max_pid_size() + 1)
        ret.append(self.curse_add_line(msg))
        msg = ' {:10}'.format('USER')
        ret.append(self.curse_add_line(msg, sort_style if process_sort_key == 'username' else 'DEFAULT'))
        msg = '{:>4}'.format('NI')
        ret.append(self.curse_add_line(msg))
        msg = '{:>2}'.format('S')
        ret.append(self.curse_add_line(msg))
        msg = '{:>10}'.format('TIME+')
        ret.append(self.curse_add_line(msg, sort_style if process_sort_key == 'cpu_times' else 'DEFAULT', optional=True))
        msg = '{:>6}'.format('R/s')
        ret.append(self.curse_add_line(msg, sort_style if process_sort_key == 'io_counters' else 'DEFAULT', optional=True, additional=True))
        msg = '{:>6}'.format('W/s')
        ret.append(self.curse_add_line(msg, sort_style if process_sort_key == 'io_counters' else 'DEFAULT', optional=True, additional=True))
        msg = ' {:8}'.format('Command')
        ret.append(self.curse_add_line(msg, sort_style if process_sort_key == 'name' else 'DEFAULT'))

    def __msg_curse_sum(self, ret, sep_char='_', mmm=None, args=None):
        """
        Build the sum message (only when filter is on) and add it to the ret dict
        * ret: list of string where the message is added
        * sep_char: define the line separation char
        * mmm: display min, max, mean or current (if mmm=None)
        * args: Glances args
        """
        ret.append(self.curse_new_line())
        if mmm is None:
            ret.append(self.curse_add_line(sep_char * 69))
            ret.append(self.curse_new_line())
        # CPU percent sum
        msg = '{:>6.1f}'.format(self.__sum_stats('cpu_percent', mmm=mmm))
        ret.append(self.curse_add_line(msg,
                                       decoration=self.__mmm_deco(mmm)))
        # MEM percent sum
        msg = '{:>6.1f}'.format(self.__sum_stats('memory_percent', mmm=mmm))
        ret.append(self.curse_add_line(msg,
                                       decoration=self.__mmm_deco(mmm)))
        # VIRT and RES memory sum
        if 'memory_info' in self.stats[0] and self.stats[0]['memory_info'] is not None and self.stats[0]['memory_info'] != '':
            # VMS
            msg = '{:>6}'.format(self.auto_unit(self.__sum_stats('memory_info', indice=1, mmm=mmm), low_precision=False))
            ret.append(self.curse_add_line(msg,
                                           decoration=self.__mmm_deco(mmm),
                                           optional=True))
            # RSS
            msg = '{:>6}'.format(self.auto_unit(self.__sum_stats('memory_info', indice=0, mmm=mmm), low_precision=False))
            ret.append(self.curse_add_line(msg,
                                           decoration=self.__mmm_deco(mmm),
                                           optional=True))
        else:
            msg = '{:>6}'.format('')
            ret.append(self.curse_add_line(msg))
            ret.append(self.curse_add_line(msg))
        # PID
        msg = '{:>6}'.format('')
        ret.append(self.curse_add_line(msg))
        # USER
        msg = ' {:9}'.format('')
        ret.append(self.curse_add_line(msg))
        # NICE
        msg = '{:>5}'.format('')
        ret.append(self.curse_add_line(msg))
        # STATUS
        msg = '{:>2}'.format('')
        ret.append(self.curse_add_line(msg))
        # TIME+
        msg = '{:>10}'.format('')
        ret.append(self.curse_add_line(msg, optional=True))
        # IO read/write
        if 'io_counters' in self.stats[0] and mmm is None:
            # IO read
            io_rs = int((self.__sum_stats('io_counters', 0) - self.__sum_stats('io_counters', indice=2, mmm=mmm)) / self.stats[0]['time_since_update'])
            if io_rs == 0:
                msg = '{:>6}'.format('0')
            else:
                msg = '{:>6}'.format(self.auto_unit(io_rs, low_precision=True))
            ret.append(self.curse_add_line(msg,
                                           decoration=self.__mmm_deco(mmm),
                                           optional=True, additional=True))
            # IO write
            io_ws = int((self.__sum_stats('io_counters', 1) - self.__sum_stats('io_counters', indice=3, mmm=mmm)) / self.stats[0]['time_since_update'])
            if io_ws == 0:
                msg = '{:>6}'.format('0')
            else:
                msg = '{:>6}'.format(self.auto_unit(io_ws, low_precision=True))
            ret.append(self.curse_add_line(msg,
                                           decoration=self.__mmm_deco(mmm),
                                           optional=True, additional=True))
        else:
            msg = '{:>6}'.format('')
            ret.append(self.curse_add_line(msg, optional=True, additional=True))
            ret.append(self.curse_add_line(msg, optional=True, additional=True))
        if mmm is None:
            msg = ' < {}'.format('current')
            ret.append(self.curse_add_line(msg, optional=True))
        else:
            msg = ' < {}'.format(mmm)
            ret.append(self.curse_add_line(msg, optional=True))
            msg = ' (\'M\' to reset)'
            ret.append(self.curse_add_line(msg, optional=True))

    def __mmm_deco(self, mmm):
        """
        Return the decoration string for the current mmm status
        """
        if mmm is not None:
            return 'DEFAULT'
        else:
            return 'FILTER'

    def __mmm_reset(self):
        """
        Reset the MMM stats
        """
        self.mmm_min = {}
        self.mmm_max = {}

    def __sum_stats(self, key, indice=None, mmm=None):
        """
        Return the sum of the stats value for the given key
        * indice: If indice is set, get the p[key][indice]
        * mmm: display min, max, mean or current (if mmm=None)
        """
        # Compute stats summary
        ret = 0
        for p in self.stats:
            if indice is None:
                ret += p[key]
            else:
                ret += p[key][indice]

        # Manage Min/Max/Mean
        mmm_key = self.__mmm_key(key, indice)
        if mmm == 'min':
            try:
                if self.mmm_min[mmm_key] > ret:
                    self.mmm_min[mmm_key] = ret
            except AttributeError:
                self.mmm_min = {}
                return 0
            except KeyError:
                self.mmm_min[mmm_key] = ret
            ret = self.mmm_min[mmm_key]
        elif mmm == 'max':
            try:
                if self.mmm_max[mmm_key] < ret:
                    self.mmm_max[mmm_key] = ret
            except AttributeError:
                self.mmm_max = {}
                return 0
            except KeyError:
                self.mmm_max[mmm_key] = ret
            ret = self.mmm_max[mmm_key]

        return ret

    def __mmm_key(self, key, indice):
        ret = key
        if indice is not None:
            ret += str(indice)
        return ret

    def __sort_stats(self, sortedby=None):
        """Return the stats (dict) sorted by (sortedby)"""
        return sort_stats(self.stats, sortedby,
                          tree=glances_processes.is_tree_enabled(),
                          reverse=glances_processes.sort_reverse)

    def __max_pid_size(self):
        """Return the maximum PID size in number of char"""
        if self.pid_max is not None:
            return len(str(self.pid_max))
        else:
            # By default return 5 (corresponding to 99999 PID number)
            return 5
                                                                                                                                                                                                                                                                                                                                                                                                                                  ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_memswap.py                          0000664 0000000 0000000 00000016135 13066703446 023676  0                                                                                                    ustar                                                                                                                                                                                                                                                          # -*- coding: utf-8 -*-
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""Swap memory plugin."""

from glances.compat import iterkeys
from glances.plugins.glances_plugin import GlancesPlugin

import psutil

# SNMP OID
# Total Swap Size: .1.3.6.1.4.1.2021.4.3.0
# Available Swap Space: .1.3.6.1.4.1.2021.4.4.0
snmp_oid = {'default': {'total': '1.3.6.1.4.1.2021.4.3.0',
                        'free': '1.3.6.1.4.1.2021.4.4.0'},
            'windows': {'mnt_point': '1.3.6.1.2.1.25.2.3.1.3',
                        'alloc_unit': '1.3.6.1.2.1.25.2.3.1.4',
                        'size': '1.3.6.1.2.1.25.2.3.1.5',
                        'used': '1.3.6.1.2.1.25.2.3.1.6'}}

# Define the history items list
# All items in this list will be historised if the --enable-history tag is set
# 'color' define the graph color in #RGB format
items_history_list = [{'name': 'percent',
                       'description': 'Swap memory usage',
                       'color': '#00FF00',
                       'y_unit': '%'}]


class Plugin(GlancesPlugin):

    """Glances swap memory plugin.

    stats is a dict
    """

    def __init__(self, args=None):
        """Init the plugin."""
        super(Plugin, self).__init__(args=args, items_history_list=items_history_list)

        # We want to display the stat in the curse interface
        self.display_curse = True

        # Init the stats
        self.reset()

    def reset(self):
        """Reset/init the stats."""
        self.stats = {}

    @GlancesPlugin._check_decorator
    @GlancesPlugin._log_result_decorator
    def update(self):
        """Update swap memory stats using the input method."""
        # Reset stats
        self.reset()

        if self.input_method == 'local':
            # Update stats using the standard system lib
            # Grab SWAP using the PSUtil swap_memory method
            sm_stats = psutil.swap_memory()

            # Get all the swap stats (copy/paste of the PsUtil documentation)
            # total: total swap memory in bytes
            # used: used swap memory in bytes
            # free: free swap memory in bytes
            # percent: the percentage usage
            # sin: the number of bytes the system has swapped in from disk (cumulative)
            # sout: the number of bytes the system has swapped out from disk
            # (cumulative)
            for swap in ['total', 'used', 'free', 'percent',
                         'sin', 'sout']:
                if hasattr(sm_stats, swap):
                    self.stats[swap] = getattr(sm_stats, swap)
        elif self.input_method == 'snmp':
            # Update stats using SNMP
            if self.short_system_name == 'windows':
                # Mem stats for Windows OS are stored in the FS table
                try:
                    fs_stat = self.get_stats_snmp(snmp_oid=snmp_oid[self.short_system_name],
                                                  bulk=True)
                except KeyError:
                    self.reset()
                else:
                    for fs in fs_stat:
                        # The virtual memory concept is used by the operating
                        # system to extend (virtually) the physical memory and
                        # thus to run more programs by swapping unused memory
                        # zone (page) to a disk file.
                        if fs == 'Virtual Memory':
                            self.stats['total'] = int(
                                fs_stat[fs]['size']) * int(fs_stat[fs]['alloc_unit'])
                            self.stats['used'] = int(
                                fs_stat[fs]['used']) * int(fs_stat[fs]['alloc_unit'])
                            self.stats['percent'] = float(
                                self.stats['used'] * 100 / self.stats['total'])
                            self.stats['free'] = self.stats[
                                'total'] - self.stats['used']
                            break
            else:
                self.stats = self.get_stats_snmp(snmp_oid=snmp_oid['default'])

                if self.stats['total'] == '':
                    self.reset()
                    return self.stats

                for key in iterkeys(self.stats):
                    if self.stats[key] != '':
                        self.stats[key] = float(self.stats[key]) * 1024

                # used=total-free
                self.stats['used'] = self.stats['total'] - self.stats['free']

                # percent: the percentage usage calculated as (total -
                # available) / total * 100.
                self.stats['percent'] = float(
                    (self.stats['total'] - self.stats['free']) / self.stats['total'] * 100)

        return self.stats

    def update_views(self):
        """Update stats views."""
        # Call the father's method
        super(Plugin, self).update_views()

        # Add specifics informations
        # Alert and log
        self.views['used']['decoration'] = self.get_alert_log(self.stats['used'], maximum=self.stats['total'])

    def msg_curse(self, args=None):
        """Return the dict to display in the curse interface."""
        # Init the return message
        ret = []

        # Only process if stats exist and plugin not disabled
        if not self.stats or self.is_disable():
            return ret

        # Build the string message
        # Header
        msg = '{:7} '.format('SWAP')
        ret.append(self.curse_add_line(msg, "TITLE"))
        # Percent memory usage
        msg = '{:>6.1%}'.format(self.stats['percent'] / 100)
        ret.append(self.curse_add_line(msg))
        # New line
        ret.append(self.curse_new_line())
        # Total memory usage
        msg = '{:8}'.format('total:')
        ret.append(self.curse_add_line(msg))
        msg = '{:>6}'.format(self.auto_unit(self.stats['total']))
        ret.append(self.curse_add_line(msg))
        # New line
        ret.append(self.curse_new_line())
        # Used memory usage
        msg = '{:8}'.format('used:')
        ret.append(self.curse_add_line(msg))
        msg = '{:>6}'.format(self.auto_unit(self.stats['used']))
        ret.append(self.curse_add_line(
            msg, self.get_views(key='used', option='decoration')))
        # New line
        ret.append(self.curse_new_line())
        # Free memory usage
        msg = '{:8}'.format('free:')
        ret.append(self.curse_add_line(msg))
        msg = '{:>6}'.format(self.auto_unit(self.stats['free']))
        ret.append(self.curse_add_line(msg))

        return ret
                                                                                                                                                                                                                                                                                                                                                                                                                                   ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_load.py                             0000664 0000000 0000000 00000013444 13066703446 023144  0                                                                                                    ustar                                                                                                                                                                                                                                                          # -*- coding: utf-8 -*-
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""Load plugin."""

import os

from glances.compat import iteritems
from glances.plugins.glances_core import Plugin as CorePlugin
from glances.plugins.glances_plugin import GlancesPlugin

# SNMP OID
# 1 minute Load: .1.3.6.1.4.1.2021.10.1.3.1
# 5 minute Load: .1.3.6.1.4.1.2021.10.1.3.2
# 15 minute Load: .1.3.6.1.4.1.2021.10.1.3.3
snmp_oid = {'min1': '1.3.6.1.4.1.2021.10.1.3.1',
            'min5': '1.3.6.1.4.1.2021.10.1.3.2',
            'min15': '1.3.6.1.4.1.2021.10.1.3.3'}

# Define the history items list
# All items in this list will be historised if the --enable-history tag is set
# 'color' define the graph color in #RGB format
items_history_list = [{'name': 'min1',
                       'description': '1 minute load',
                       'color': '#0000FF'},
                      {'name': 'min5',
                       'description': '5 minutes load',
                       'color': '#0000AA'},
                      {'name': 'min15',
                       'description': '15 minutes load',
                       'color': '#000044'}]


class Plugin(GlancesPlugin):

    """Glances load plugin.

    stats is a dict
    """

    def __init__(self, args=None):
        """Init the plugin."""
        super(Plugin, self).__init__(args=args, items_history_list=items_history_list)

        # We want to display the stat in the curse interface
        self.display_curse = True

        # Init stats
        self.reset()

        # Call CorePlugin in order to display the core number
        try:
            self.nb_log_core = CorePlugin(args=self.args).update()["log"]
        except Exception:
            self.nb_log_core = 1

    def reset(self):
        """Reset/init the stats."""
        self.stats = {}

    @GlancesPlugin._check_decorator
    @GlancesPlugin._log_result_decorator
    def update(self):
        """Update load stats."""
        # Reset stats
        self.reset()

        if self.input_method == 'local':
            # Update stats using the standard system lib

            # Get the load using the os standard lib
            try:
                load = os.getloadavg()
            except (OSError, AttributeError):
                self.stats = {}
            else:
                self.stats = {'min1': load[0],
                              'min5': load[1],
                              'min15': load[2],
                              'cpucore': self.nb_log_core}
        elif self.input_method == 'snmp':
            # Update stats using SNMP
            self.stats = self.get_stats_snmp(snmp_oid=snmp_oid)

            if self.stats['min1'] == '':
                self.reset()
                return self.stats

            # Python 3 return a dict like:
            # {'min1': "b'0.08'", 'min5': "b'0.12'", 'min15': "b'0.15'"}
            for k, v in iteritems(self.stats):
                self.stats[k] = float(v)

            self.stats['cpucore'] = self.nb_log_core

        return self.stats

    def update_views(self):
        """Update stats views."""
        # Call the father's method
        super(Plugin, self).update_views()

        # Add specifics informations
        try:
            # Alert and log
            self.views['min15']['decoration'] = self.get_alert_log(self.stats['min15'], maximum=100 * self.stats['cpucore'])
            # Alert only
            self.views['min5']['decoration'] = self.get_alert(self.stats['min5'], maximum=100 * self.stats['cpucore'])
        except KeyError:
            # try/except mandatory for Windows compatibility (no load stats)
            pass

    def msg_curse(self, args=None):
        """Return the dict to display in the curse interface."""
        # Init the return message
        ret = []

        # Only process if stats exist, not empty (issue #871) and plugin not disabled
        if not self.stats or (self.stats == {}) or self.is_disable():
            return ret

        # Build the string message
        # Header
        msg = '{:8}'.format('LOAD')
        ret.append(self.curse_add_line(msg, "TITLE"))
        # Core number
        if 'cpucore' in self.stats and self.stats['cpucore'] > 0:
            msg = '{}-core'.format(int(self.stats['cpucore']))
            ret.append(self.curse_add_line(msg))
        # New line
        ret.append(self.curse_new_line())
        # 1min load
        msg = '{:8}'.format('1 min:')
        ret.append(self.curse_add_line(msg))
        msg = '{:>6.2f}'.format(self.stats['min1'])
        ret.append(self.curse_add_line(msg))
        # New line
        ret.append(self.curse_new_line())
        # 5min load
        msg = '{:8}'.format('5 min:')
        ret.append(self.curse_add_line(msg))
        msg = '{:>6.2f}'.format(self.stats['min5'])
        ret.append(self.curse_add_line(
            msg, self.get_views(key='min5', option='decoration')))
        # New line
        ret.append(self.curse_new_line())
        # 15min load
        msg = '{:8}'.format('15 min:')
        ret.append(self.curse_add_line(msg))
        msg = '{:>6.2f}'.format(self.stats['min15'])
        ret.append(self.curse_add_line(
            msg, self.get_views(key='min15', option='decoration')))

        return ret
                                                                                                                                                                                                                            ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_help.pyc                            0000664 0000000 0000000 00000017020 13070471670 023306  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   sF   d  Z  d d l m Z m Z d d l m Z d e f d �  �  YZ d S(   s@   
Help plugin.

Just a stupid plugin to display the help screen.
i����(   t   __version__t   psutil_version(   t
    			c         C   s   d S(   s2   No stats. It is just a plugin to display the help.N(    (   R   (    (    sF   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_help.pyt   reset0   s    c         C   s   d S(   s2   No stats. It is just a plugin to display the help.N(    (   R   (    (    sF   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_help.pyt   update4   s    c         C   s  d j  d t � |  j d <d j  t � |  j d <y  d j  |  j j � |  j d <Wn t k
 rb n Xd } d	 } | j  d
 d � |  j d <| j  d
   R   R   t   loaded_config_filet   AttributeError(   R   t   msg_colt   msg_col2(    (    sF   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_help.pyR   8   sZ     
   (   R   R   (    (    sF   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_help.pyt
 � � | j  |  j �  � | j  |  j |  j d � � | j  |  j |  j d � � | j  |  j �  � | j  |  j |  j d
   t   curse_new_line(   R   R   t   ret(    (    sF   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_help.pyt	   msg_cursel   s�     N(
   t   __name__t
   __module__t   __doc__t   NoneR   R
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""Alert plugin."""

from datetime import datetime

from glances.logs import glances_logs
from glances.plugins.glances_plugin import GlancesPlugin


class Plugin(GlancesPlugin):

    """Glances alert plugin.

    Only for display.
    """

    def __init__(self, args=None):
        """Init the plugin."""
        super(Plugin, self).__init__(args=args)

        # We want to display the stat in the curse interface
        self.display_curse = True

        # Set the message position
        self.align = 'bottom'

        # Init the stats
        self.reset()

    def reset(self):
        """Reset/init the stats."""
        self.stats = []

    def update(self):
        """Nothing to do here. Just return the global glances_log."""
        # Set the stats to the glances_logs
        self.stats = glances_logs.get()

    def msg_curse(self, args=None):
        """Return the dict to display in the curse interface."""
        # Init the return message
        ret = []

        # Only process if display plugin enable...
        if not self.stats and self.is_disable():
            return ret

        # Build the string message
        # Header
        if not self.stats:
            msg = 'No warning or critical alert detected'
            ret.append(self.curse_add_line(msg, "TITLE"))
        else:
            # Header
            msg = 'Warning or critical alerts'
            ret.append(self.curse_add_line(msg, "TITLE"))
            logs_len = glances_logs.len()
            if logs_len > 1:
                msg = ' (last {} entries)'.format(logs_len)
            else:
                msg = ' (one entry)'
            ret.append(self.curse_add_line(msg, "TITLE"))
            # Loop over alerts
            for alert in self.stats:
                # New line
                ret.append(self.curse_new_line())
                # Start
                msg = str(datetime.fromtimestamp(alert[0]))
                ret.append(self.curse_add_line(msg))
                # Duration
                if alert[1] > 0:
                    # If finished display duration
                    msg = ' ({})'.format(datetime.fromtimestamp(alert[1]) -
                                         datetime.fromtimestamp(alert[0]))
                else:
                    msg = ' (ongoing)'
                ret.append(self.curse_add_line(msg))
                ret.append(self.curse_add_line(" - "))
                # Infos
                if alert[1] > 0:
                    # If finished do not display status
                    msg = '{} on {}'.format(alert[2], alert[3])
                    ret.append(self.curse_add_line(msg))
                else:
                    msg = str(alert[3])
                    ret.append(self.curse_add_line(msg, decoration=alert[2]))
                # Min / Mean / Max
                if self.approx_equal(alert[6], alert[4], tolerance=0.1):
                    msg = ' ({:.1f})'.format(alert[5])
                else:
                    msg = ' (Min:{:.1f} Mean:{:.1f} Max:{:.1f})'.format(
                        alert[6], alert[5], alert[4])
                ret.append(self.curse_add_line(msg))
                # Top processes
                top_process = ', '.join([p['name'] for p in alert[9]])
                if top_process != '':
                    msg = ': {}'.format(top_process)
                    ret.append(self.curse_add_line(msg))

        return ret

    def approx_equal(self, a, b, tolerance=0.0):
        """Compare a with b using the tolerance (if numerical)."""
        if str(int(a)).isdigit() and str(int(b)).isdigit():
            return abs(a - b) <= max(abs(a), abs(b)) * tolerance
        else:
            return a == b
                                                                                                                                                                   ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_folders.pyc                         0000664 0000000 0000000 00000006776 13070471670 024034  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   sL   d  Z  d d l Z d d l m Z d d l m Z d e f d �  �  YZ d S(   s   Folder plugin.i����N(   t
   FolderList(   t
 d �  � � Z d �  Z d d � Z
   /   s    c         C   s   t  | � |  _ d S(   s:   Load the foldered list from the config file, if it exists.N(   t   glancesFolderListR	   (   R   t   config(    (    sI   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_folders.pyt   load_limits3   s    c         C   sX   |  j  �  |  j d k rQ |  j d k r/ |  j S|  j j �  |  j j �  |  _ n  |  j S(   s   Update the foldered list.t   localN(   R
   t   input_methodR	   R   R   t   updatet   get(   R   (    (    sI   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_folders.pyR   7   s    

 } n  | S(   s    Manage limits of the folder listt   sizet   DEFAULTt   OKt   criticali@B t   CRITICALt   warningt   WARNINGt   carefult   CAREFULN(   t
   isinstancet   numberst   NumberR   t   int(   R   t   statt   ret(    (    sI   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_folders.pyt	   get_alertN   s    .	.	.	c         C   s<  g  } |  j  s |  j �  r  | Sd j d � } | j |  j | d � � x� |  j  D]� } | j |  j �  � t | d � d k r� d | d d } n
 | d } d	 j | � } | j |  j | � � y  d
 j |  j | d � � } Wn* t t	 f k
 rd
 j | d � } n X| j |  j | |  j
 | � � � qR W| S(
   is_disablet   formatt   appendt   curse_add_linet   curse_new_linet   lent	   auto_unitt	   TypeErrort
   ValueErrorR%   (   R   R   R$   t   msgt   iR   (    (    sI   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_folders.pyt	   msg_curse_   s$    
 &N(   t   __name__t
   __module__t   __doc__R   R   R
   R   R   t   _check_decoratort   _log_result_decoratorR   R%   R4   (    (    (    sI   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_folders.pyR      s   				(   R7   R    t   glances.folder_listR    R   t   glances.plugins.glances_pluginR   R   (    (    (    sI   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_folders.pyt   <module>   s     ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_sensors.pyc                         0000664 0000000 0000000 00000021020 13070471670 024045  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   s�   d  Z  d d l Z d d l m Z d d l m Z d d l m Z d d l	 m Z
 d d l m Z d Z
 e f d �  �  YZ d e f d
 d �  Z d �  Z d d � Z

    The stats list includes both sensors and hard disks stats, if any.
    The sensors are already grouped by chip type and then sorted by name.
    The hard disks are already sorted by name.
    c         C   s`   t  t |  � j d | � t �  |  _ t d | � |  _ t d | � |  _ t	 |  _
 |  j �  d S(   s   Init the plugin.t   argsN(   t   superR   t   __init__t   GlancesGrabSensorst   glancesgrabsensorst
   0   s    	c         C   s   d S(   s   Return the key of the list.t   label(    (   R   (    (    sI   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_sensors.pyt   get_keyE   s    c         C   s
 rj } t j d | � n X|  j j	 | � y" |  j |  j j d � d � } Wn$ t k
 r� } t j d | � n X|  j j	 | � y |  j |  j
 j �  d � } Wn$ t k
 r} t j d | � n X|  j j	 | � y |  j |  j j �  d � } Wn$ t k
 ro} t j d	 | � q�X|  j j	 | � n |  j d
 k r�n  |  j S(   s,   Update sensors stats using the input method.t   localt   temperature_cores%   Cannot grab sensors temperatures (%s)t	   fan_speeds   Cannot grab FAN speed (%s)t   temperature_hdds    Cannot grab HDD temperature (%s)t   batterys    Cannot grab battery percent (%s)t   snmp(
   batpercent(    (    sI   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_sensors.pyR$   M   s<    
	

        4 types of stats is possible in the sensors plugin:
        - Core temperature: 'temperature_core'
        - Fan speed: 'fan_speed'
        - HDD temperature: 'temperature_hdd'
        - Battery capacity: 'battery'
        t   typet   key(   R$   R   (   R   R   t   sensor_typet   i(    (    sI   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_sensors.pyt
   __set_type�   s    	
   decorationN(   R	   R   t   update_viewsR   t	   get_alertt   viewsR   (   R   R,   (    (    sI   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_sensors.pyR1   �   s    
=c         C   s9  g  } |  j  s | j r | Sd j d � } | j |  j | d � � x�|  j  D]�} | d d k r{ | d g  k r{ qO n  | j |  j �  � |  j | d j �  � } | d k r� | d } n  | d d k r� d	 j | d
  � } n d j | d  � } | j |  j | � � | d d k rpd j | d � } | j |  j | |  j	 d | |  j
 �  d d d d � � � qO | j r�| d d k r�| d d k r�t | d � } d } n | d } | d } yQ d j | | � } | j |  j | |  j	 d | |  j
 �  d d d d � � � WqO t
 r0qO XqO W| S(   s2   Return the dict to display in the curse interface.s   {:18}t   SENSORSt   TITLER)   R   R.   R   R   s   {:15}i   s   {:13}i
   {:>7.0f}{}N(   R6   R7   R8   R9   (   R   t   disable_sensorst   formatt   appendt   curse_add_linet   curse_new_linet	   has_aliast   lowert   Nonet	   get_viewsR   t
   fahrenheitR   t	   TypeErrort
   ValueError(   R   R   t   rett   msgR,   R   R.   R=   (    (    sI   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_sensors.pyt	   msg_curse�   sJ     

N(   t   __name__t
   __module__t   __doc__RE   R
   R   R   R   t   _check_decoratort   _log_result_decoratorR$   R   R1   RL   (    (    (    sI   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_sensors.pyR   '   s   		7		R   c           B   s>   e  Z d  Z d �  Z d �  Z d �  Z d �  Z d d � Z RS(   s   Get sensors stats.c         C   s  t  |  _ i  |  _ y t j �  |  _ WnF t k
 rE t j d � n2 t k
 rm } t j	 d j
 | � � n
 Xt |  _ t  |  _ i  |  _
 r� t j d � n2 t k
 r� } t j	 d j
 | � � n
 Xt |  _ t  |  _ |  j �  d S(   s   Init sensors stats.s=   PsUtil 5.1.0 or higher is needed to grab temperatures sensorss&   Can not grab temperatures sensors ({})s5   PsUtil 5.2.0 or higher is needed to grab fans sensorss   Can not grab fans sensors ({})N(   t   Falset	   init_tempt   stempst   psutilt   sensors_temperaturest   AttributeErrorR    t   warningt   OSErrorR"   R?   R   t   init_fant   sfanst   sensors_fansR   (   R   R&   (    (    sI   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_sensors.pyR
   �   s(    		
   __update__  s    
	c   	      C   s  g  } | t  k r6 |  j r6 |  j } t j �  |  _ n4 | t k rf |  j rf |  j } t j �  |  _ n | Sx� t	 | � D]� \ } } d } x | D]w } i  } | j
 d k r� | d t | � | d <n
 | d <t | j

        type: SENSOR_TEMP_UNIT or SENSOR_FAN_UNIT

        output: a listi   t    t    R   R.   R=   (   R_   RS   RT   RU   RV   R`   RZ   R[   R\   R   R   t   strt   intt   currentR@   (	   R   R)   RJ   t
   input_listt   chipnamet   chipR,   t   featuret   sensors_current(    (    sI   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_sensors.pyR^     s(    		

//(   RM   RN   RO   R
   R   Ra   R^   R    (    (    (    sI   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_sensors.pyR   �   s   	$			 (   RO   RU   t   glances.loggerR    t   glances.compatR   t"   glances.plugins.glances_batpercentR   R   t   glances.plugins.glances_hddtempR
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""System plugin."""

import os
import platform
import re
from io import open

from glances.compat import iteritems
from glances.plugins.glances_plugin import GlancesPlugin

# SNMP OID
snmp_oid = {'default': {'hostname': '1.3.6.1.2.1.1.5.0',
                        'system_name': '1.3.6.1.2.1.1.1.0'},
            'netapp': {'hostname': '1.3.6.1.2.1.1.5.0',
                       'system_name': '1.3.6.1.2.1.1.1.0',
                       'platform': '1.3.6.1.4.1.789.1.1.5.0'}}

# SNMP to human read
# Dict (key: OS short name) of dict (reg exp OID to human)
# Windows:
# http://msdn.microsoft.com/en-us/library/windows/desktop/ms724832%28v=vs.85%29.aspx
snmp_to_human = {'windows': {'Windows Version 10.0': 'Windows 10 or Server 2016',
                             'Windows Version 6.3': 'Windows 8.1 or Server 2012R2',
                             'Windows Version 6.2': 'Windows 8 or Server 2012',
                             'Windows Version 6.1': 'Windows 7 or Server 2008R2',
                             'Windows Version 6.0': 'Windows Vista or Server 2008',
                             'Windows Version 5.2': 'Windows XP 64bits or 2003 server',
                             'Windows Version 5.1': 'Windows XP',
                             'Windows Version 5.0': 'Windows 2000'}}


def _linux_os_release():
    """Try to determine the name of a Linux distribution.

    This function checks for the /etc/os-release file.
    It takes the name from the 'NAME' field and the version from 'VERSION_ID'.
    An empty string is returned if the above values cannot be determined.
    """
    pretty_name = ''
    ashtray = {}
    keys = ['NAME', 'VERSION_ID']
    try:
        with open(os.path.join('/etc', 'os-release')) as f:
            for line in f:
                for key in keys:
                    if line.startswith(key):
                        ashtray[key] = re.sub(r'^"|"$', '', line.strip().split('=')[1])
    except (OSError, IOError):
        return pretty_name

    if ashtray:
        if 'NAME' in ashtray:
            pretty_name = ashtray['NAME']
        if 'VERSION_ID' in ashtray:
            pretty_name += ' {}'.format(ashtray['VERSION_ID'])

    return pretty_name


class Plugin(GlancesPlugin):

    """Glances' host/system plugin.

    stats is a dict
    """

    def __init__(self, args=None):
        """Init the plugin."""
        super(Plugin, self).__init__(args=args)

        # We want to display the stat in the curse interface
        self.display_curse = True

        # Init the stats
        self.reset()

    def reset(self):
        """Reset/init the stats."""
        self.stats = {}

    @GlancesPlugin._check_decorator
    @GlancesPlugin._log_result_decorator
    def update(self):
        """Update the host/system info using the input method.

        Return the stats (dict)
        """
        # Reset stats
        self.reset()

        if self.input_method == 'local':
            # Update stats using the standard system lib
            self.stats['os_name'] = platform.system()
            self.stats['hostname'] = platform.node()
            self.stats['platform'] = platform.architecture()[0]
            if self.stats['os_name'] == "Linux":
                try:
                    linux_distro = platform.linux_distribution()
                except AttributeError:
                    self.stats['linux_distro'] = _linux_os_release()
                else:
                    if linux_distro[0] == '':
                        self.stats['linux_distro'] = _linux_os_release()
                    else:
                        self.stats['linux_distro'] = ' '.join(linux_distro[:2])
                self.stats['os_version'] = platform.release()
            elif (self.stats['os_name'].endswith('BSD') or
                  self.stats['os_name'] == 'SunOS'):
                self.stats['os_version'] = platform.release()
            elif self.stats['os_name'] == "Darwin":
                self.stats['os_version'] = platform.mac_ver()[0]
            elif self.stats['os_name'] == "Windows":
                os_version = platform.win32_ver()
                self.stats['os_version'] = ' '.join(os_version[::2])
                # if the python version is 32 bit perhaps the windows operating
                # system is 64bit
                if self.stats['platform'] == '32bit' and 'PROCESSOR_ARCHITEW6432' in os.environ:
                    self.stats['platform'] = '64bit'
            else:
                self.stats['os_version'] = ""
            # Add human readable name
            if self.stats['os_name'] == "Linux":
                self.stats['hr_name'] = self.stats['linux_distro']
            else:
                self.stats['hr_name'] = '{} {}'.format(
                    self.stats['os_name'], self.stats['os_version'])
            self.stats['hr_name'] += ' {}'.format(self.stats['platform'])

        elif self.input_method == 'snmp':
            # Update stats using SNMP
            try:
                self.stats = self.get_stats_snmp(
                    snmp_oid=snmp_oid[self.short_system_name])
            except KeyError:
                self.stats = self.get_stats_snmp(snmp_oid=snmp_oid['default'])
            # Default behavor: display all the information
            self.stats['os_name'] = self.stats['system_name']
            # Windows OS tips
            if self.short_system_name == 'windows':
                for r, v in iteritems(snmp_to_human['windows']):
                    if re.search(r, self.stats['system_name']):
                        self.stats['os_name'] = v
                        break
            # Add human readable name
            self.stats['hr_name'] = self.stats['os_name']

        return self.stats

    def msg_curse(self, args=None):
        """Return the string to display in the curse interface."""
        # Init the return message
        ret = []

        # Build the string message
        if args.client:
            # Client mode
            if args.cs_status.lower() == "connected":
                msg = 'Connected to '
                ret.append(self.curse_add_line(msg, 'OK'))
            elif args.cs_status.lower() == "snmp":
                msg = 'SNMP from '
                ret.append(self.curse_add_line(msg, 'OK'))
            elif args.cs_status.lower() == "disconnected":
                msg = 'Disconnected from '
                ret.append(self.curse_add_line(msg, 'CRITICAL'))

        # Hostname is mandatory
        msg = self.stats['hostname']
        ret.append(self.curse_add_line(msg, "TITLE"))
        # System info
        if self.stats['os_name'] == "Linux" and self.stats['linux_distro']:
            msg = ' ({} {} / {} {})'.format(self.stats['linux_distro'],
                                            self.stats['platform'],
                                            self.stats['os_name'],
                                            self.stats['os_version'])
        else:
            try:
                msg = ' ({} {} {})'.format(self.stats['os_name'],
                                           self.stats['os_version'],
                                           self.stats['platform'])
            except Exception:
                msg = ' ({})'.format(self.stats['os_name'])
        ret.append(self.curse_add_line(msg, optional=True))

        # Return the message with decoration
        return ret
                                                       ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_amps.pyc                            0000664 0000000 0000000 00000006640 13070471670 023324  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   sP   d  Z  d d l m Z d d l m Z d d l m Z d e f d �  �  YZ d S(   s   Monitor plugin.i����(   t	   iteritems(   t   AmpsList(   t
 d � Z d d � Z RS(	   s   Glances AMPs plugin.c         C   sZ   t  t |  � j d | � | |  _ | |  _ t |  _ t |  j |  j � |  _ |  j	 �  d S(   s   Init the plugin.t   argsN(
   t   superR   t   __init__R   t   configt   Truet
 �  d 6| j �  d 6| j �  d 6| j
   s   Update the AMP list.t   localt   keyt   namet   resultt   refresht   timert   countt   countmint   countmax(   R   t   input_methodR    R   t   updateR   t   appendt   NAMER   R   t   time_until_refreshR   t	   count_mint	   count_max(   R
"

 } } | j |  j | d t	 �� | j |  j
 �  � q� Wq3 Wy | j �  Wn t k
 r_n X| S(
s   {:<16} s   {:<4} R!   t
   splittableN(
   is_disableR%   t   formatR*   t   splitR   t   curse_add_lineR   t   curse_new_linet   popt
   IndexError(	   R

   __module__t   __doc__R%   R   R   R   t   _check_decoratort   _log_result_decoratorR   t   FalseR*   R;   (    (    (    sF   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_amps.pyR      s   	N(	   R>   t   glances.compatR    t   glances.amps_listR   R
   t   glances.plugins.glances_pluginR   R   (    (    (    sF   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_amps.pyt   <module>   s                                                                                                   ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_folders.py                          0000664 0000000 0000000 00000007547 13066703446 023672  0                                                                                                    ustar                                                                                                                                                                                                                                                          # -*- coding: utf-8 -*-
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""Folder plugin."""

import numbers

from glances.folder_list import FolderList as glancesFolderList
from glances.plugins.glances_plugin import GlancesPlugin


class Plugin(GlancesPlugin):

    """Glances folder plugin."""

    def __init__(self, args=None):
        """Init the plugin."""
        super(Plugin, self).__init__(args=args)

        # We want to display the stat in the curse interface
        self.display_curse = True

        # Init stats
        self.glances_folders = None
        self.reset()

    def get_key(self):
        """Return the key of the list."""
        return 'path'

    def reset(self):
        """Reset/init the stats."""
        self.stats = []

    def load_limits(self, config):
        """Load the foldered list from the config file, if it exists."""
        self.glances_folders = glancesFolderList(config)

    @GlancesPlugin._check_decorator
    @GlancesPlugin._log_result_decorator
    def update(self):
        """Update the foldered list."""
        # Reset the list
        self.reset()

        if self.input_method == 'local':
            # Folder list only available in a full Glances environment
            # Check if the glances_folder instance is init
            if self.glances_folders is None:
                return self.stats

            # Update the foldered list (result of command)
            self.glances_folders.update()

            # Put it on the stats var
            self.stats = self.glances_folders.get()
        else:
            pass

        return self.stats

    def get_alert(self, stat):
        """Manage limits of the folder list"""

        if not isinstance(stat['size'], numbers.Number):
            return 'DEFAULT'
        else:
            ret = 'OK'

        if stat['critical'] is not None and stat['size'] > int(stat['critical']) * 1000000:
            ret = 'CRITICAL'
        elif stat['warning'] is not None and stat['size'] > int(stat['warning']) * 1000000:
            ret = 'WARNING'
        elif stat['careful'] is not None and stat['size'] > int(stat['careful']) * 1000000:
            ret = 'CAREFUL'

        return ret

    def msg_curse(self, args=None):
        """Return the dict to display in the curse interface."""
        # Init the return message
        ret = []

        # Only process if stats exist and display plugin enable...
        if not self.stats or self.is_disable():
            return ret

        # Build the string message
        # Header
        msg = '{}'.format('FOLDERS')
        ret.append(self.curse_add_line(msg, "TITLE"))

        # Data
        for i in self.stats:
            ret.append(self.curse_new_line())
            if len(i['path']) > 15:
                # Cut path if it is too long
                path = '_' + i['path'][-15 + 1:]
            else:
                path = i['path']
            msg = '{:<16} '.format(path)
            ret.append(self.curse_add_line(msg))
            try:
                msg = '{:>6}'.format(self.auto_unit(i['size']))
            except (TypeError, ValueError):
                msg = '{:>6}'.format(i['size'])
            ret.append(self.curse_add_line(msg, self.get_alert(i)))

        return ret
                                                                                                                                                         ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_ip.pyc                              0000664 0000000 0000000 00000013720 13070471670 022771  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   s#  d  Z  d d l Z d d l m Z d d l m Z m Z m Z d d l m	 Z	 d d l
 m Z d d l m
 r� e Z q� Xn e Z d	 e d f d
 e d f d e d
   IP plugin.i����N(   t   loads(   t   iterkeyst   urlopent   queue(   t   BSD(   t   logger(   t   Timer(   t
 d d � Z e d �  � Z

    stats is a dict
    c         C   sB   t  t |  � j d | � t |  _ t �  j �  |  _ |  j �  d S(   s   Init the plugin.t   argsN(	   t   superR
   t   __init__t   Truet
 rk } t j	 d j
 | � � qXXy� t j | d � t j d d |  j d <t j | d � t j d d |  j d	 <|  j
 <t j �  d t j d |  j d <|  j |  j d <WqXt t f k
 rB} t j	 d
 | � � qXXn |  j d k rXn  |  j S(   sG   Update IP stats using the input method.

        Stats is dict
        t   localt   defaults$   Cannot grab the default gateway ({})i   i    t   addrt   addresst   netmaskt   maskt	   mask_cidrt   gatewayR   s   Cannot grab IP information: {}t   snmp(   R   t   input_methodt
   ip_to_cidrR   (   R   t
   default_gwt   e(    (    sD   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_ip.pyt   updateN   s"    
))"c         C   sB   t  t |  � j �  x( t |  j � D] } t |  j | d <q# Wd S(   s   Update stats views.t   optionalN(   R   R
   t   update_viewsR   R   R   t   views(   R   t   key(    (    sD   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_ip.pyR.   n   s    c         C   sB  g  } |  j  s |  j �  r  | Sd } | j |  j | � � d } | j |  j | d � � d j |  j  d � } | j |  j | � � d |  j  k r� d j |  j  d � } | j |  j | � � n  y d j |  j  d � } Wn t k
 r� nL X|  j  d d
 k	 r>d	 } | j |  j | d � � | j |  j | � � n  | S(   s2   Return the dict to display in the curse interface.s    - s   IP t   TITLEs   {}R   R   s   /{}R   s    Pub N(   R   t
   is_disablet   appendt   curse_add_lineR'   t   UnicodeEncodeErrort   None(   R   R   t   rett   msgt   msg_pub(    (    sD   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_ip.pyt	   msg_cursex   s*    

        Example: '255.255.255.0' will return 24
        t   .i   i�  (   t   sumt   splitt   int(   R	   t   x(    (    sD   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_ip.pyR)   �   s    N(   t   __name__t
   __module__t   __doc__R6   R
   6   s   
 R   c           B   s2   e  Z d  Z d d � Z d �  Z e d d � Z RS(   s*   Get public IP address from online servicesi   c         C   s
 � } d } x> | j �  r� | d k r� | j
 rc } t j d j | | � � | j d � nS Xy1 | s} | j | � n | j t
 | � | � Wn t k
 r� | j d � n Xd S(   s>   Request the url service and put the result in the queue_targetRF   s   utf-8s#   IP plugin - Cannot open URL {} ({})N(   R   RF   t   readt   decodet	   ExceptionR   R&   R'   t   putR6   R    t
   ValueError(   R   t   queue_targett   urlt   jsonR0   t   responseR+   (    (    sD   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_ip.pyRL   �   s    (
   t   objectR   (    (    (    sD   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_ip.pyt   <module>   s(   

#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""Ports scanner plugin."""

import os
import subprocess
import threading
import socket
import time

from glances.globals import WINDOWS
from glances.ports_list import GlancesPortsList
from glances.timer import Timer, Counter
from glances.compat import bool_type
from glances.logger import logger
from glances.plugins.glances_plugin import GlancesPlugin


class Plugin(GlancesPlugin):

    """Glances ports scanner plugin."""

    def __init__(self, args=None, config=None):
        """Init the plugin."""
        super(Plugin, self).__init__(args=args)
        self.args = args
        self.config = config

        # We want to display the stat in the curse interface
        self.display_curse = True

        # Init stats
        self.stats = GlancesPortsList(config=config, args=args).get_ports_list()

        # Init global Timer
        self.timer_ports = Timer(0)

        # Global Thread running all the scans
        self._thread = None

    def exit(self):
        """Overwrite the exit method to close threads"""
        if self._thread is not None:
            self._thread.stop()
        # Call the father class
        super(Plugin, self).exit()

    def reset(self):
        """Reset/init the stats."""
        self.stats = []

    @GlancesPlugin._log_result_decorator
    def update(self):
        """Update the ports list."""

        if self.input_method == 'local':
            # Only refresh:
            # * if there is not other scanning thread
            # * every refresh seconds (define in the configuration file)
            if self._thread is None:
                thread_is_running = False
            else:
                thread_is_running = self._thread.isAlive()
            if self.timer_ports.finished() and not thread_is_running:
                # Run ports scanner
                self._thread = ThreadScanner(self.stats)
                self._thread.start()
                # Restart timer
                if len(self.stats) > 0:
                    self.timer_ports = Timer(self.stats[0]['refresh'])
                else:
                    self.timer_ports = Timer(0)
        else:
            # Not available in SNMP mode
            pass

        return self.stats

    def get_alert(self, port, header="", log=False):
        """Return the alert status relative to the port scan return value."""

        if port['status'] is None:
            return 'CAREFUL'
        elif port['status'] == 0:
            return 'CRITICAL'
        elif (isinstance(port['status'], (float, int)) and
              port['rtt_warning'] is not None and
              port['status'] > port['rtt_warning']):
            return 'WARNING'

        return 'OK'

    def msg_curse(self, args=None):
        """Return the dict to display in the curse interface."""
        # Init the return message
        # Only process if stats exist and display plugin enable...
        ret = []

        if not self.stats or args.disable_ports:
            return ret

        # Build the string message
        for p in self.stats:
            if p['host'] is None:
                status = 'None'
            elif p['status'] is None:
                status = 'Scanning'
            elif isinstance(p['status'], bool_type) and p['status'] is True:
                status = 'Open'
            elif p['status'] == 0:
                status = 'Timeout'
            else:
                # Convert second to ms
                status = '{0:.0f}ms'.format(p['status'] * 1000.0)

            msg = '{:14.14} '.format(p['description'])
            ret.append(self.curse_add_line(msg))
            msg = '{:>8}'.format(status)
            ret.append(self.curse_add_line(msg, self.get_alert(p)))
            ret.append(self.curse_new_line())

        # Delete the last empty line
        try:
            ret.pop()
        except IndexError:
            pass

        return ret

    def _port_scan_all(self, stats):
        """Scan all host/port of the given stats"""
        for p in stats:
            self._port_scan(p)
            # Had to wait between two scans
            # If not, result are not ok
            time.sleep(1)


class ThreadScanner(threading.Thread):
    """
    Specific thread for the port scanner.

    stats is a list of dict
    """

    def __init__(self, stats):
        """Init the class"""
        logger.debug("ports plugin - Create thread for scan list {}".format(stats))
        super(ThreadScanner, self).__init__()
        # Event needed to stop properly the thread
        self._stopper = threading.Event()
        # The class return the stats as a list of dict
        self._stats = stats
        # Is part of Ports plugin
        self.plugin_name = "ports"

    def run(self):
        """Function called to grab stats.
        Infinite loop, should be stopped by calling the stop() method"""

        for p in self._stats:
            self._port_scan(p)
            if self.stopped():
                break
            # Had to wait between two scans
            # If not, result are not ok
            time.sleep(1)

    @property
    def stats(self):
        """Stats getter"""
        return self._stats

    @stats.setter
    def stats(self, value):
        """Stats setter"""
        self._stats = value

    def stop(self, timeout=None):
        """Stop the thread"""
        logger.debug("ports plugin - Close thread for scan list {}".format(self._stats))
        self._stopper.set()

    def stopped(self):
        """Return True is the thread is stopped"""
        return self._stopper.isSet()

    def _port_scan(self, port):
        """Scan the port structure (dict) and update the status key"""
        if int(port['port']) == 0:
            return self._port_scan_icmp(port)
        else:
            return self._port_scan_tcp(port)

    def _resolv_name(self, hostname):
        """Convert hostname to IP address"""
        ip = hostname
        try:
            ip = socket.gethostbyname(hostname)
        except Exception as e:
            logger.debug("{}: Cannot convert {} to IP address ({})".format(self.plugin_name, hostname, e))
        return ip

    def _port_scan_icmp(self, port):
        """Scan the (ICMP) port structure (dict) and update the status key"""
        ret = None

        # Create the ping command
        # Use the system ping command because it already have the steacky bit set
        # Python can not create ICMP packet with non root right
        cmd = ['ping', '-n' if WINDOWS else '-c', '1', self._resolv_name(port['host'])]
        fnull = open(os.devnull, 'w')

        try:
            counter = Counter()
            ret = subprocess.check_call(cmd, stdout=fnull, stderr=fnull, close_fds=True)
            if ret == 0:
                port['status'] = counter.get()
            else:
                port['status'] = False
        except Exception as e:
            logger.debug("{}: Error while pinging host {} ({})".format(self.plugin_name, port['host'], e))

        return ret

    def _port_scan_tcp(self, port):
        """Scan the (TCP) port structure (dict) and update the status key"""
        ret = None

        # Create and configure the scanning socket
        try:
            socket.setdefaulttimeout(port['timeout'])
            _socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        except Exception as e:
            logger.debug("{}: Error while creating scanning socket".format(self.plugin_name))

        # Scan port
        ip = self._resolv_name(port['host'])
        counter = Counter()
        try:
            ret = _socket.connect_ex((ip, int(port['port'])))
        except Exception as e:
            logger.debug("{}: Error while scanning port {} ({})".format(self.plugin_name, port, e))
        else:
            if ret == 0:
                port['status'] = counter.get()
            else:
                port['status'] = False
        finally:
            _socket.close()

        return ret
           ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_alert.pyc                           0000664 0000000 0000000 00000006570 13070471670 023475  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   sP   d  Z  d d l m Z d d l m Z d d l m Z d e f d �  �  YZ d S(   s

    Only for display.
    c         C   s9   t  t |  � j d | � t |  _ d |  _ |  j �  d S(   s   Init the plugin.t   argst   bottomN(   t   superR   t   __init__t   Truet
 | d � � } | j |  j | � � | d d k rEd j t	 j
 | d � t	 j
 | d � � } n d	 } | j |  j | � � | j |  j d
 � � | d d k r�d j | d | d
    (ongoing)s    - s   {} on {}i   i   t
   decorationi   i   t	   toleranceg�������?s	    ({:.1f})i   s$    (Min:{:.1f} Mean:{:.1f} Max:{:.1f})s   , i	   t   namet    s   : {}(
   is_disablet   appendt   curse_add_lineR   t   lent   formatt   curse_new_linet   strR    t
   __module__t   __doc__t   NoneR   R   R   R%   R   (    (    (    sG   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_alert.pyR      s   
&��Xc           @   s:   d  d l  m Z d  d l m Z d e f d �  �  YZ d S(   i����(   t   psutil_version_info(   t

    stats is a tuple
    c         C   s'   t  t |  � j d | � |  j �  d S(   s   Init the plugin.t   argsN(   t   superR   t   __init__t   reset(   t   selfR   (    (    sO   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_psutilversion.pyR      s    c         C   s
 r9 q= Xn  |  j S(   s   Update the stats.t   local(   R   t   input_methodR    R	   t	   NameError(   R   (    (    sO   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_psutilversion.pyt   update(   s    

   t   __name__t
   __module__t   __doc__R   R   R   R   t   _check_decoratort   _log_result_decoratorR
   	N(   t   glancesR    t   glances.plugins.glances_pluginR   R   (    (    (    sO   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_psutilversion.pyt   <module>   s                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_irq.py                              0000664 0000000 0000000 00000015241 13066703446 023015  0                                                                                                    ustar                                                                                                                                                                                                                                                          # -*- coding: utf-8 -*-
#
# This file is part of Glances.
#
# Copyright (C) 2017 Angelo Poerio <angelo.poerio@gmail.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""IRQ plugin."""

import os
import operator

from glances.globals import LINUX
from glances.timer import getTimeSinceLastUpdate
from glances.plugins.glances_plugin import GlancesPlugin


class Plugin(GlancesPlugin):

    """Glances IRQ plugin.

    stats is a list
    """

    def __init__(self, args=None):
        """Init the plugin."""
        super(Plugin, self).__init__(args=args)

        # We want to display the stat in the curse interface
        self.display_curse = True

        # Init the stats
        self.irq = GlancesIRQ()
        self.reset()

    def get_key(self):
        """Return the key of the list."""
        return self.irq.get_key()

    def reset(self):
        """Reset/init the stats."""
        self.stats = []

    @GlancesPlugin._check_decorator
    @GlancesPlugin._log_result_decorator
    def update(self):
        """Update the IRQ stats"""

        # Reset the list
        self.reset()

        # IRQ plugin only available on GNU/Linux
        if not LINUX:
            return self.stats

        if self.input_method == 'local':
            # Grab the stats
            self.stats = self.irq.get()

        elif self.input_method == 'snmp':
            # not available
            pass

        # Get the TOP 5
        self.stats = sorted(self.stats, key=operator.itemgetter(
            'irq_rate'), reverse=True)[:5]  # top 5 IRQ by rate/s

        return self.stats

    def update_views(self):
        """Update stats views."""
        # Call the father's method
        super(Plugin, self).update_views()

    def msg_curse(self, args=None, max_width=None):
        """Return the dict to display in the curse interface."""
        # Init the return message
        ret = []

        # Only available on GNU/Linux
        # Only process if stats exist and display plugin enable...
        if not LINUX or not self.stats or not self.args.enable_irq:
            return ret

        if max_width is not None and max_width >= 23:
            irq_max_width = max_width - 14
        else:
            irq_max_width = 9

        # Build the string message
        # Header
        msg = '{:{width}}'.format('IRQ', width=irq_max_width)
        ret.append(self.curse_add_line(msg, "TITLE"))
        msg = '{:>14}'.format('Rate/s')
        ret.append(self.curse_add_line(msg))

        for i in self.stats:
            ret.append(self.curse_new_line())
            msg = '{:<15}'.format(i['irq_line'][:15])
            ret.append(self.curse_add_line(msg))
            msg = '{:>8}'.format(str(i['irq_rate']))
            ret.append(self.curse_add_line(msg))

        return ret


class GlancesIRQ(object):
    """
    This class manages the IRQ file
    """

    IRQ_FILE = '/proc/interrupts'

    def __init__(self):
        """
        Init the class
        The stat are stored in a internal list of dict
        """
        self.lasts = {}
        self.reset()

    def reset(self):
        """Reset the stats"""
        self.stats = []
        self.cpu_number = 0

    def get(self):
        """Return the current IRQ stats"""
        return self.__update()

    def get_key(self):
        """Return the key of the dict."""
        return 'irq_line'

    def __header(self, line):
        """The header contain the number of CPU

        CPU0       CPU1       CPU2       CPU3
        0:         21          0          0          0   IO-APIC   2-edge      timer
        """
        self.cpu_number = len(line.split())
        return self.cpu_number

    def __humanname(self, line):
        """Get a line and
        Return the IRQ name, alias or number (choose the best for human)

        IRQ line samples:
        1:      44487        341         44         72   IO-APIC   1-edge      i8042
        LOC:   33549868   22394684   32474570   21855077   Local timer interrupts
        """
        splitted_line = line.split()
        irq_line = splitted_line[0].replace(':', '')
        if irq_line.isdigit():
            # If the first column is a digit, use the alias (last column)
            irq_line += '_{}'.format(splitted_line[-1])
        return irq_line

    def __sum(self, line):
        """Get a line and
        Return the IRQ sum number

        IRQ line samples:
        1:     44487        341         44         72   IO-APIC   1-edge      i8042
        LOC:   33549868   22394684   32474570   21855077   Local timer interrupts
        FIQ:   usb_fiq
        """
        splitted_line = line.split()
        try:
            ret = sum(map(int, splitted_line[1:(self.cpu_number + 1)]))
        except ValueError:
            # Correct issue #1007 on some conf (Raspberry Pi with Raspbian)
            ret = 0
        return ret

    def __update(self):
        """
        Load the IRQ file and update the internal dict
        """

        self.reset()

        if not os.path.exists(self.IRQ_FILE):
            # Correct issue #947: IRQ file do not exist on OpenVZ container
            return self.stats

        try:
            with open(self.IRQ_FILE) as irq_proc:
                time_since_update = getTimeSinceLastUpdate('irq')
                # Read the header
                self.__header(irq_proc.readline())
                # Read the rest of the lines (one line per IRQ)
                for line in irq_proc.readlines():
                    irq_line = self.__humanname(line)
                    current_irqs = self.__sum(line)
                    irq_rate = int(
                        current_irqs - self.lasts.get(irq_line)
                        if self.lasts.get(irq_line)
                        else 0 // time_since_update)
                    irq_current = {
                        'irq_line': irq_line,
                        'irq_rate': irq_rate,
                        'key': self.get_key(),
                        'time_since_update': time_since_update
                    }
                    self.stats.append(irq_current)
                    self.lasts[irq_line] = current_irqs
        except (OSError, IOError):
            pass

        return self.stats
                                                                                                                                                                                                                                                                                                                                                               ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_core.py                             0000664 0000000 0000000 00000004620 13066703446 023151  0                                                                                                    ustar                                                                                                                                                                                                                                                          # -*- coding: utf-8 -*-
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""CPU core plugin."""

from glances.plugins.glances_plugin import GlancesPlugin

import psutil


class Plugin(GlancesPlugin):

    """Glances CPU core plugin.

    Get stats about CPU core number.

    stats is integer (number of core)
    """

    def __init__(self, args=None):
        """Init the plugin."""
        super(Plugin, self).__init__(args=args)

        # We dot not want to display the stat in the curse interface
        # The core number is displayed by the load plugin
        self.display_curse = False

        # Init the stat
        self.reset()

    def reset(self):
        """Reset/init the stat using the input method."""
        self.stats = {}

    def update(self):
        """Update core stats.

        Stats is a dict (with both physical and log cpu number) instead of a integer.
        """
        # Reset the stats
        self.reset()

        if self.input_method == 'local':
            # Update stats using the standard system lib

            # The PSUtil 2.0 include psutil.cpu_count() and psutil.cpu_count(logical=False)
            # Return a dict with:
            # - phys: physical cores only (hyper thread CPUs are excluded)
            # - log: logical CPUs in the system
            # Return None if undefine
            try:
                self.stats["phys"] = psutil.cpu_count(logical=False)
                self.stats["log"] = psutil.cpu_count()
            except NameError:
                self.reset()

        elif self.input_method == 'snmp':
            # Update stats using SNMP
            # http://stackoverflow.com/questions/5662467/how-to-find-out-the-number-of-cpus-using-snmp
            pass

        return self.stats
                                                                                                                ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_percpu.pyc                          0000664 0000000 0000000 00000005523 13070471670 023661  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   s@   d  Z  d d l m Z d d l m Z d e f d �  �  YZ d S(   s   Per-CPU plugin.i����(   t   cpu_percent(   t
 d d � Z RS(   s~   Glances per-CPU plugin.

    'stats' is a list of dictionaries that contain the utilization percentages
    for each CPU.
    c         C   s0   t  t |  � j d | � t |  _ |  j �  d S(   s   Init the plugin.t   argsN(   t   superR   t   __init__t   Truet
   cpu_number(    (   R	   (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_percpu.pyt   get_key,   s    c         C   s
c      	   C   s�  g  } |  j  s2 d } | j |  j | d � � | Sd j d � } | j |  j | d � � xa |  j  D]V } y d j | d � } Wn  t k
 r� d j d � } n X| j |  j | � � qd Wx� d	 d
 d d d
 rxd j d � } n X| j |  j | |  j | | d | �� � q9Wq� W| S(   s2   Return the dict to display in the curse interface.s   PER CPU not availablet   TITLEs   {:8}s   PER CPUs   {:6.1f}%t   totals   {:>6}%t   ?t   usert   systemt   idlet   iowaitt   steali    t   :t   header(   R   t   appendt   curse_add_linet   formatt	   TypeErrort   curse_new_linet	   get_alert(   R	   R   t   rett   msgt   cput   stat(    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_percpu.pyt	   msg_curseE   s6    	
   __module__t   __doc__t   NoneR   R   R   R   t   _check_decoratort   _log_result_decoratorR   R&   (    (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_percpu.pyR      s   
		N(   R)   t   glances.cpu_percentR    t   glances.plugins.glances_pluginR   R   (    (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_percpu.pyt   <module>   s                                                                                                                                                                                ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_hddtemp.pyc                         0000664 0000000 0000000 00000010577 13070471670 024015  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   s�   d  Z  d d l Z d d l Z d d l m Z m Z d d l m Z d d l m	 Z	 d e	 f d �  �  YZ
 d e f d	 �  �  YZ d S(
   s   HDD temperature plugin.i����N(   t	   nativestrt   range(   t   logger(   t

    stats is a list
    c         C   sB   t  t |  � j d | � t d | � |  _ t |  _ |  j �  d S(   s   Init the plugin.t   argsN(   t   superR   t   __init__t   GlancesGrabHDDTempt   glancesgrabhddtempt   Falset
N(
   t   __name__t
   __module__t   __doc__t   NoneR   R   R   t   _check_decoratort   _log_result_decoratorR   (    (    (    sI   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_hddtemp.pyR      s
   	R   c           B   sD   e  Z d  Z d d d d � Z d �  Z d �  Z d �  Z d �  Z RS(	   s,   Get hddtemp stats using a socket connection.s	   127.0.0.1i�  c         C   s2   | |  _  | |  _ | |  _ d |  _ |  j �  d S(   s   Init hddtemp stats.t    N(   R   t   hostt   portt   cacheR   (   R
    				c         C   s
      C   sx  |  j  �  |  j �  } | d k r& d St | � d k  re t |  j � d k rV |  j n	 |  j �  } n  | |  _ y | j d � } Wn t k
 r� d } n Xt | � d d } x� t | � D]� } | d } i  } t j j	 t
 | | d � � } | | d } t
 | | d	 � }	 | | d
 <y t | � | d <Wn! t k
 rUt
 | � | d <n X|	 | d <|  j
   ValueErrorR   t   append(
   R
   __update__Z   s2    
-	

 

c         C   s�   z� yD t  j  t  j t  j � } | j |  j |  j f � | j d � } Wni t  j k
 r� } t j	 d j
 |  j |  j | � � t j	 d � |  j d k	 r� t
N(	   R   R   R   R   R   R   R4   R"   R   (    (    (    sI   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_hddtemp.pyR   J   s   		/	(
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""File system plugin."""

import operator

from glances.plugins.glances_plugin import GlancesPlugin

import psutil


# SNMP OID
# The snmpd.conf needs to be edited.
# Add the following to enable it on all disk
# ...
# includeAllDisks 10%
# ...
# The OIDs are as follows (for the first disk)
# Path where the disk is mounted: .1.3.6.1.4.1.2021.9.1.2.1
# Path of the device for the partition: .1.3.6.1.4.1.2021.9.1.3.1
# Total size of the disk/partion (kBytes): .1.3.6.1.4.1.2021.9.1.6.1
# Available space on the disk: .1.3.6.1.4.1.2021.9.1.7.1
# Used space on the disk: .1.3.6.1.4.1.2021.9.1.8.1
# Percentage of space used on disk: .1.3.6.1.4.1.2021.9.1.9.1
# Percentage of inodes used on disk: .1.3.6.1.4.1.2021.9.1.10.1
snmp_oid = {'default': {'mnt_point': '1.3.6.1.4.1.2021.9.1.2',
                        'device_name': '1.3.6.1.4.1.2021.9.1.3',
                        'size': '1.3.6.1.4.1.2021.9.1.6',
                        'used': '1.3.6.1.4.1.2021.9.1.8',
                        'percent': '1.3.6.1.4.1.2021.9.1.9'},
            'windows': {'mnt_point': '1.3.6.1.2.1.25.2.3.1.3',
                        'alloc_unit': '1.3.6.1.2.1.25.2.3.1.4',
                        'size': '1.3.6.1.2.1.25.2.3.1.5',
                        'used': '1.3.6.1.2.1.25.2.3.1.6'},
            'netapp': {'mnt_point': '1.3.6.1.4.1.789.1.5.4.1.2',
                       'device_name': '1.3.6.1.4.1.789.1.5.4.1.10',
                       'size': '1.3.6.1.4.1.789.1.5.4.1.3',
                       'used': '1.3.6.1.4.1.789.1.5.4.1.4',
                       'percent': '1.3.6.1.4.1.789.1.5.4.1.6'}}
snmp_oid['esxi'] = snmp_oid['windows']

# Define the history items list
# All items in this list will be historised if the --enable-history tag is set
# 'color' define the graph color in #RGB format
items_history_list = [{'name': 'percent',
                       'description': 'File system usage in percent',
                       'color': '#00FF00'}]


class Plugin(GlancesPlugin):

    """Glances file system plugin.

    stats is a list
    """

    def __init__(self, args=None):
        """Init the plugin."""
        super(Plugin, self).__init__(args=args, items_history_list=items_history_list)

        # We want to display the stat in the curse interface
        self.display_curse = True

        # Init the stats
        self.reset()

    def get_key(self):
        """Return the key of the list."""
        return 'mnt_point'

    def reset(self):
        """Reset/init the stats."""
        self.stats = []

    @GlancesPlugin._check_decorator
    @GlancesPlugin._log_result_decorator
    def update(self):
        """Update the FS stats using the input method."""
        # Reset the list
        self.reset()

        if self.input_method == 'local':
            # Update stats using the standard system lib

            # Grab the stats using the PsUtil disk_partitions
            # If 'all'=False return physical devices only (e.g. hard disks, cd-rom drives, USB keys)
            # and ignore all others (e.g. memory partitions such as /dev/shm)
            try:
                fs_stat = psutil.disk_partitions(all=False)
            except UnicodeDecodeError:
                return self.stats

            # Optionnal hack to allow logicals mounts points (issue #448)
            # Ex: Had to put 'allow=zfs' in the [fs] section of the conf file
            #     to allow zfs monitoring
            for fstype in self.get_conf_value('allow'):
                try:
                    fs_stat += [f for f in psutil.disk_partitions(all=True) if f.fstype.find(fstype) >= 0]
                except UnicodeDecodeError:
                    return self.stats

            # Loop over fs
            for fs in fs_stat:
                # Do not take hidden file system into account
                if self.is_hide(fs.mountpoint):
                    continue
                # Grab the disk usage
                try:
                    fs_usage = psutil.disk_usage(fs.mountpoint)
                except OSError:
                    # Correct issue #346
                    # Disk is ejected during the command
                    continue
                fs_current = {
                    'device_name': fs.device,
                    'fs_type': fs.fstype,
                    'mnt_point': fs.mountpoint,
                    'size': fs_usage.total,
                    'used': fs_usage.used,
                    'free': fs_usage.free,
                    'percent': fs_usage.percent,
                    'key': self.get_key()}
                self.stats.append(fs_current)

        elif self.input_method == 'snmp':
            # Update stats using SNMP

            # SNMP bulk command to get all file system in one shot
            try:
                fs_stat = self.get_stats_snmp(snmp_oid=snmp_oid[self.short_system_name],
                                              bulk=True)
            except KeyError:
                fs_stat = self.get_stats_snmp(snmp_oid=snmp_oid['default'],
                                              bulk=True)

            # Loop over fs
            if self.short_system_name in ('windows', 'esxi'):
                # Windows or ESXi tips
                for fs in fs_stat:
                    # Memory stats are grabbed in the same OID table (ignore it)
                    if fs == 'Virtual Memory' or fs == 'Physical Memory' or fs == 'Real Memory':
                        continue
                    size = int(fs_stat[fs]['size']) * int(fs_stat[fs]['alloc_unit'])
                    used = int(fs_stat[fs]['used']) * int(fs_stat[fs]['alloc_unit'])
                    percent = float(used * 100 / size)
                    fs_current = {
                        'device_name': '',
                        'mnt_point': fs.partition(' ')[0],
                        'size': size,
                        'used': used,
                        'percent': percent,
                        'key': self.get_key()}
                    self.stats.append(fs_current)
            else:
                # Default behavior
                for fs in fs_stat:
                    fs_current = {
                        'device_name': fs_stat[fs]['device_name'],
                        'mnt_point': fs,
                        'size': int(fs_stat[fs]['size']) * 1024,
                        'used': int(fs_stat[fs]['used']) * 1024,
                        'percent': float(fs_stat[fs]['percent']),
                        'key': self.get_key()}
                    self.stats.append(fs_current)

        return self.stats

    def update_views(self):
        """Update stats views."""
        # Call the father's method
        super(Plugin, self).update_views()

        # Add specifics informations
        # Alert
        for i in self.stats:
            self.views[i[self.get_key()]]['used']['decoration'] = self.get_alert(
                i['used'], maximum=i['size'], header=i['mnt_point'])

    def msg_curse(self, args=None, max_width=None):
        """Return the dict to display in the curse interface."""
        # Init the return message
        ret = []

        # Only process if stats exist and display plugin enable...
        if not self.stats or self.is_disable():
            return ret

        # Max size for the fsname name
        if max_width is not None and max_width >= 23:
            # Interface size name = max_width - space for interfaces bitrate
            fsname_max_width = max_width - 14
        else:
            fsname_max_width = 9

        # Build the string message
        # Header
        msg = '{:{width}}'.format('FILE SYS', width=fsname_max_width)
        ret.append(self.curse_add_line(msg, "TITLE"))
        if args.fs_free_space:
            msg = '{:>7}'.format('Free')
        else:
            msg = '{:>7}'.format('Used')
        ret.append(self.curse_add_line(msg))
        msg = '{:>7}'.format('Total')
        ret.append(self.curse_add_line(msg))

        # Filesystem list (sorted by name)
        for i in sorted(self.stats, key=operator.itemgetter(self.get_key())):
            # New line
            ret.append(self.curse_new_line())
            if i['device_name'] == '' or i['device_name'] == 'none':
                mnt_point = i['mnt_point'][-fsname_max_width + 1:]
            elif len(i['mnt_point']) + len(i['device_name'].split('/')[-1]) <= fsname_max_width - 3:
                # If possible concatenate mode info... Glances touch inside :)
                mnt_point = i['mnt_point'] + ' (' + i['device_name'].split('/')[-1] + ')'
            elif len(i['mnt_point']) > fsname_max_width:
                # Cut mount point name if it is too long
                mnt_point = '_' + i['mnt_point'][-fsname_max_width + 1:]
            else:
                mnt_point = i['mnt_point']
            msg = '{:{width}}'.format(mnt_point, width=fsname_max_width)
            ret.append(self.curse_add_line(msg))
            if args.fs_free_space:
                msg = '{:>7}'.format(self.auto_unit(i['free']))
            else:
                msg = '{:>7}'.format(self.auto_unit(i['used']))
            ret.append(self.curse_add_line(msg, self.get_views(item=i[self.get_key()],
                                                               key='used',
                                                               option='decoration')))
            msg = '{:>7}'.format(self.auto_unit(i['size']))
            ret.append(self.curse_add_line(msg))

        return ret
              ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_irq.pyc                             0000664 0000000 0000000 00000015443 13070471670 023160  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   s~   d  Z  d d l Z d d l Z d d l m Z d d l m Z d d l m Z d e f d �  �  YZ	 d e
 f d	 �  �  YZ d S(
   s   IRQ plugin.i����N(   t   LINUX(   t   getTimeSinceLastUpdate(   t
 d �  Z d d d � Z RS(   s-   Glances IRQ plugin.

    stats is a list
    c         C   s<   t  t |  � j d | � t |  _ t �  |  _ |  j �  d S(   s   Init the plugin.t   argsN(   t   superR   t   __init__t   Truet
   GlancesIRQt   irqt   reset(   t   selfR   (    (    sE   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_irq.pyR   %   s    	c         C   s
   t   get_key(   R   (    (    sE   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_irq.pyR
   R   R    R   t   input_methodR
   t   gett   sortedt   operatort
   itemgetterR   (   R   (    (    sE   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_irq.pyt   update8   s    
c         C   s   t  t |  � j �  d S(   s   Update stats views.N(   R   R   t   update_views(   R   (    (    sE   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_irq.pyR   R   s    c         C   s-  g  } t  s$ |  j s$ |  j j r( | S| d k	 rM | d k rM | d } n d } d j d d | �} | j |  j | d � � d j d	 � } | j |  j | � � x� |  j D]u } | j |  j �  � d
 j | d d  � } | j |  j | � � d
   {:{width}}t   IRQt   widtht   TITLEs   {:>14}s   Rate/ss   {:<15}t   irq_linei   s   {:>8}R   N(
   R    R   R   t
   enable_irqt   Nonet   formatt   appendt   curse_add_linet   curse_new_linet   str(   R   R   t	   max_widtht   rett
   __module__t   __doc__R    R   R
 d	 �  Z RS(
   s)   
    This class manages the IRQ file
    s   /proc/interruptsc         C   s   i  |  _  |  j �  d S(   sW   
        Init the class
        The stat are stored in a internal list of dict
        N(   t   lastsR   (   R   (    (    sE   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_irq.pyR   ~   s    	c         C   s   g  |  _  d |  _ d S(   s   Reset the statsi    N(   R   t
   cpu_number(   R   (    (    sE   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_irq.pyR   �   s    	c         C   s
   |  j  �  S(   s   Return the current IRQ stats(   t   _GlancesIRQ__update(   R   (    (    sE   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_irq.pyR   �   s    c         C   s   d S(   s   Return the key of the dict.R   (    (   R   (    (    sE   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_irq.pyR

        CPU0       CPU1       CPU2       CPU3
        0:         21          0          0          0   IO-APIC   2-edge      timer
        (   t   lent   splitR2   (   R   t   line(    (    sE   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_irq.pyt   __header�   s    c         C   sL   | j  �  } | d j d d � } | j �  rH | d j | d � 7} n  | S(   s"  Get a line and
        Return the IRQ name, alias or number (choose the best for human)

        IRQ line samples:
        1:      44487        341         44         72   IO-APIC   1-edge      i8042
        LOC:   33549868   22394684   32474570   21855077   Local timer interrupts
        i    t   :t    s   _{}i����(   R5   t   replacet   isdigitR!   (   R   R6   t
    c         C   sQ   | j  �  } y' t t t | d |  j d !� � } Wn t k
 rL d } n X| S(   s  Get a line and
        Return the IRQ sum number

        IRQ line samples:
        1:     44487        341         44         72   IO-APIC   1-edge      i8042
        LOC:   33549868   22394684   32474570   21855077   Local timer interrupts
        FIQ:   usb_fiq
        i   i    (   R5   t   sumt   mapt   intR2   t
   ValueError(   R   R6   R<   R'   (    (    sE   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_irq.pyt   __sum�   s    	'
c      	   C   s4  |  j  �  t j j |  j � s& |  j Sy� t |  j � �� } t d � } |  j | j	 �  � x� | j
 �  D]� } |  j | � } |  j | � } t
 r,n X|  j S(   s@   
        Load the IRQ file and update the internal dict
        R
   i    R   R   R   t   time_since_updateN(   R   t   ost   patht   existst   IRQ_FILER   t   openR   t   _GlancesIRQ__headert   readlinet	   readlinest   _GlancesIRQ__humannamet   _GlancesIRQ__sumR@   R1   R   R
(
(   R,   R-   R.   RG   R   R   R   R
&��Xc           @   s�   d  Z  d d l Z d d l m Z d d l m Z d d l m Z i d d 6d d	 6d
 d 6Z	 i d d 6d
 d e f d �  �  YZ d S(   s   Load plugin.i����N(   t	   iteritems(   t   Plugin(   t
 d d � Z RS(   s.   Glances load plugin.

    stats is a dict
    c         C   sv   t  t |  � j d | d t � t |  _ |  j �  y# t d |  j � j	 �  d |  _
 Wn t k
 rq d |  _
 n Xd S(   s   Init the plugin.t   argst   items_history_listt   logi   N(   t   superR   t   __init__R
   t   Truet
   CorePluginR	   t   updatet   nb_log_coret	   Exception(   t   selfR	   (    (    sF   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_load.pyR
#
 rK i  |  _ qXi | d d 6| d d 6| d d 6|  j d 6|  _ n� |  j d	 k r|  j d
 t	 � |  _ |  j d d k r� |  j  �  |  j Sx0 t
 |  j � D] \ } } t | � |  j | <q� W|  j |  j d <n  |  j S(   s   Update load stats.t   locali    R   i   R   i   R   t   cpucoret   snmpt   snmp_oidt    (   R   t   input_methodt   ost
   getloadavgt   OSErrort   AttributeErrorR   R   t   get_stats_snmpR   R    t   float(   R   t   loadt   kt   v(    (    sF   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_load.pyR   M   s&    

c         C   s�   t  t |  � j �  yh |  j |  j d d d |  j d �|  j d d <|  j |  j d d d |  j d �|  j d d <Wn t k
 r� n Xd S(   s   Update stats views.R   t   maximumid   R   t
   decorationR   N(   R   R   t   update_viewst
 � } | j |  j | � � d j |  j  d � } | j |  j | |  j d d d
   is_disablet   formatt   appendt   curse_add_linet   intt   curse_new_linet	   get_views(   R   R	   t   rett   msg(    (    sF   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_load.pyt	   msg_curse�   s4    %"N(   t   __name__t
   __module__t   __doc__t   NoneR
   (    (    (    sF   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_load.pyt   <module>   s"   





#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""HDD temperature plugin."""

import os
import socket

from glances.compat import nativestr, range
from glances.logger import logger
from glances.plugins.glances_plugin import GlancesPlugin


class Plugin(GlancesPlugin):

    """Glances HDD temperature sensors plugin.

    stats is a list
    """

    def __init__(self, args=None):
        """Init the plugin."""
        super(Plugin, self).__init__(args=args)

        # Init the sensor class
        self.glancesgrabhddtemp = GlancesGrabHDDTemp(args=args)

        # We do not want to display the stat in a dedicated area
        # The HDD temp is displayed within the sensors plugin
        self.display_curse = False

        # Init stats
        self.reset()

    def reset(self):
        """Reset/init the stats."""
        self.stats = []

    @GlancesPlugin._check_decorator
    @GlancesPlugin._log_result_decorator
    def update(self):
        """Update HDD stats using the input method."""
        # Reset stats
        self.reset()

        if self.input_method == 'local':
            # Update stats using the standard system lib
            self.stats = self.glancesgrabhddtemp.get()

        else:
            # Update stats using SNMP
            # Not available for the moment
            pass

        return self.stats


class GlancesGrabHDDTemp(object):

    """Get hddtemp stats using a socket connection."""

    def __init__(self, host='127.0.0.1', port=7634, args=None):
        """Init hddtemp stats."""
        self.args = args
        self.host = host
        self.port = port
        self.cache = ""
        self.reset()

    def reset(self):
        """Reset/init the stats."""
        self.hddtemp_list = []

    def __update__(self):
        """Update the stats."""
        # Reset the list
        self.reset()

        # Fetch the data
        # data = ("|/dev/sda|WDC WD2500JS-75MHB0|44|C|"
        #         "|/dev/sdb|WDC WD2500JS-75MHB0|35|C|"
        #         "|/dev/sdc|WDC WD3200AAKS-75B3A0|45|C|"
        #         "|/dev/sdd|WDC WD3200AAKS-75B3A0|45|C|"
        #         "|/dev/sde|WDC WD3200AAKS-75B3A0|43|C|"
        #         "|/dev/sdf|???|ERR|*|"
        #         "|/dev/sdg|HGST HTS541010A9E680|SLP|*|"
        #         "|/dev/sdh|HGST HTS541010A9E680|UNK|*|")
        data = self.fetch()

        # Exit if no data
        if data == "":
            return

        # Safety check to avoid malformed data
        # Considering the size of "|/dev/sda||0||" as the minimum
        if len(data) < 14:
            data = self.cache if len(self.cache) > 0 else self.fetch()
        self.cache = data

        try:
            fields = data.split(b'|')
        except TypeError:
            fields = ""
        devices = (len(fields) - 1) // 5
        for item in range(devices):
            offset = item * 5
            hddtemp_current = {}
            device = os.path.basename(nativestr(fields[offset + 1]))
            temperature = fields[offset + 3]
            unit = nativestr(fields[offset + 4])
            hddtemp_current['label'] = device
            try:
                hddtemp_current['value'] = float(temperature)
            except ValueError:
                # Temperature could be 'ERR', 'SLP' or 'UNK' (see issue #824)
                # Improper bytes/unicode in glances_hddtemp.py (see issue #887)
                hddtemp_current['value'] = nativestr(temperature)
            hddtemp_current['unit'] = unit
            self.hddtemp_list.append(hddtemp_current)

    def fetch(self):
        """Fetch the data from hddtemp daemon."""
        # Taking care of sudden deaths/stops of hddtemp daemon
        try:
            sck = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sck.connect((self.host, self.port))
            data = sck.recv(4096)
        except socket.error as e:
            logger.debug("Cannot connect to an HDDtemp server ({}:{} => {})".format(self.host, self.port, e))
            logger.debug("Disable the HDDtemp module. Use the --disable-hddtemp to hide the previous message.")
            if self.args is not None:
                self.args.disable_hddtemp = True
            data = ""
        finally:
            sck.close()

        return data

    def get(self):
        """Get HDDs list."""
        self.__update__()
        return self.hddtemp_list
                                           ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_cpu.py                              0000664 0000000 0000000 00000034672 13066703446 023022  0                                                                                                    ustar                                                                                                                                                                                                                                                          # -*- coding: utf-8 -*-
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""CPU plugin."""

from glances.timer import getTimeSinceLastUpdate
from glances.compat import iterkeys
from glances.cpu_percent import cpu_percent
from glances.globals import LINUX
from glances.plugins.glances_core import Plugin as CorePlugin
from glances.plugins.glances_plugin import GlancesPlugin

import psutil

# SNMP OID
# percentage of user CPU time: .1.3.6.1.4.1.2021.11.9.0
# percentages of system CPU time: .1.3.6.1.4.1.2021.11.10.0
# percentages of idle CPU time: .1.3.6.1.4.1.2021.11.11.0
snmp_oid = {'default': {'user': '1.3.6.1.4.1.2021.11.9.0',
                        'system': '1.3.6.1.4.1.2021.11.10.0',
                        'idle': '1.3.6.1.4.1.2021.11.11.0'},
            'windows': {'percent': '1.3.6.1.2.1.25.3.3.1.2'},
            'esxi': {'percent': '1.3.6.1.2.1.25.3.3.1.2'},
            'netapp': {'system': '1.3.6.1.4.1.789.1.2.1.3.0',
                       'idle': '1.3.6.1.4.1.789.1.2.1.5.0',
                       'nb_log_core': '1.3.6.1.4.1.789.1.2.1.6.0'}}

# Define the history items list
# - 'name' define the stat identifier
# - 'color' define the graph color in #RGB format
# - 'y_unit' define the Y label
# All items in this list will be historised if the --enable-history tag is set
items_history_list = [{'name': 'user',
                       'description': 'User CPU usage',
                       'color': '#00FF00',
                       'y_unit': '%'},
                      {'name': 'system',
                       'description': 'System CPU usage',
                       'color': '#FF0000',
                       'y_unit': '%'}]


class Plugin(GlancesPlugin):

    """Glances CPU plugin.

    'stats' is a dictionary that contains the system-wide CPU utilization as a
    percentage.
    """

    def __init__(self, args=None):
        """Init the CPU plugin."""
        super(Plugin, self).__init__(args=args, items_history_list=items_history_list)

        # We want to display the stat in the curse interface
        self.display_curse = True

        # Init stats
        self.reset()

        # Call CorePlugin in order to display the core number
        try:
            self.nb_log_core = CorePlugin(args=self.args).update()["log"]
        except Exception:
            self.nb_log_core = 1

    def reset(self):
        """Reset/init the stats."""
        self.stats = {}

    @GlancesPlugin._check_decorator
    @GlancesPlugin._log_result_decorator
    def update(self):
        """Update CPU stats using the input method."""

        # Reset stats
        self.reset()

        # Grab stats into self.stats
        if self.input_method == 'local':
            self.update_local()
        elif self.input_method == 'snmp':
            self.update_snmp()

        return self.stats

    def update_local(self):
        """Update CPU stats using PSUtil."""
        # Grab CPU stats using psutil's cpu_percent and cpu_times_percent
        # Get all possible values for CPU stats: user, system, idle,
        # nice (UNIX), iowait (Linux), irq (Linux, FreeBSD), steal (Linux 2.6.11+)
        # The following stats are returned by the API but not displayed in the UI:
        # softirq (Linux), guest (Linux 2.6.24+), guest_nice (Linux 3.2.0+)
        self.stats['total'] = cpu_percent.get()
        cpu_times_percent = psutil.cpu_times_percent(interval=0.0)
        for stat in ['user', 'system', 'idle', 'nice', 'iowait',
                     'irq', 'softirq', 'steal', 'guest', 'guest_nice']:
            if hasattr(cpu_times_percent, stat):
                self.stats[stat] = getattr(cpu_times_percent, stat)

        # Additionnal CPU stats (number of events / not as a %)
        # ctx_switches: number of context switches (voluntary + involuntary) per second
        # interrupts: number of interrupts per second
        # soft_interrupts: number of software interrupts per second. Always set to 0 on Windows and SunOS.
        # syscalls: number of system calls since boot. Always set to 0 on Linux.
        try:
            cpu_stats = psutil.cpu_stats()
        except AttributeError:
            # cpu_stats only available with PSUtil 4.1 or +
            pass
        else:
            # By storing time data we enable Rx/s and Tx/s calculations in the
            # XML/RPC API, which would otherwise be overly difficult work
            # for users of the API
            time_since_update = getTimeSinceLastUpdate('cpu')

            # Previous CPU stats are stored in the cpu_stats_old variable
            if not hasattr(self, 'cpu_stats_old'):
                # First call, we init the cpu_stats_old var
                self.cpu_stats_old = cpu_stats
            else:
                for stat in cpu_stats._fields:
                    if getattr(cpu_stats, stat) is not None:
                        self.stats[stat] = getattr(cpu_stats, stat) - getattr(self.cpu_stats_old, stat)

                self.stats['time_since_update'] = time_since_update

                # Core number is needed to compute the CTX switch limit
                self.stats['cpucore'] = self.nb_log_core

                # Save stats to compute next step
                self.cpu_stats_old = cpu_stats

    def update_snmp(self):
        """Update CPU stats using SNMP."""
        # Update stats using SNMP
        if self.short_system_name in ('windows', 'esxi'):
            # Windows or VMWare ESXi
            # You can find the CPU utilization of windows system by querying the oid
            # Give also the number of core (number of element in the table)
            try:
                cpu_stats = self.get_stats_snmp(snmp_oid=snmp_oid[self.short_system_name],
                                                bulk=True)
            except KeyError:
                self.reset()

            # Iter through CPU and compute the idle CPU stats
            self.stats['nb_log_core'] = 0
            self.stats['idle'] = 0
            for c in cpu_stats:
                if c.startswith('percent'):
                    self.stats['idle'] += float(cpu_stats['percent.3'])
                    self.stats['nb_log_core'] += 1
            if self.stats['nb_log_core'] > 0:
                self.stats['idle'] = self.stats[
                    'idle'] / self.stats['nb_log_core']
            self.stats['idle'] = 100 - self.stats['idle']
            self.stats['total'] = 100 - self.stats['idle']

        else:
            # Default behavor
            try:
                self.stats = self.get_stats_snmp(
                    snmp_oid=snmp_oid[self.short_system_name])
            except KeyError:
                self.stats = self.get_stats_snmp(
                    snmp_oid=snmp_oid['default'])

            if self.stats['idle'] == '':
                self.reset()
                return self.stats

            # Convert SNMP stats to float
            for key in iterkeys(self.stats):
                self.stats[key] = float(self.stats[key])
            self.stats['total'] = 100 - self.stats['idle']

    def update_views(self):
        """Update stats views."""
        # Call the father's method
        super(Plugin, self).update_views()

        # Add specifics informations
        # Alert and log
        for key in ['user', 'system', 'iowait']:
            if key in self.stats:
                self.views[key]['decoration'] = self.get_alert_log(self.stats[key], header=key)
        # Alert only
        for key in ['steal', 'total']:
            if key in self.stats:
                self.views[key]['decoration'] = self.get_alert(self.stats[key], header=key)
        # Alert only but depend on Core number
        for key in ['ctx_switches']:
            if key in self.stats:
                self.views[key]['decoration'] = self.get_alert(self.stats[key], maximum=100 * self.stats['cpucore'], header=key)
        # Optional
        for key in ['nice', 'irq', 'iowait', 'steal', 'ctx_switches', 'interrupts', 'soft_interrupts', 'syscalls']:
            if key in self.stats:
                self.views[key]['optional'] = True

    def msg_curse(self, args=None):
        """Return the list to display in the UI."""
        # Init the return message
        ret = []

        # Only process if stats exist and plugin not disable
        if not self.stats or self.is_disable():
            return ret

        # Build the string message
        # If user stat is not here, display only idle / total CPU usage (for
        # exemple on Windows OS)
        idle_tag = 'user' not in self.stats

        # Header
        msg = '{:8}'.format('CPU')
        ret.append(self.curse_add_line(msg, "TITLE"))
        # Total CPU usage
        msg = '{:5.1f}%'.format(self.stats['total'])
        if idle_tag:
            ret.append(self.curse_add_line(
                msg, self.get_views(key='total', option='decoration')))
        else:
            ret.append(self.curse_add_line(msg))
        # Nice CPU
        if 'nice' in self.stats:
            msg = '  {:8}'.format('nice:')
            ret.append(self.curse_add_line(msg, optional=self.get_views(key='nice', option='optional')))
            msg = '{:5.1f}%'.format(self.stats['nice'])
            ret.append(self.curse_add_line(msg, optional=self.get_views(key='nice', option='optional')))
        # ctx_switches
        if 'ctx_switches' in self.stats:
            msg = '  {:8}'.format('ctx_sw:')
            ret.append(self.curse_add_line(msg, optional=self.get_views(key='ctx_switches', option='optional')))
            msg = '{:>5}'.format(int(self.stats['ctx_switches'] // self.stats['time_since_update']))
            ret.append(self.curse_add_line(
                msg, self.get_views(key='ctx_switches', option='decoration'),
                optional=self.get_views(key='ctx_switches', option='optional')))

        # New line
        ret.append(self.curse_new_line())
        # User CPU
        if 'user' in self.stats:
            msg = '{:8}'.format('user:')
            ret.append(self.curse_add_line(msg))
            msg = '{:5.1f}%'.format(self.stats['user'])
            ret.append(self.curse_add_line(
                msg, self.get_views(key='user', option='decoration')))
        elif 'idle' in self.stats:
            msg = '{:8}'.format('idle:')
            ret.append(self.curse_add_line(msg))
            msg = '{:5.1f}%'.format(self.stats['idle'])
            ret.append(self.curse_add_line(msg))
        # IRQ CPU
        if 'irq' in self.stats:
            msg = '  {:8}'.format('irq:')
            ret.append(self.curse_add_line(msg, optional=self.get_views(key='irq', option='optional')))
            msg = '{:5.1f}%'.format(self.stats['irq'])
            ret.append(self.curse_add_line(msg, optional=self.get_views(key='irq', option='optional')))
        # interrupts
        if 'interrupts' in self.stats:
            msg = '  {:8}'.format('inter:')
            ret.append(self.curse_add_line(msg, optional=self.get_views(key='interrupts', option='optional')))
            msg = '{:>5}'.format(int(self.stats['interrupts'] // self.stats['time_since_update']))
            ret.append(self.curse_add_line(msg, optional=self.get_views(key='interrupts', option='optional')))

        # New line
        ret.append(self.curse_new_line())
        # System CPU
        if 'system' in self.stats and not idle_tag:
            msg = '{:8}'.format('system:')
            ret.append(self.curse_add_line(msg))
            msg = '{:5.1f}%'.format(self.stats['system'])
            ret.append(self.curse_add_line(
                msg, self.get_views(key='system', option='decoration')))
        else:
            msg = '{:8}'.format('core:')
            ret.append(self.curse_add_line(msg))
            msg = '{:>6}'.format(self.stats['nb_log_core'])
            ret.append(self.curse_add_line(msg))
        # IOWait CPU
        if 'iowait' in self.stats:
            msg = '  {:8}'.format('iowait:')
            ret.append(self.curse_add_line(msg, optional=self.get_views(key='iowait', option='optional')))
            msg = '{:5.1f}%'.format(self.stats['iowait'])
            ret.append(self.curse_add_line(
                msg, self.get_views(key='iowait', option='decoration'),
                optional=self.get_views(key='iowait', option='optional')))
        # soft_interrupts
        if 'soft_interrupts' in self.stats:
            msg = '  {:8}'.format('sw_int:')
            ret.append(self.curse_add_line(msg, optional=self.get_views(key='soft_interrupts', option='optional')))
            msg = '{:>5}'.format(int(self.stats['soft_interrupts'] // self.stats['time_since_update']))
            ret.append(self.curse_add_line(msg, optional=self.get_views(key='soft_interrupts', option='optional')))

        # New line
        ret.append(self.curse_new_line())
        # Idle CPU
        if 'idle' in self.stats and not idle_tag:
            msg = '{:8}'.format('idle:')
            ret.append(self.curse_add_line(msg))
            msg = '{:5.1f}%'.format(self.stats['idle'])
            ret.append(self.curse_add_line(msg))
        # Steal CPU usage
        if 'steal' in self.stats:
            msg = '  {:8}'.format('steal:')
            ret.append(self.curse_add_line(msg, optional=self.get_views(key='steal', option='optional')))
            msg = '{:5.1f}%'.format(self.stats['steal'])
            ret.append(self.curse_add_line(
                msg, self.get_views(key='steal', option='decoration'),
                optional=self.get_views(key='steal', option='optional')))
        # syscalls
        # syscalls: number of system calls since boot. Always set to 0 on Linux. (do not display)
        if 'syscalls' in self.stats and not LINUX:
            msg = '  {:8}'.format('syscal:')
            ret.append(self.curse_add_line(msg, optional=self.get_views(key='syscalls', option='optional')))
            msg = '{:>5}'.format(int(self.stats['syscalls'] // self.stats['time_since_update']))
            ret.append(self.curse_add_line(msg, optional=self.get_views(key='syscalls', option='optional')))

        # Return the message with decoration
        return ret
                                                                      ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_cloud.py                            0000664 0000000 0000000 00000013173 13066703446 023332  0                                                                                                    ustar                                                                                                                                                                                                                                                          # -*- coding: utf-8 -*-
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""Cloud plugin.

Supported Cloud API:
- AWS EC2 (class ThreadAwsEc2Grabber, see bellow)
"""

try:
    import requests
except ImportError:
    cloud_tag = False
else:
    cloud_tag = True

import threading

from glances.compat import iteritems, to_ascii
from glances.plugins.glances_plugin import GlancesPlugin
from glances.logger import logger


class Plugin(GlancesPlugin):

    """Glances' cloud plugin.

    The goal of this plugin is to retreive additional information
    concerning the datacenter where the host is connected.

    See https://github.com/nicolargo/glances/issues/1029

    stats is a dict
    """

    def __init__(self, args=None):
        """Init the plugin."""
        super(Plugin, self).__init__(args=args)

        # We want to display the stat in the curse interface
        self.display_curse = True

        # Init the stats
        self.reset()

        # Init thread to grab AWS EC2 stats asynchroniously
        self.aws_ec2 = ThreadAwsEc2Grabber()

        # Run the thread
        self.aws_ec2. start()

    def reset(self):
        """Reset/init the stats."""
        self.stats = {}

    def exit(self):
        """Overwrite the exit method to close threads"""
        self.aws_ec2.stop()
        # Call the father class
        super(Plugin, self).exit()

    @GlancesPlugin._check_decorator
    @GlancesPlugin._log_result_decorator
    def update(self):
        """Update the cloud stats.

        Return the stats (dict)
        """
        # Reset stats
        self.reset()

        # Requests lib is needed to get stats from the Cloud API
        if not cloud_tag:
            return self.stats

        # Update the stats
        if self.input_method == 'local':
            self.stats = self.aws_ec2.stats
            # self.stats = {'ami-id': 'ami-id',
            #                         'instance-id': 'instance-id',
            #                         'instance-type': 'instance-type',
            #                         'region': 'placement/availability-zone'}

        return self.stats

    def msg_curse(self, args=None):
        """Return the string to display in the curse interface."""
        # Init the return message
        ret = []

        if not self.stats or self.stats == {} or self.is_disable():
            return ret

        # Generate the output
        if 'ami-id' in self.stats and 'region' in self.stats:
            msg = 'AWS EC2'
            ret.append(self.curse_add_line(msg, "TITLE"))
            msg = ' {} instance {} ({})'.format(to_ascii(self.stats['instance-type']),
                                                to_ascii(self.stats['instance-id']),
                                                to_ascii(self.stats['region']))
            ret.append(self.curse_add_line(msg))

        # Return the message with decoration
        logger.info(ret)
        return ret


class ThreadAwsEc2Grabber(threading.Thread):
    """
    Specific thread to grab AWS EC2 stats.

    stats is a dict
    """

    # AWS EC2
    # http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-metadata.html
    AWS_EC2_API_URL = 'http://169.254.169.254/latest/meta-data'
    AWS_EC2_API_METADATA = {'ami-id': 'ami-id',
                            'instance-id': 'instance-id',
                            'instance-type': 'instance-type',
                            'region': 'placement/availability-zone'}

    def __init__(self):
        """Init the class"""
        logger.debug("cloud plugin - Create thread for AWS EC2")
        super(ThreadAwsEc2Grabber, self).__init__()
        # Event needed to stop properly the thread
        self._stopper = threading.Event()
        # The class return the stats as a dict
        self._stats = {}

    def run(self):
        """Function called to grab stats.
        Infinite loop, should be stopped by calling the stop() method"""

        if not cloud_tag:
            logger.debug("cloud plugin - Requests lib is not installed")
            self.stop()
            return False

        for k, v in iteritems(self.AWS_EC2_API_METADATA):
            r_url = '{}/{}'.format(self.AWS_EC2_API_URL, v)
            try:
                # Local request, a timeout of 3 seconds is OK
                r = requests.get(r_url, timeout=3)
            except Exception as e:
                logger.debug('cloud plugin - Cannot connect to the AWS EC2 API {}: {}'.format(r_url, e))
                break
            else:
                if r.ok:
                    self._stats[k] = r.content

        return True

    @property
    def stats(self):
        """Stats getter"""
        return self._stats

    @stats.setter
    def stats(self, value):
        """Stats setter"""
        self._stats = value

    def stop(self, timeout=None):
        """Stop the thread"""
        logger.debug("cloud plugin - Close thread for AWS EC2")
        self._stopper.set()

    def stopped(self):
        """Return True is the thread is stopped"""
        return self._stopper.isSet()
                                                                                                                                                                                                                                                                                                                                                                                                     ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_plugin.pyc                          0000664 0000000 0000000 00000065243 13070471670 023666  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   s�   d  Z  d d l Z d d l Z d d l m Z d d l m Z m Z m Z m	 Z	 d d l
 m Z d d l m
 �  �  YZ d S(   s2   
I am your father...

...for all Glances plugins.
i����N(   t
   itemgetter(   t   iterkeyst
   itervaluest   listkeyst   map(   t   GlancesActions(   t   GlancesHistory(   t   logger(   t   glances_logst
 d �  Z d	 �  Z d
 �  Z
 |  j �  |  _ t
   __module__t   lent   plugin_nameR
 r1 t SX| t k Sd S(   s    Return true if plugin is enabledt   disable_N(   t   getattrR
    
   is_disableb   s    c         C   s9   y t  j | � SWn! t k
 r4 t  j | d t �SXd S(   sS   Return the object 'd' in a JSON format
        Manage the issue #815 for Windows OSt   ensure_asciiN(   t   jsont   dumpst   UnicodeDecodeErrorR+   (   R   R,   (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_plugin.pyt   _json_dumpsf   s    
   reset_list(    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_plugin.pyt   reset_stats_historyx   s    #c      
   C   s�   |  j  �  d k r d } n |  j  �  } |  j r� |  j �  r� x� |  j �  D]� } t |  j t � r� x� |  j D]H } |  j j | | d | d | | d d | d d |  j	 d �qk WqI |  j j | d |  j | d d | d d |  j	 d �qI Wn  d S(   s   Update stats history.t    t   _R7   t   descriptiont   history_max_sizet   history_sizeN(
   R&   R   R   R6   R5   t
   isinstancet   listR   t   addR   (   R   t	   item_namet   it   l(    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_plugin.pyt   update_stats_history   s     		

c         C   s   |  j  S(   s   Return the items history list.(   R   (   R   (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_plugin.pyR5   �   s    c         C   s;   |  j  j �  } | d k r | S| | k r3 | | Sd Sd S(   s�   Return
        - the stats history (dict of list) if item is None
        - the stats history for the given item (list) instead
        - None if item did not exist in the historyN(   R   t   getR   (   R   t   itemt   s(    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_plugin.pyt   get_raw_history�   s    i    c         C   sA   |  j  j d | � } | d k r% | S| | k r9 | | Sd Sd S(   s�   Return:
        - the stats history (dict of list) if item is None
        - the stats history for the given item (list) instead
        - None if item did not exist in the history
        Limit to lasts nb items (all if nb=0)t   nbN(   R   t   get_jsonR   (   R   RJ   RM   RK   (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_plugin.pyt   get_json_history�   s    c         C   s   |  j  d | � S(   s]   Return the stats history object to export.
        See get_raw_history for a full descriptionRJ   (   RL   (   R   RJ   (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_plugin.pyt   get_export_history�   s    c         C   s   |  j  d | � } | d k r+ |  j | � St | t � r� y |  j i | | | 6� SWq� t k
 r� } t j d j | | � � d SXns t | t	 � r� y' |  j i t
 t | � | � | 6� SWq� t t f k
 r� } t j d j | | � � d SXn d Sd S(   sg   Return the stats history as a JSON object (dict or None).
        Limit to lasts nb items (all if nb=0)RM   s   Cannot get item history {} ({})N(
   ValueError(   R   RJ   RM   RK   t   e(    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_plugin.pyt   get_stats_history�   s     

        * local: system local grab (psutil or direct access)
        * snmp: Client server mode via SNMP
        * glances: Client server mode via Glances API
        N(   R   (   R   RV   (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_plugin.pyRV   �   s    c         C   s   |  j  S(   s&   Get the short detected OS name (SNMP).(   R   (   R   (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_plugin.pyt   short_system_name�   s    c         C   s
   short_name(    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_plugin.pyRW   �   s    c         C   s
 | � d j t | � d � r� t | � d | t
 | � d t
 | � d j t | � d � d	 <q� q� Wq�d	 } x� | D]� } i  }	 d }
 xb t
 | � D]T } | | d
 t | � } | | k r7|
 d k rz| | }
 q�| | |	 | <q7q7W|	 r�|	 | |
 <n  | d	 7} qWn> | j t | �  � } x& t
 | � D] } | | | | | <q�W| S(   se   Update stats using SNMP.

        If bulk=True, use a bulk request instead of a get request.
        i����(   t   GlancesSNMPClientt   hostt   portt   versiont	   communityi    i
   i   t   .N(   t   glances.snmpR[   R
   startswitht   splitR   R$   t
   get_by_oid(
   clientsnmpt   rett
   snmpresultRJ   t   indext
   item_statst   item_keyt   keyt   oid(    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_plugin.pyt   get_stats_snmp�   s<    
   |  j  �  S(   s"   Return the stats object to export.(   Ru   (   R   (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_plugin.pyt
   get_export2  s    c         C   s   |  j  |  j � S(   s'   Return the stats object in JSON format.(   R3   R   (   R   (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_plugin.pyt	   get_stats6  s    c         C   s�   t  |  j t � rd y |  j i |  j | | 6� SWq� t k
 r` } t j d j | | � � d SXny t  |  j t	 � r� y* |  j i t
 t | � |  j � | 6� SWq� t t f k
 r� } t j d j | | � � d SXn d Sd S(   s�   Return the stats object for a specific item in JSON format.

        Stats should be a list of dict (processlist, network...)
        s   Cannot get item {} ({})N(
 r� } t	 j
 d j | | | � � d SXd S(   s�   Return the stats object for a specific item=value in JSON format.

        Stats should be a list of dict (processlist, network...)
        s"   Cannot get item({})=value({}) ({})N(   RB   R   RC   R   t   isdigitt   intR3   RQ   RS   R   RR   R!   (   R   RJ   t   valueRF   RT   (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_plugin.pyt   get_stats_valueP  s    >c         C   sA  i  } t  |  j �  t � r� |  j �  d k	 r� |  j �  d k	 r� x� |  j �  D]k } i  | | |  j �  <xN t | � D]@ } i d d 6t d 6t d 6t d 6} | | | |  j �  | <qs WqL Wns t  |  j �  t � r1|  j �  d k	 r1xI t |  j �  � D]2 } i d d 6t d 6t d 6t d 6} | | | <q� Wn  | |  _ |  j S(   sC  Default builder fo the stats views.

        The V of MVC
        A dict of dict with the needed information to display the stats.
        Example for the stat xxx:
        'xxx': {'decoration': 'DEFAULT',
                'optional': False,
                'additional': False,
                'splittable': False}
        t   DEFAULTt
   decorationt   optionalt
   additionalt
   splittableN(	   RB   Ru   RC   R   R&   R   R+   R   R   (   R   Rm   RF   Rr   R{   (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_plugin.pyt   update_viewsa  s*    

#'

	c         C   s

        If key is None, return all the view for the current plugin
        else if option is None return the view for the specific key (all option)
        else return the view fo the specific key/option

        Specify item if the stats are stored in a dict of dict (ex: NETWORK, FS...)
        R}   N(   R   R   (   R   RJ   Rr   t   optiont
   item_views(    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_plugin.pyt	   get_views�  s    	
 |  j | g � } y  | j |  j | � |  j  | <Wn6 t k
 r| j |  j | � j
   s6   Load limits from the configuration file, if it exists.i�p  RA   t   has_sectiont   globalt   defaults   Load configuration key: {} = {}R>   t   ,s   Load limit: {} = {}(   R   t   hasattrR+   R�   t   get_float_valueR   R    R!   R   t   itemst   joinRS   t	   get_valueRh   R*   (   R   t   configt   levelR>   t   limit(    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_plugin.pyt   load_limits�  s    
        By default return all the stats.
        Can be overwrite by plugins implementation.
        For example, Docker will return self.stats['containers'](   R   (   R   (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_plugin.pyt   get_stats_action�  s    id   R=   c	   
 r= d St k
 rN d SX| d k rg |  j }
 n |  j d | }
 | r� d n d } y� |	 |  j d d	 |
 �k r� d
 } n] |	 |  j d d	 |
 �k r� d } n9 |	 |  j d
 �k r� d } n | | k  rd } n  Wn t k
 r#d SXd } |  j d	 |
 d | � rdd } t j | |
 j �  |	 � n  |  j	 |
 | j
 �  | | � | | S(   s  Return the alert status relative to a current value.

        Use this function for minor stats.

        If current < CAREFUL of max then alert = OK
        If current > CAREFUL of max then alert = CAREFUL
        If current > WARNING of max then alert = WARNING
        If current > CRITICAL of max then alert = CRITICAL

        If highlight=True than 0.0 is highlighted

        If defined 'header' is added between the plugin name and the status.
        Only useful for stats with several alert status.

        If defined, 'action_key' define the key for the actions.
        By default, the action_key is equal to the header.

        If log=True than add log if necessary
        elif log=False than do not log
        elif log=None than apply the config given in the conf file
        i    R}   id   R=   R>   t   MAXt   OKt   criticalt	   stat_namet   CRITICALt   warningt   WARNINGt   carefult   CAREFULt   default_actiont   _LOG(   t   ZeroDivisionErrort	   TypeErrorR   t	   get_limitRQ   t
   action_keyt   logR{   R�   Rm   t   log_str(    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_plugin.pyt	   get_alert�  s:    
 r? |  j j | | � n� X| d k rU | } n  t |  j �  t � r� i  } xC |  j �  D]& } | |  j �  | k r} | } Pq} q} Wn |  j �  } |  j j	 | | | d | �d S(   s&   Manage the action for the current statR�   t
   t   get_limit_actionRQ   R   t   setR   RB   R�   RC   R&   t   run(   R   R�   t   triggerR�   R�   t   commandR�   RJ   (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_plugin.pyR�     s    
 rD |  j  |  j d | } n X| S(   s%   Return the limit value for the alert.R>   (   R   RQ   R   (   R   t	   criticityR�   R�   (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_plugin.pyR�   O  s
    
 rL |  j  |  j d | d } n X| S(   s    Return the action for the alert.R>   t   _action(   R   RQ   R   (   R   R�   R�   Rm   (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_plugin.pyR�   _  s
    
 rU y |  j  |  j d } WqV t k
 rQ | SXn X| d j �  d k S(   s!   Return the log tag for the alert.t   _logi    t   true(   R   RQ   R   R�   (   R   R�   R�   t   log_tag(    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_plugin.pyR�   m  s    
 r` g  SXd S(   s~   Return the configuration (header_) value for the current plugin.

        ...or the one given by the plugin_name var.
        R=   R>   N(   R   R   R   RQ   (   R   R{   R�   R   (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_plugin.pyt   get_conf_value  s    
        Return True if the value is in the hide configuration list.
        The hide configuration list is defined in the glances.conf file.
        It is a comma separed list of regexp.
        Example for diskio:
        hide=sda2,sda5,loop.*
        c         s   s   |  ] } | d  k Vq d  S(   N(   R   (   t   .0t   j(    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_plugin.pys	   <genexpr>�  s    t   hideR�   (   t   allR�   t   ret   match(   R   R{   R�   RF   (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_plugin.pyt   is_hide�  s    	c         C   sE   y& |  j  |  j d | d d d SWn t t f k
 r@ d SXd S(   sB   Return the alias name for the relative header or None if nonexist.R>   t   aliasi    N(   R   R   RQ   t
   IndexErrorR   (   R   R�   (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_plugin.pyt	   has_alias�  s    &c         C   s   |  j  t |  j � � g S(   s8   Return default string to display in the curse interface.(   t   curse_add_lineR$   R   (   R   R

        key     | description
        ----------------------------
        display | Display the stat (True or False)
        msgdict | Message to display (list of dict [{ 'msg': msg, 'decoration': decoration } ... ])
        align   | Message position
        t


R}   c         C   s'   i | d 6| d 6| d 6| d 6| d 6S(   sg  Return a dict with.

        Where:
            msg: string
            decoration:
                DEFAULT: no decoration
                UNDERLINE: underline
                BOLD: bold
                TITLE: for stat title
                PROCESS: for process name
                STATUS: for process status
                NICE: for process niceness
                CPU_TIME: for process cpu time
                OK: Value is OK and non logged
                OK_LOG: Value is OK and logged
                CAREFUL: Value is CAREFUL and non logged
                CAREFUL_LOG: Value is CAREFUL and logged
                WARNING: Value is WARINING and non logged
                WARNING_LOG: Value is WARINING and logged
                CRITICAL: Value is CRITICAL and non logged
                CRITICAL_LOG: Value is CRITICAL and logged
            optional: True if the stat is optional (display only if space is available)
            additional: True if the stat is additional (display only if space is available after optional)
            spittable: Line can be splitted to fit on the screen (default is not)
        t   msgR~   R   R�   R�   (    (   R   R�   R~   R   R�   R�   (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_plugin.pyR�   �  s    c         C   s
(   R�   (   R   (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_plugin.pyt   curse_new_line�  s    c         C   s   |  j  S(   s   Get the curse align.(   R   (   R   (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_plugin.pyR�   �  s    c         C   s

        value: left, right, bottom.
        N(   R   (   R   R{   (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_plugin.pyR�   �  s    c         C   s  d } i d	 d 6d
 d 6d d 6d d 6d

        Number of decimal places increases as quantity approaches 1.

        examples:
        CASE: 613421788        RESULT:       585M low_precision:       585M
        CASE: 5307033647       RESULT:      4.94G low_precision:       4.9G
        CASE: 44968414685      RESULT:      41.9G low_precision:      41.9G
        CASE: 838471403472     RESULT:       781G low_precision:       781G
        CASE: 9683209690677    RESULT:      8.81T low_precision:       8.8T
        CASE: 1073741824       RESULT:      1024M low_precision:      1024M
        CASE: 1181116006       RESULT:      1.10G low_precision:       1.1G

        'low_precision=True' returns less decimal places potentially
        sacrificing precision for more readability.
        t   Kt   Mt   Gt   Tt   Pt   Et   Zt   Yl               l            I       I       I       i   @i   i   i   i    i
   i   id   t   MKs   {:.{decimal}f}{symbol}t   decimalt   symbols   {!s}(   R�   R�   R�   R�   R�   R�   R�   R�   (   t   reversedt   floatt   minR!   (   R   t   numbert
				c            s   �  f d �  } | S(   s   Check if the plugin is enabled.c            s.   |  j  �  r! �  |  | | � } n	 |  j } | S(   N(   R-   R   (   R   R
   (   R   R    R   t   __name__R   R   (   R
	7						&			F	$			0	
	(   R�   R�   R0   t   operatorR    t   glances.compatR   R   R   R   t   glances.actionsR   t   glances.historyR   t   glances.loggerR   t   glances.logsR   t   objectR	   (    (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_plugin.pyt   <module>   s   "                                                                                                                                                                                                                                                                                                                                                             ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_network.pyc                         0000664 0000000 0000000 00000016026 13070471670 024054  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   s�   d  Z  d d l Z d d l Z d d l m Z d d l m Z d d l Z i i d d 6d d 6d	 d
 6d 6Z i d d
 d S(   s   Network plugin.i����N(   t   getTimeSinceLastUpdate(   t
 d �  Z d d d � Z RS(   s1   Glances network plugin.

    stats is a list
    c         C   s6   t  t |  � j d | d t � t |  _ |  j �  d S(   s   Init the plugin.t   argst   items_history_listN(   t   superR   t   __init__R   t   Truet
 rF |  j SXi  } y t j �  } Wn t k
 rp n Xt	 |  d � s� y
 Wqt t f k
 r� qXqAt
 | j }	 | |  j
 | j }
 |	 |
 } i | d 6| d 6| d 6|	 d 6| d	 6|
 d
 6| d 6| d 6} Wn t k
 r�q� q� Xy | | j | d
 r�n Xy | | j d | d <Wn t t f k
 r�n X|  j �  | d <|  j j | � q� W| |  _
 n"|  j d k rAy# |  j d t |  j d t � } Wn- t k
 r�|  j d t d d t � } n Xt	 |  d � s�y
 Wq>t t f k
 r�q>XqAt
 r?| }
 | d � }	 | t |  j
 | d	 � }
 |	 |
 } i |
 d
 6| d 6| d 6} Wn t k
 rq�q�X|  j �  | d <|  j j | � q�W| |  _
 n  |  j S(   so   Update network stats using the input method.

        Stats is a list of dict (one dict per interface)
        t   localt   pernict   network_oldt   netR   t   time_since_updateR   R   R   R   t
   bytes_recvt
   bytes_sentt   KeyErrort   isupR   R   t   appendt   get_stats_snmpR"   t   short_system_namet   strt   base64t	   b16decodet   uppert	   TypeErrort   float(   R   t





 �} | d k r� d | k r� | d d k r� |  j d
   decorationN(	   R   R   t   update_viewsR   t   splitt   intt	   get_alertt   viewsR   (   R   t   it
   ifrealnamet   bps_rxt   bps_txt   alert_rxt   alert_tx(    (    sI   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_network.pyRI   �   s"    (
(
c         C   st  g  } |  j  s |  j �  r  | S| d" k	 rE | d k rE | d } n d } d j d d | �} | j |  j | d � � | j r | j r� d j d	 � } | j |  j | � � q{d
 j d � } | j |  j | � � d
 j d � } | j |  j | � � n{ | j r1d j d
 j d � } | j |  j | � � d
 j d � } | j |  j | � � x�t |  j  d t	 j
 |  j �  � �D]�} d | k r�| d t k r�q�n  | d j
 n d }	 d }
 | j r�|  j t | d |	 � � |
 } |  j t | d |	 � � |
 } |  j t | d |	 � t | d |	 � � |
 }
 } |  j t | d | d |	 � � |
 } |  j t | d | d |	 � t | d | d |	 � � |
 }
 j | � } | j |  j | |  j d | |  j �  d d d  d! � � � d
 j | � } | j |  j | |  j d | |  j �  d d d  d! � � � q�W| S(#   s2   Return the dict to display in the curse interface.i   i   i	   s
   {:{width}}t   NETWORKt   widtht   TITLEs   {:>14}s   Rx+Txs   {:>7}t   Rxt   Txs   Rx+Tx/ss   Rx/ss   Tx/sR    R   R   RA   i    t   _i   t    i   t   bR   R   R   R   R   t   itemt   optionRH   N(   R   t
   is_disablet   Nonet   formatR3   t   curse_add_linet
   itemgetterR   t   FalseRJ   t	   has_aliast   lent   bytet	   auto_unitRK   t   curse_new_linet	   get_views(   R   R
   __module__t   __doc__R_   R   R   R   R   t   _check_decoratort   _log_result_decoratorR@   RI   Rv   (    (    (    sI   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_network.pyR   2   s   
		�	(   Ry   R7   Re   t


#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""Battery plugin."""

import psutil

from glances.logger import logger
from glances.plugins.glances_plugin import GlancesPlugin

# Batinfo library (optional; Linux-only)
batinfo_tag = True
try:
    import batinfo
except ImportError:
    logger.debug("batpercent plugin - Batinfo library not found. Trying fallback to PsUtil.")
    batinfo_tag = False

# PsUtil library 5.2.0 or higher (optional; Linux-only)
psutil_tag = True
try:
    psutil.sensors_battery()
except AttributeError:
    logger.debug("batpercent plugin - PsUtil 5.2.0 or higher is needed to grab battery stats.")
    psutil_tag = False


class Plugin(GlancesPlugin):

    """Glances battery capacity plugin.

    stats is a list
    """

    def __init__(self, args=None):
        """Init the plugin."""
        super(Plugin, self).__init__(args=args)

        # Init the sensor class
        self.glancesgrabbat = GlancesGrabBat()

        # We do not want to display the stat in a dedicated area
        # The HDD temp is displayed within the sensors plugin
        self.display_curse = False

        # Init stats
        self.reset()

    def reset(self):
        """Reset/init the stats."""
        self.stats = []

    @GlancesPlugin._check_decorator
    @GlancesPlugin._log_result_decorator
    def update(self):
        """Update battery capacity stats using the input method."""
        # Reset stats
        self.reset()

        if self.input_method == 'local':
            # Update stats
            self.glancesgrabbat.update()
            self.stats = self.glancesgrabbat.get()

        elif self.input_method == 'snmp':
            # Update stats using SNMP
            # Not avalaible
            pass

        return self.stats


class GlancesGrabBat(object):

    """Get batteries stats using the batinfo library."""

    def __init__(self):
        """Init batteries stats."""
        self.bat_list = []

        if batinfo_tag:
            self.bat = batinfo.batteries()
        elif psutil_tag:
            self.bat = psutil
        else:
            self.bat = None

    def update(self):
        """Update the stats."""
        if batinfo_tag:
            # Use the batinfo lib to grab the stats
            # Compatible with multiple batteries
            self.bat.update()
            self.bat_list = [{
                'label': 'Battery',
                'value': self.battery_percent,
                'unit': '%'}]
        elif psutil_tag and hasattr(self.bat.sensors_battery(), 'percent'):
            # Use the PSUtil 5.2.0 or higher lib to grab the stats
            # Give directly the battery percent
            self.bat_list = [{
                'label': 'Battery',
                'value': int(self.bat.sensors_battery().percent),
                'unit': '%'}]
        else:
            # No stats...
            self.bat_list = []

    def get(self):
        """Get the stats."""
        return self.bat_list

    @property
    def battery_percent(self):
        """Get batteries capacity percent."""
        if not batinfo_tag or not self.bat.stat:
            return []

        # Init the bsum (sum of percent)
        # and Loop over batteries (yes a computer could have more than 1 battery)
        bsum = 0
        for b in self.bat.stat:
            try:
                bsum += int(b.capacity)
            except ValueError:
                return []

        # Return the global percent
        return int(bsum / len(self.bat.stat))
                                                                                                                                                                                                                                                                                                                                                                                                                  ./usr/local/lib/python2.7/dist-packages/glances/plugins/glances_system.pyc                          0000664 0000000 0000000 00000013333 13070471670 023705  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   s�   d  Z  d d l Z d d l Z d d l Z d d l m Z d d l m Z d d l m	 Z	 i i d d 6d d	 6d
 6i d d 6d d	 6d d 6d
 i i d d 6d d 6d d 6d d 6d d 6d d 6d d 6d d 6d 6Z d �  Z d  e	 f d! �  �  YZ
   Windows XPs   Windows Version 5.1s   Windows 2000s   Windows Version 5.0t   windowsc          C   s  d }  i  } d d g } y� t  t j j d d � � �g } x] | D]U } xL | D]D } | j | � rM t j d d | j �  j d � d � | | <qM qM Wq@ WWd	 QXWn t	 t
 f k
 r� |  SX| rd | k r� | d }  n  d | k r|  d
 j | d � 7}  qn  |  S(   s  Try to determine the name of a Linux distribution.

    This function checks for the /etc/os-release file.
    It takes the name from the 'NAME' field and the version from 'VERSION_ID'.
    An empty string is returned if the above values cannot be determined.
    t    t   NAMEt
   VERSION_IDs   /etcs
   os-releases   ^"|"$t   =i   Ns    {}(   R    t   ost   patht   joint
   startswitht   ret   subt   stript   splitt   OSErrort   IOErrort   format(   t   pretty_namet   ashtrayt   keyst   ft   linet   key(    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_system.pyt   _linux_os_release3   s"    
 RS(   s6   Glances' host/system plugin.

    stats is a dict
    c         C   s0   t  t |  � j d | � t |  _ |  j �  d S(   s   Init the plugin.t   argsN(   t   superR   t   __init__t   Truet
 r� t	 �  |  j d <n> X| d d k r� t	 �  |  j d <n d	 j
 | d
  � |  j d <t j �  |  j d <n� |  j d j d � s|  j d d
 | d d d
 � � |  j d <|  j d d k r�d t j k r�d |  j d <q�n
|  j d |  j d <n' d j |  j d |  j d � |  j d <|  j d c d j |  j d � 7<n� |  j d k r;y  |  j d t |  j � |  _ Wn* t k
 r�|  j d t d � |  _ n X|  j d |  j d <|  j d k r$xK t t d � D]6 \ } } t j | |  j d � r�| |  j d <Pq�q�Wn  |  j d |  j d <n  |  j S(   s]   Update the host/system info using the input method.

        Return the stats (dict)
        t   localt   os_nameR   i    R   t   Linuxt   linux_distroR	   t    i   t
   os_versiont   BSDt   SunOSt   Darwint   WindowsNt   32bitt   PROCESSOR_ARCHITEW6432t   64bitt   hr_names   {} {}s    {}t   snmpt   snmp_oidR   R   R   (   R%   t   input_methodR   t   systemR'   t   nodet   architecturet   linux_distributiont   AttributeErrorR   R   t   releaset   endswitht   mac_vert	   win32_verR

 � � |  j d d k r4|  j d
 r�d j |  j d � } n X| j |  j | d t �� | S(   s4   Return the string to display in the curse interface.t	   connecteds
   SNMP from t   disconnecteds   Disconnected from t   CRITICALR   t   TITLER)   R*   R+   s    ({} {} / {} {})R   R-   s    ({} {} {})s    ({})t   optional(	   t   clientt	   cs_statust   lowert   appendt   curse_add_lineR'   R   t	   ExceptionR#   (   R&   R    t   rett   msg(    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_system.pyt	   msg_curse�   s4    	



   __module__t   __doc__t   NoneR"   R%   R   t   _check_decoratort   _log_result_decoratorRJ   RY   (    (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/plugins/glances_system.pyR   O   s   
	C(   R\   R

#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""Docker plugin."""

import os
import re
import threading
import time

from glances.compat import iterkeys, itervalues
from glances.logger import logger
from glances.timer import getTimeSinceLastUpdate
from glances.plugins.glances_plugin import GlancesPlugin

from glances.globals import WINDOWS

# Docker-py library (optional and Linux-only)
# https://github.com/docker/docker-py
try:
    import docker
    import requests
except ImportError as e:
    logger.debug("Docker library not found (%s). Glances cannot grab Docker info." % e)
    docker_tag = False
else:
    docker_tag = True


class Plugin(GlancesPlugin):

    """Glances Docker plugin.

    stats is a list
    """

    def __init__(self, args=None):
        """Init the plugin."""
        super(Plugin, self).__init__(args=args)

        # The plgin can be disable using: args.disable_docker
        self.args = args

        # We want to display the stat in the curse interface
        self.display_curse = True

        # Init the Docker API
        self.docker_client = False

        # Dict of thread (to grab stats asynchroniously, one thread is created by container)
        # key: Container Id
        # value: instance of ThreadDockerGrabber
        self.thread_list = {}

        # Init the stats
        self.reset()

    def exit(self):
        """Overwrite the exit method to close threads"""
        for t in itervalues(self.thread_list):
            t.stop()
        # Call the father class
        super(Plugin, self).exit()

    def get_key(self):
        """Return the key of the list."""
        return 'name'

    def get_export(self):
        """Overwrite the default export method.

        - Only exports containers
        - The key is the first container name
        """
        ret = []
        try:
            ret = self.stats['containers']
        except KeyError as e:
            logger.debug("docker plugin - Docker export error {}".format(e))
        return ret

    def __connect_old(self, version):
        """Connect to the Docker server with the 'old school' method"""
        # Glances is compatible with both API 2.0 and <2.0
        # (thanks to the @bacondropped patch)
        if hasattr(docker, 'APIClient'):
            # Correct issue #1000 for API 2.0
            init_docker = docker.APIClient
        elif hasattr(docker, 'Client'):
            # < API 2.0
            init_docker = docker.Client
        else:
            # Can not found init method (new API version ?)
            logger.error("docker plugin - Can not found any way to init the Docker API")
            return None
        # Init connection to the Docker API
        try:
            if WINDOWS:
                url = 'npipe:////./pipe/docker_engine'
            else:
                url = 'unix://var/run/docker.sock'
            if version is None:
                ret = init_docker(base_url=url)
            else:
                ret = init_docker(base_url=url,
                                  version=version)
        except NameError:
            # docker lib not found
            return None

        return ret

    def connect(self, version=None):
        """Connect to the Docker server."""
        if hasattr(docker, 'from_env') and version is not None:
            # Connect to Docker using the default socket or
            # the configuration in your environment
            ret = docker.from_env()
        else:
            ret = self.__connect_old(version=version)

        # Check the server connection with the version() method
        try:
            ret.version()
        except requests.exceptions.ConnectionError as e:
            # Connexion error (Docker not detected)
            # Let this message in debug mode
            logger.debug("docker plugin - Can't connect to the Docker server (%s)" % e)
            return None
        except docker.errors.APIError as e:
            if version is None:
                # API error (Version mismatch ?)
                logger.debug("docker plugin - Docker API error (%s)" % e)
                # Try the connection with the server version
                version = re.search('(?:server API version|server)\:\ (.*)\)\".*\)', str(e))
                if version:
                    logger.debug("docker plugin - Try connection with Docker API version %s" % version.group(1))
                    ret = self.connect(version=version.group(1))
                else:
                    logger.debug("docker plugin - Can not retreive Docker server version")
                    ret = None
            else:
                # API error
                logger.error("docker plugin - Docker API error (%s)" % e)
                ret = None
        except Exception as e:
            # Others exceptions...
            # Connexion error (Docker not detected)
            logger.error("docker plugin - Can't connect to the Docker server (%s)" % e)
            ret = None

        # Log an info if Docker plugin is disabled
        if ret is None:
            logger.debug("docker plugin - Docker plugin is disable because an error has been detected")

        return ret

    def reset(self):
        """Reset/init the stats."""
        self.stats = {}

    @GlancesPlugin._check_decorator
    @GlancesPlugin._log_result_decorator
    def update(self):
        """Update Docker stats using the input method."""
        global docker_tag

        # Reset stats
        self.reset()

        # Get the current Docker API client
        if not self.docker_client:
            # First time, try to connect to the server
            try:
                self.docker_client = self.connect()
            except Exception:
                docker_tag = False
            else:
                if self.docker_client is None:
                    docker_tag = False

        # The Docker-py lib is mandatory
        if not docker_tag:
            return self.stats

        if self.input_method == 'local':
            # Update stats

            # Docker version
            # Exemple: {
            #     "KernelVersion": "3.16.4-tinycore64",
            #     "Arch": "amd64",
            #     "ApiVersion": "1.15",
            #     "Version": "1.3.0",
            #     "GitCommit": "c78088f",
            #     "Os": "linux",
            #     "GoVersion": "go1.3.3"
            # }
            try:
                self.stats['version'] = self.docker_client.version()
            except Exception as e:
                # Correct issue#649
                logger.error("{} plugin - Cannot get Docker version ({})".format(self.plugin_name, e))
                return self.stats

            # Container globals information
            # Example: [{u'Status': u'Up 36 seconds',
            #            u'Created': 1420378904,
            #            u'Image': u'nginx:1',
            #            u'Ports': [{u'Type': u'tcp', u'PrivatePort': 443},
            #                       {u'IP': u'0.0.0.0', u'Type': u'tcp', u'PublicPort': 8080, u'PrivatePort': 80}],
            #            u'Command': u"nginx -g 'daemon off;'",
            #            u'Names': [u'/webstack_nginx_1'],
            #            u'Id': u'b0da859e84eb4019cf1d965b15e9323006e510352c402d2f442ea632d61faaa5'}]

            # Update current containers list
            try:
                self.stats['containers'] = self.docker_client.containers() or []
            except Exception as e:
                logger.error("{} plugin - Cannot get containers list ({})".format(self.plugin_name, e))
                return self.stats

            # Start new thread for new container
            for container in self.stats['containers']:
                if container['Id'] not in self.thread_list:
                    # Thread did not exist in the internal dict
                    # Create it and add it to the internal dict
                    logger.debug("{} plugin - Create thread for container {}".format(self.plugin_name, container['Id'][:12]))
                    t = ThreadDockerGrabber(self.docker_client, container['Id'])
                    self.thread_list[container['Id']] = t
                    t.start()

            # Stop threads for non-existing containers
            nonexisting_containers = set(iterkeys(self.thread_list)) - set([c['Id'] for c in self.stats['containers']])
            for container_id in nonexisting_containers:
                # Stop the thread
                logger.debug("{} plugin - Stop thread for old container {}".format(self.plugin_name, container_id[:12]))
                self.thread_list[container_id].stop()
                # Delete the item from the dict
                del self.thread_list[container_id]

            # Get stats for all containers
            for container in self.stats['containers']:
                # The key is the container name and not the Id
                container['key'] = self.get_key()

                # Export name (first name in the list, without the /)
                container['name'] = container['Names'][0][1:]

                container['cpu'] = self.get_docker_cpu(container['Id'], self.thread_list[container['Id']].stats)
                container['memory'] = self.get_docker_memory(container['Id'], self.thread_list[container['Id']].stats)
                container['network'] = self.get_docker_network(container['Id'], self.thread_list[container['Id']].stats)
                container['io'] = self.get_docker_io(container['Id'], self.thread_list[container['Id']].stats)

        elif self.input_method == 'snmp':
            # Update stats using SNMP
            # Not available
            pass

        return self.stats

    def get_docker_cpu(self, container_id, all_stats):
        """Return the container CPU usage.

        Input: id is the full container id
               all_stats is the output of the stats method of the Docker API
        Output: a dict {'total': 1.49}
        """
        cpu_new = {}
        ret = {'total': 0.0}

        # Read the stats
        # For each container, you will find a pseudo-file cpuacct.stat,
        # containing the CPU usage accumulated by the processes of the container.
        # Those times are expressed in ticks of 1/USER_HZ of a second.
        # On x86 systems, USER_HZ is 100.
        try:
            cpu_new['total'] = all_stats['cpu_stats']['cpu_usage']['total_usage']
            cpu_new['system'] = all_stats['cpu_stats']['system_cpu_usage']
            cpu_new['nb_core'] = len(all_stats['cpu_stats']['cpu_usage']['percpu_usage'] or [])
        except KeyError as e:
            # all_stats do not have CPU information
            logger.debug("docker plugin - Cannot grab CPU usage for container {} ({})".format(container_id, e))
            logger.debug(all_stats)
        else:
            # Previous CPU stats stored in the cpu_old variable
            if not hasattr(self, 'cpu_old'):
                # First call, we init the cpu_old variable
                self.cpu_old = {}
                try:
                    self.cpu_old[container_id] = cpu_new
                except (IOError, UnboundLocalError):
                    pass

            if container_id not in self.cpu_old:
                try:
                    self.cpu_old[container_id] = cpu_new
                except (IOError, UnboundLocalError):
                    pass
            else:
                #
                cpu_delta = float(cpu_new['total'] - self.cpu_old[container_id]['total'])
                system_delta = float(cpu_new['system'] - self.cpu_old[container_id]['system'])
                if cpu_delta > 0.0 and system_delta > 0.0:
                    ret['total'] = (cpu_delta / system_delta) * float(cpu_new['nb_core']) * 100

                # Save stats to compute next stats
                self.cpu_old[container_id] = cpu_new

        # Return the stats
        return ret

    def get_docker_memory(self, container_id, all_stats):
        """Return the container MEMORY.

        Input: id is the full container id
               all_stats is the output of the stats method of the Docker API
        Output: a dict {'rss': 1015808, 'cache': 356352,  'usage': ..., 'max_usage': ...}
        """
        ret = {}
        # Read the stats
        try:
            # Do not exist anymore with Docker 1.11 (issue #848)
            # ret['rss'] = all_stats['memory_stats']['stats']['rss']
            # ret['cache'] = all_stats['memory_stats']['stats']['cache']
            ret['usage'] = all_stats['memory_stats']['usage']
            ret['limit'] = all_stats['memory_stats']['limit']
            ret['max_usage'] = all_stats['memory_stats']['max_usage']
        except (KeyError, TypeError) as e:
            # all_stats do not have MEM information
            logger.debug("docker plugin - Cannot grab MEM usage for container {} ({})".format(container_id, e))
            logger.debug(all_stats)
        # Return the stats
        return ret

    def get_docker_network(self, container_id, all_stats):
        """Return the container network usage using the Docker API (v1.0 or higher).

        Input: id is the full container id
        Output: a dict {'time_since_update': 3000, 'rx': 10, 'tx': 65}.
        with:
            time_since_update: number of seconds elapsed between the latest grab
            rx: Number of byte received
            tx: Number of byte transmited
        """
        # Init the returned dict
        network_new = {}

        # Read the rx/tx stats (in bytes)
        try:
            netcounters = all_stats["networks"]
        except KeyError as e:
            # all_stats do not have NETWORK information
            logger.debug("docker plugin - Cannot grab NET usage for container {} ({})".format(container_id, e))
            logger.debug(all_stats)
            # No fallback available...
            return network_new

        # Previous network interface stats are stored in the network_old variable
        if not hasattr(self, 'inetcounters_old'):
            # First call, we init the network_old var
            self.netcounters_old = {}
            try:
                self.netcounters_old[container_id] = netcounters
            except (IOError, UnboundLocalError):
                pass

        if container_id not in self.netcounters_old:
            try:
                self.netcounters_old[container_id] = netcounters
            except (IOError, UnboundLocalError):
                pass
        else:
            # By storing time data we enable Rx/s and Tx/s calculations in the
            # XML/RPC API, which would otherwise be overly difficult work
            # for users of the API
            try:
                network_new['time_since_update'] = getTimeSinceLastUpdate('docker_net_{}'.format(container_id))
                network_new['rx'] = netcounters["eth0"]["rx_bytes"] - self.netcounters_old[container_id]["eth0"]["rx_bytes"]
                network_new['tx'] = netcounters["eth0"]["tx_bytes"] - self.netcounters_old[container_id]["eth0"]["tx_bytes"]
                network_new['cumulative_rx'] = netcounters["eth0"]["rx_bytes"]
                network_new['cumulative_tx'] = netcounters["eth0"]["tx_bytes"]
            except KeyError as e:
                # all_stats do not have INTERFACE information
                logger.debug("docker plugin - Cannot grab network interface usage for container {} ({})".format(container_id, e))
                logger.debug(all_stats)

            # Save stats to compute next bitrate
            self.netcounters_old[container_id] = netcounters

        # Return the stats
        return network_new

    def get_docker_io(self, container_id, all_stats):
        """Return the container IO usage using the Docker API (v1.0 or higher).

        Input: id is the full container id
        Output: a dict {'time_since_update': 3000, 'ior': 10, 'iow': 65}.
        with:
            time_since_update: number of seconds elapsed between the latest grab
            ior: Number of byte readed
            iow: Number of byte written
        """
        # Init the returned dict
        io_new = {}

        # Read the ior/iow stats (in bytes)
        try:
            iocounters = all_stats["blkio_stats"]
        except KeyError as e:
            # all_stats do not have io information
            logger.debug("docker plugin - Cannot grab block IO usage for container {} ({})".format(container_id, e))
            logger.debug(all_stats)
            # No fallback available...
            return io_new

        # Previous io interface stats are stored in the io_old variable
        if not hasattr(self, 'iocounters_old'):
            # First call, we init the io_old var
            self.iocounters_old = {}
            try:
                self.iocounters_old[container_id] = iocounters
            except (IOError, UnboundLocalError):
                pass

        if container_id not in self.iocounters_old:
            try:
                self.iocounters_old[container_id] = iocounters
            except (IOError, UnboundLocalError):
                pass
        else:
            # By storing time data we enable IoR/s and IoW/s calculations in the
            # XML/RPC API, which would otherwise be overly difficult work
            # for users of the API
            try:
                # Read IOR and IOW value in the structure list of dict
                ior = [i for i in iocounters['io_service_bytes_recursive'] if i['op'] == 'Read'][0]['value']
                iow = [i for i in iocounters['io_service_bytes_recursive'] if i['op'] == 'Write'][0]['value']
                ior_old = [i for i in self.iocounters_old[container_id]['io_service_bytes_recursive'] if i['op'] == 'Read'][0]['value']
                iow_old = [i for i in self.iocounters_old[container_id]['io_service_bytes_recursive'] if i['op'] == 'Write'][0]['value']
            except (IndexError, KeyError) as e:
                # all_stats do not have io information
                logger.debug("docker plugin - Cannot grab block IO usage for container {} ({})".format(container_id, e))
            else:
                io_new['time_since_update'] = getTimeSinceLastUpdate('docker_io_{}'.format(container_id))
                io_new['ior'] = ior - ior_old
                io_new['iow'] = iow - iow_old
                io_new['cumulative_ior'] = ior
                io_new['cumulative_iow'] = iow

                # Save stats to compute next bitrate
                self.iocounters_old[container_id] = iocounters

        # Return the stats
        return io_new

    def get_user_ticks(self):
        """Return the user ticks by reading the environment variable."""
        return os.sysconf(os.sysconf_names['SC_CLK_TCK'])

    def get_stats_action(self):
        """Return stats for the action
        Docker will return self.stats['containers']"""
        return self.stats['containers']

    def update_views(self):
        """Update stats views."""
        # Call the father's method
        super(Plugin, self).update_views()

        if 'containers' not in self.stats:
            return False

        # Add specifics informations
        # Alert
        for i in self.stats['containers']:
            # Init the views for the current container (key = container name)
            self.views[i[self.get_key()]] = {'cpu': {}, 'mem': {}}
            # CPU alert
            if 'cpu' in i and 'total' in i['cpu']:
                # Looking for specific CPU container threasold in the conf file
                alert = self.get_alert(i['cpu']['total'],
                                       header=i['name'] + '_cpu',
                                       action_key=i['name'])
                if alert == 'DEFAULT':
                    # Not found ? Get back to default CPU threasold value
                    alert = self.get_alert(i['cpu']['total'], header='cpu')
                self.views[i[self.get_key()]]['cpu']['decoration'] = alert
            # MEM alert
            if 'memory' in i and 'usage' in i['memory']:
                # Looking for specific MEM container threasold in the conf file
                alert = self.get_alert(i['memory']['usage'],
                                       maximum=i['memory']['limit'],
                                       header=i['name'] + '_mem',
                                       action_key=i['name'])
                if alert == 'DEFAULT':
                    # Not found ? Get back to default MEM threasold value
                    alert = self.get_alert(i['memory']['usage'],
                                           maximum=i['memory']['limit'],
                                           header='mem')
                self.views[i[self.get_key()]]['mem']['decoration'] = alert

        return True

    def msg_curse(self, args=None):
        """Return the dict to display in the curse interface."""
        # Init the return message
        ret = []

        # Only process if stats exist (and non null) and display plugin enable...
        if not self.stats or len(self.stats['containers']) == 0 or self.is_disable():
            return ret

        # Build the string message
        # Title
        msg = '{}'.format('CONTAINERS')
        ret.append(self.curse_add_line(msg, "TITLE"))
        msg = ' {}'.format(len(self.stats['containers']))
        ret.append(self.curse_add_line(msg))
        msg = ' (served by Docker {})'.format(self.stats['version']["Version"])
        ret.append(self.curse_add_line(msg))
        ret.append(self.curse_new_line())
        # Header
        ret.append(self.curse_new_line())
        # msg = '{:>14}'.format('Id')
        # ret.append(self.curse_add_line(msg))
        # Get the maximum containers name (cutted to 20 char max)
        name_max_width = min(20, len(max(self.stats['containers'], key=lambda x: len(x['name']))['name']))
        msg = ' {:{width}}'.format('Name', width=name_max_width)
        ret.append(self.curse_add_line(msg))
        msg = '{:>26}'.format('Status')
        ret.append(self.curse_add_line(msg))
        msg = '{:>6}'.format('CPU%')
        ret.append(self.curse_add_line(msg))
        msg = '{:>7}'.format('MEM')
        ret.append(self.curse_add_line(msg))
        msg = '{:>7}'.format('/MAX')
        ret.append(self.curse_add_line(msg))
        msg = '{:>7}'.format('IOR/s')
        ret.append(self.curse_add_line(msg))
        msg = '{:>7}'.format('IOW/s')
        ret.append(self.curse_add_line(msg))
        msg = '{:>7}'.format('Rx/s')
        ret.append(self.curse_add_line(msg))
        msg = '{:>7}'.format('Tx/s')
        ret.append(self.curse_add_line(msg))
        msg = ' {:8}'.format('Command')
        ret.append(self.curse_add_line(msg))
        # Data
        for container in self.stats['containers']:
            ret.append(self.curse_new_line())
            # Id
            # msg = '{:>14}'.format(container['Id'][0:12])
            # ret.append(self.curse_add_line(msg))
            # Name
            name = container['name']
            if len(name) > name_max_width:
                name = '_' + name[-name_max_width + 1:]
            else:
                name = name[:name_max_width]
            msg = ' {:{width}}'.format(name, width=name_max_width)
            ret.append(self.curse_add_line(msg))
            # Status
            status = self.container_alert(container['Status'])
            msg = container['Status'].replace("minute", "min")
            msg = '{:>26}'.format(msg[0:25])
            ret.append(self.curse_add_line(msg, status))
            # CPU
            try:
                msg = '{:>6.1f}'.format(container['cpu']['total'])
            except KeyError:
                msg = '{:>6}'.format('?')
            ret.append(self.curse_add_line(msg, self.get_views(item=container['name'],
                                                               key='cpu',
                                                               option='decoration')))
            # MEM
            try:
                msg = '{:>7}'.format(self.auto_unit(container['memory']['usage']))
            except KeyError:
                msg = '{:>7}'.format('?')
            ret.append(self.curse_add_line(msg, self.get_views(item=container['name'],
                                                               key='mem',
                                                               option='decoration')))
            try:
                msg = '{:>7}'.format(self.auto_unit(container['memory']['limit']))
            except KeyError:
                msg = '{:>7}'.format('?')
            ret.append(self.curse_add_line(msg))
            # IO R/W
            for r in ['ior', 'iow']:
                try:
                    value = self.auto_unit(int(container['io'][r] // container['io']['time_since_update'] * 8)) + "b"
                    msg = '{:>7}'.format(value)
                except KeyError:
                    msg = '{:>7}'.format('?')
                ret.append(self.curse_add_line(msg))
            # NET RX/TX
            if args.byte:
                # Bytes per second (for dummy)
                to_bit = 1
                unit = ''
            else:
                # Bits per second (for real network administrator | Default)
                to_bit = 8
                unit = 'b'
            for r in ['rx', 'tx']:
                try:
                    value = self.auto_unit(int(container['network'][r] // container['network']['time_since_update'] * to_bit)) + unit
                    msg = '{:>7}'.format(value)
                except KeyError:
                    msg = '{:>7}'.format('?')
                ret.append(self.curse_add_line(msg))
            # Command
            msg = ' {}'.format(container['Command'])
            ret.append(self.curse_add_line(msg, splittable=True))

        return ret

    def container_alert(self, status):
        """Analyse the container status."""
        if "Paused" in status:
            return 'CAREFUL'
        else:
            return 'OK'


class ThreadDockerGrabber(threading.Thread):
    """
    Specific thread to grab docker stats.

    stats is a dict
    """

    def __init__(self, docker_client, container_id):
        """Init the class:
        docker_client: instance of Docker-py client
        container_id: Id of the container"""
        logger.debug("docker plugin - Create thread for container {}".format(container_id[:12]))
        super(ThreadDockerGrabber, self).__init__()
        # Event needed to stop properly the thread
        self._stopper = threading.Event()
        # The docker-py return stats as a stream
        self._container_id = container_id
        self._stats_stream = docker_client.stats(container_id, decode=True)
        # The class return the stats as a dict
        self._stats = {}

    def run(self):
        """Function called to grab stats.
        Infinite loop, should be stopped by calling the stop() method"""

        for i in self._stats_stream:
            self._stats = i
            time.sleep(0.1)
            if self.stopped():
                break

    @property
    def stats(self):
        """Stats getter"""
        return self._stats

    @stats.setter
    def stats(self, value):
        """Stats setter"""
        self._stats = value

    def stop(self, timeout=None):
        """Stop the thread"""
        logger.debug("docker plugin - Close thread for container {}".format(self._container_id[:12]))
        self._stopper.set()

    def stopped(self):
        """Return True is the thread is stopped"""
        return self._stopper.isSet()
                                                                                                                                                                                                                                                                                                                                                                                                ./usr/local/lib/python2.7/dist-packages/glances/__main__.pyc                                        0000664 0000000 0000000 00000000455 13070471670 020725  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   s/   d  Z  d d l Z e d k r+ e j �  n  d S(   s&   Allow user to run Glances as a module.i����Nt   __main__(   t   __doc__t   glancest   __name__t   main(    (    (    s:   /usr/local/lib/python2.7/dist-packages/glances/__main__.pyt   <module>   s                                                                                                                                                                                                                      ./usr/local/lib/python2.7/dist-packages/glances/standalone.pyc                                      0000664 0000000 0000000 00000007222 13070471670 021334  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   s�   d  Z  d d l Z d d l Z d d l m Z d d l m Z d d l m Z d d l	 m
 Z
 d d l m Z d d l
 �  �  YZ d S(   s&   Manage the Glances standalone session.i����N(   t   WINDOWS(   t   logger(   t   glances_processes(   t   GlancesStats(   t   GlancesCursesStandalone(   t   Outdatedt   GlancesStandalonec           B   sG   e  Z d  Z d d d � Z e d �  � Z d �  Z d �  Z d �  Z	 RS(   s>   This class creates and manages the Glances standalone session.c         C   s`  | j  |  _ | j |  _ t d | d | � |  _ | j sS t j d � t	 j
 �  n t j d � t	 j �  | j d  k	 r� | j t	 _ n  t r� | j r� t	 j �  n  y | j r� t	 j �  n  Wn t k
 r� n X|  j j �  |  j  rt j d � d t	 _ n! d t	 _ t d | d | � |  _ t d | d | � |  _ t j d t j d	 t j � |  _ d  S(
   Nt   configt   argss+   Extended stats for top process are disableds*   Extended stats for top process are enableds+   Quiet mode is ON: Nothing will be displayedi    i2   t   timefunct	   delayfunc(   t   quiett   _quiett   timet   refresh_timeR   t   statst   enable_process_extendedR   t   debugR   t   disable_extendedt   enable_extendedt   process_filtert   NoneR    t   no_kernel_threadst   disable_kernel_threadst   process_treet   enable_treet   AttributeErrort   updatet   infot


        This function will restore the terminal to a sane state
        before re-raising the exception and generating a traceback.
        N(   R*   R#   t   runt   end(   R$   (    (    s<   /usr/local/lib/python2.7/dist-packages/glances/standalone.pyt
c         C   sd   |  j  s |  j j �  n  |  j j �  |  j j �  r` d j |  j j �  |  j j �  � GHd GHn  d S(   s   End of the standalone CLI.sB   You are using Glances version {}, however version {} is available.sB   You should consider upgrading using: pip install --upgrade glancesN(	   R   R   R.   R   R   t   is_outdatedt   formatt   installed_versiont   latest_version(   R$   (    (    s<   /usr/local/lib/python2.7/dist-packages/glances/standalone.pyR.   y   s    	
   t   __name__t
   __module__t   __doc__R   R%   t   propertyR   R*   R/   R.   (    (    (    s<   /usr/local/lib/python2.7/dist-packages/glances/standalone.pyR   !   s   4		(   R6   R    R
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""Manage the configuration file."""

import os
import sys
import multiprocessing
from io import open

from glances.compat import ConfigParser, NoOptionError
from glances.globals import BSD, LINUX, MACOS, SUNOS, WINDOWS
from glances.logger import logger


def user_config_dir():
    r"""Return the per-user config dir (full path).

    - Linux, *BSD, SunOS: ~/.config/glances
    - macOS: ~/Library/Application Support/glances
    - Windows: %APPDATA%\glances
    """
    if WINDOWS:
        path = os.environ.get('APPDATA')
    elif MACOS:
        path = os.path.expanduser('~/Library/Application Support')
    else:
        path = os.environ.get('XDG_CONFIG_HOME') or os.path.expanduser('~/.config')
    if path is None:
        path = ''
    else:
        path = os.path.join(path, 'glances')

    return path


def user_cache_dir():
    r"""Return the per-user cache dir (full path).

    - Linux, *BSD, SunOS: ~/.cache/glances
    - macOS: ~/Library/Caches/glances
    - Windows: {%LOCALAPPDATA%,%APPDATA%}\glances\cache
    """
    if WINDOWS:
        path = os.path.join(os.environ.get('LOCALAPPDATA') or os.environ.get('APPDATA'),
                            'glances', 'cache')
    elif MACOS:
        path = os.path.expanduser('~/Library/Caches/glances')
    else:
        path = os.path.join(os.environ.get('XDG_CACHE_HOME') or os.path.expanduser('~/.cache'),
                            'glances')

    return path


def system_config_dir():
    r"""Return the system-wide config dir (full path).

    - Linux, SunOS: /etc/glances
    - *BSD, macOS: /usr/local/etc/glances
    - Windows: %APPDATA%\glances
    """
    if LINUX or SUNOS:
        path = '/etc'
    elif BSD or MACOS:
        path = '/usr/local/etc'
    else:
        path = os.environ.get('APPDATA')
    if path is None:
        path = ''
    else:
        path = os.path.join(path, 'glances')

    return path


class Config(object):

    """This class is used to access/read config file, if it exists.

    :param config_dir: the path to search for config file
    :type config_dir: str or None
    """

    def __init__(self, config_dir=None):
        self.config_dir = config_dir
        self.config_filename = 'glances.conf'
        self._loaded_config_file = None

        self.parser = ConfigParser()
        self.read()

    def config_file_paths(self):
        r"""Get a list of config file paths.

        The list is built taking into account of the OS, priority and location.

        * custom path: /path/to/glances
        * Linux, SunOS: ~/.config/glances, /etc/glances
        * *BSD: ~/.config/glances, /usr/local/etc/glances
        * macOS: ~/Library/Application Support/glances, /usr/local/etc/glances
        * Windows: %APPDATA%\glances

        The config file will be searched in the following order of priority:
            * /path/to/file (via -C flag)
            * user's home directory (per-user settings)
            * system-wide directory (system-wide settings)
        """
        paths = []

        if self.config_dir:
            paths.append(self.config_dir)

        paths.append(os.path.join(user_config_dir(), self.config_filename))
        paths.append(os.path.join(system_config_dir(), self.config_filename))

        return paths

    def read(self):
        """Read the config file, if it exists. Using defaults otherwise."""
        for config_file in self.config_file_paths():
            if os.path.exists(config_file):
                try:
                    with open(config_file, encoding='utf-8') as f:
                        self.parser.read_file(f)
                        self.parser.read(f)
                    logger.info("Read configuration file '{}'".format(config_file))
                except UnicodeDecodeError as err:
                    logger.error("Cannot decode configuration file '{}': {}".format(config_file, err))
                    sys.exit(1)
                # Save the loaded configuration file path (issue #374)
                self._loaded_config_file = config_file
                break

        # Quicklook
        if not self.parser.has_section('quicklook'):
            self.parser.add_section('quicklook')
        self.set_default_cwc('quicklook', 'cpu')
        self.set_default_cwc('quicklook', 'mem')
        self.set_default_cwc('quicklook', 'swap')

        # CPU
        if not self.parser.has_section('cpu'):
            self.parser.add_section('cpu')
        self.set_default_cwc('cpu', 'user')
        self.set_default_cwc('cpu', 'system')
        self.set_default_cwc('cpu', 'steal')
        # By default I/O wait should be lower than 1/number of CPU cores
        iowait_bottleneck = (1.0 / multiprocessing.cpu_count()) * 100.0
        self.set_default_cwc('cpu', 'iowait',
                             [str(iowait_bottleneck - (iowait_bottleneck * 0.20)),
                              str(iowait_bottleneck - (iowait_bottleneck * 0.10)),
                              str(iowait_bottleneck)])
        ctx_switches_bottleneck = 56000 / multiprocessing.cpu_count()
        self.set_default_cwc('cpu', 'ctx_switches',
                             [str(ctx_switches_bottleneck - (ctx_switches_bottleneck * 0.20)),
                              str(ctx_switches_bottleneck - (ctx_switches_bottleneck * 0.10)),
                              str(ctx_switches_bottleneck)])

        # Per-CPU
        if not self.parser.has_section('percpu'):
            self.parser.add_section('percpu')
        self.set_default_cwc('percpu', 'user')
        self.set_default_cwc('percpu', 'system')

        # Load
        if not self.parser.has_section('load'):
            self.parser.add_section('load')
        self.set_default_cwc('load', cwc=['0.7', '1.0', '5.0'])

        # Mem
        if not self.parser.has_section('mem'):
            self.parser.add_section('mem')
        self.set_default_cwc('mem')

        # Swap
        if not self.parser.has_section('memswap'):
            self.parser.add_section('memswap')
        self.set_default_cwc('memswap')

        # NETWORK
        if not self.parser.has_section('network'):
            self.parser.add_section('network')
        self.set_default_cwc('network', 'rx')
        self.set_default_cwc('network', 'tx')

        # FS
        if not self.parser.has_section('fs'):
            self.parser.add_section('fs')
        self.set_default_cwc('fs')

        # Sensors
        if not self.parser.has_section('sensors'):
            self.parser.add_section('sensors')
        self.set_default_cwc('sensors', 'temperature_core', cwc=['60', '70', '80'])
        self.set_default_cwc('sensors', 'temperature_hdd', cwc=['45', '52', '60'])
        self.set_default_cwc('sensors', 'battery', cwc=['80', '90', '95'])

        # Process list
        if not self.parser.has_section('processlist'):
            self.parser.add_section('processlist')
        self.set_default_cwc('processlist', 'cpu')
        self.set_default_cwc('processlist', 'mem')

    @property
    def loaded_config_file(self):
        """Return the loaded configuration file."""
        return self._loaded_config_file

    def as_dict(self):
        """Return the configuration as a dict"""
        dictionary = {}
        for section in self.parser.sections():
            dictionary[section] = {}
            for option in self.parser.options(section):
                dictionary[section][option] = self.parser.get(section, option)
        return dictionary

    def sections(self):
        """Return a list of all sections."""
        return self.parser.sections()

    def items(self, section):
        """Return the items list of a section."""
        return self.parser.items(section)

    def has_section(self, section):
        """Return info about the existence of a section."""
        return self.parser.has_section(section)

    def set_default_cwc(self, section,
                        option_header=None,
                        cwc=['50', '70', '90']):
        """Set default values for careful, warning and critical."""
        if option_header is None:
            header = ''
        else:
            header = option_header + '_'
        self.set_default(section, header + 'careful', cwc[0])
        self.set_default(section, header + 'warning', cwc[1])
        self.set_default(section, header + 'critical', cwc[2])

    def set_default(self, section, option, default):
        """If the option did not exist, create a default value."""
        if not self.parser.has_option(section, option):
            self.parser.set(section, option, default)

    def get_value(self, section, option, default=None):
        """Get the value of an option, if it exists."""
        try:
            return self.parser.get(section, option)
        except NoOptionError:
            return default

    def get_int_value(self, section, option, default=0):
        """Get the int value of an option, if it exists."""
        try:
            return self.parser.getint(section, option)
        except NoOptionError:
            return int(default)

    def get_float_value(self, section, option, default=0.0):
        """Get the float value of an option, if it exists."""
        try:
            return self.parser.getfloat(section, option)
        except NoOptionError:
            return float(default)
                                                                                                                                                                                                  ./usr/local/lib/python2.7/dist-packages/glances/autodiscover.py                                     0000664 0000000 0000000 00000022132 13066703446 021551  0                                                                                                    ustar                                                                                                                                                                                                                                                          # -*- coding: utf-8 -*-
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""Manage autodiscover Glances server (thk to the ZeroConf protocol)."""

import socket
import sys

from glances.globals import BSD
from glances.logger import logger

try:
    from zeroconf import (
        __version__ as __zeroconf_version,
        ServiceBrowser,
        ServiceInfo,
        Zeroconf
    )
    zeroconf_tag = True
except ImportError:
    zeroconf_tag = False

# Zeroconf 0.17 or higher is needed
if zeroconf_tag:
    zeroconf_min_version = (0, 17, 0)
    zeroconf_version = tuple([int(num) for num in __zeroconf_version.split('.')])
    logger.debug("Zeroconf version {} detected.".format(__zeroconf_version))
    if zeroconf_version < zeroconf_min_version:
        logger.critical("Please install zeroconf 0.17 or higher.")
        sys.exit(1)

# Global var
# Recent versions of the zeroconf python package doesnt like a zeroconf type that ends with '._tcp.'.
# Correct issue: zeroconf problem with zeroconf_type = "_%s._tcp." % 'glances' #888
zeroconf_type = "_%s._tcp.local." % 'glances'


class AutoDiscovered(object):

    """Class to manage the auto discovered servers dict."""

    def __init__(self):
        # server_dict is a list of dict (JSON compliant)
        # [ {'key': 'zeroconf name', ip': '172.1.2.3', 'port': 61209, 'cpu': 3, 'mem': 34 ...} ... ]
        self._server_list = []

    def get_servers_list(self):
        """Return the current server list (list of dict)."""
        return self._server_list

    def set_server(self, server_pos, key, value):
        """Set the key to the value for the server_pos (position in the list)."""
        self._server_list[server_pos][key] = value

    def add_server(self, name, ip, port):
        """Add a new server to the list."""
        new_server = {
            'key': name,  # Zeroconf name with both hostname and port
            'name': name.split(':')[0],  # Short name
            'ip': ip,  # IP address seen by the client
            'port': port,  # TCP port
            'username': 'glances',  # Default username
            'password': '',  # Default password
            'status': 'UNKNOWN',  # Server status: 'UNKNOWN', 'OFFLINE', 'ONLINE', 'PROTECTED'
            'type': 'DYNAMIC'}  # Server type: 'STATIC' or 'DYNAMIC'
        self._server_list.append(new_server)
        logger.debug("Updated servers list (%s servers): %s" %
                     (len(self._server_list), self._server_list))

    def remove_server(self, name):
        """Remove a server from the dict."""
        for i in self._server_list:
            if i['key'] == name:
                try:
                    self._server_list.remove(i)
                    logger.debug("Remove server %s from the list" % name)
                    logger.debug("Updated servers list (%s servers): %s" % (
                        len(self._server_list), self._server_list))
                except ValueError:
                    logger.error(
                        "Cannot remove server %s from the list" % name)


class GlancesAutoDiscoverListener(object):

    """Zeroconf listener for Glances server."""

    def __init__(self):
        # Create an instance of the servers list
        self.servers = AutoDiscovered()

    def get_servers_list(self):
        """Return the current server list (list of dict)."""
        return self.servers.get_servers_list()

    def set_server(self, server_pos, key, value):
        """Set the key to the value for the server_pos (position in the list)."""
        self.servers.set_server(server_pos, key, value)

    def add_service(self, zeroconf, srv_type, srv_name):
        """Method called when a new Zeroconf client is detected.

        Return True if the zeroconf client is a Glances server
        Note: the return code will never be used
        """
        if srv_type != zeroconf_type:
            return False
        logger.debug("Check new Zeroconf server: %s / %s" %
                     (srv_type, srv_name))
        info = zeroconf.get_service_info(srv_type, srv_name)
        if info:
            new_server_ip = socket.inet_ntoa(info.address)
            new_server_port = info.port

            # Add server to the global dict
            self.servers.add_server(srv_name, new_server_ip, new_server_port)
            logger.info("New Glances server detected (%s from %s:%s)" %
                        (srv_name, new_server_ip, new_server_port))
        else:
            logger.warning(
                "New Glances server detected, but Zeroconf info failed to be grabbed")
        return True

    def remove_service(self, zeroconf, srv_type, srv_name):
        """Remove the server from the list."""
        self.servers.remove_server(srv_name)
        logger.info(
            "Glances server %s removed from the autodetect list" % srv_name)


class GlancesAutoDiscoverServer(object):

    """Implementation of the Zeroconf protocol (server side for the Glances client)."""

    def __init__(self, args=None):
        if zeroconf_tag:
            logger.info("Init autodiscover mode (Zeroconf protocol)")
            try:
                self.zeroconf = Zeroconf()
            except socket.error as e:
                logger.error("Cannot start Zeroconf (%s)" % e)
                self.zeroconf_enable_tag = False
            else:
                self.listener = GlancesAutoDiscoverListener()
                self.browser = ServiceBrowser(
                    self.zeroconf, zeroconf_type, self.listener)
                self.zeroconf_enable_tag = True
        else:
            logger.error("Cannot start autodiscover mode (Zeroconf lib is not installed)")
            self.zeroconf_enable_tag = False

    def get_servers_list(self):
        """Return the current server list (dict of dict)."""
        if zeroconf_tag and self.zeroconf_enable_tag:
            return self.listener.get_servers_list()
        else:
            return []

    def set_server(self, server_pos, key, value):
        """Set the key to the value for the server_pos (position in the list)."""
        if zeroconf_tag and self.zeroconf_enable_tag:
            self.listener.set_server(server_pos, key, value)

    def close(self):
        if zeroconf_tag and self.zeroconf_enable_tag:
            self.zeroconf.close()


class GlancesAutoDiscoverClient(object):

    """Implementation of the zeroconf protocol (client side for the Glances server)."""

    def __init__(self, hostname, args=None):
        if zeroconf_tag:
            zeroconf_bind_address = args.bind_address
            try:
                self.zeroconf = Zeroconf()
            except socket.error as e:
                logger.error("Cannot start zeroconf: {}".format(e))

            # XXX *BSDs: Segmentation fault (core dumped)
            # -- https://bitbucket.org/al45tair/netifaces/issues/15
            if not BSD:
                try:
                    # -B @ overwrite the dynamic IPv4 choice
                    if zeroconf_bind_address == '0.0.0.0':
                        zeroconf_bind_address = self.find_active_ip_address()
                except KeyError:
                    # Issue #528 (no network interface available)
                    pass

            # Check IP v4/v6
            address_family = socket.getaddrinfo(zeroconf_bind_address, args.port)[0][0]

            # Start the zeroconf service
            self.info = ServiceInfo(
                zeroconf_type, '{}:{}.{}'.format(hostname, args.port, zeroconf_type),
                address=socket.inet_pton(address_family, zeroconf_bind_address),
                port=args.port, weight=0, priority=0, properties={}, server=hostname)
            try:
                self.zeroconf.register_service(self.info)
            except socket.error as e:
                logger.error("Error while announcing Glances server: {}".format(e))
            else:
                print("Announce the Glances server on the LAN (using {} IP address)".format(zeroconf_bind_address))
        else:
            logger.error("Cannot announce Glances server on the network: zeroconf library not found.")

    @staticmethod
    def find_active_ip_address():
        """Try to find the active IP addresses."""
        import netifaces
        # Interface of the default gateway
        gateway_itf = netifaces.gateways()['default'][netifaces.AF_INET][1]
        # IP address for the interface
        return netifaces.ifaddresses(gateway_itf)[netifaces.AF_INET][0]['addr']

    def close(self):
        if zeroconf_tag:
            self.zeroconf.unregister_service(self.info)
            self.zeroconf.close()
                                                                                                                                                                                                                                                                                                                                                                                                                                      ./usr/local/lib/python2.7/dist-packages/glances/client_browser.pyc                                  0000664 0000000 0000000 00000016572 13070471670 022235  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   s�   d  Z  d d l Z d d l Z d d l Z d d l m Z m Z m Z d d l m	 Z	 d d l
 m Z m Z d d l
 e f d �  �  YZ d S(   s;   Manage the Glances client browser (list of Glances server).i����N(   t   Faultt
 d �  Z d	 �  Z d
 �  Z
 d  S(   Nt   args(   R   t   configt   Nonet
   t   screen(   t   selfR
	c         C   s.   t  d |  j � |  _ t d |  j � |  _ d S(   s9   Load server and password list from the confiuration file.R

        Merge of static + autodiscover servers list.
        N(   R   t   browserR   t   get_servers_listR   R   (   R   t   ret(    (    s@   /usr/local/lib/python2.7/dist-packages/glances/client_browser.pyR   B   s    "c         C   s�   | d d k r� | d d k r^ |  j  j | d � } | d k	 r^ |  j  j | � | d <q^ n  d j | d | d | d | d	 � Sd
 j | d | d	 � Sd S(   s)   Return the URI for the given server dict.R   t    t   statust	   PROTECTEDt   names   http://{}:{}@{}:{}t   usernamet   ipt   ports   http://{}:{}N(   R   t   get_passwordR   t   sha256_hasht   format(   R   t   servert   clear_password(    (    s@   /usr/local/lib/python2.7/dist-packages/glances/client_browser.pyt	   __get_uriP   s    c         C   s�  |  j  | � } t �  } | j d � y t | d | �} Wn, t k
 ri } t j d j | | � � n�Xyn d t j	 | j
 �  � d } d j | � | d <t j	 | j �  � d | d	 <t j	 | j �  � d
 | d
 <Wn� t
 r} t j d j | | � � d | d
 r�} | j d k rQd | d <d | d
 d | d
 r�} t j d j | | � � n X| S(   sQ   
        Update stats for the given server (picked from the server list)
        i   t	   transports,   Client browser couldn't create socket {}: {}id   t   idles   {:.1f}t   cpu_percentt   percentt   mem_percentt   hr_names&   Error while grabbing stats form {}: {}t   OFFLINER   i�  R   R   s!   Cannot grab stats from {} ({} {})t   ONLINEt   min5s   {:.2f}t	   load_min5N(   t   _GlancesClientBrowser__get_uriR   t   set_timeoutR   t	   ExceptionR   t   warningR$   t   jsont   loadst   getCput   getMemt	   getSystemt   sockett   errorR    t   KeyErrort   debugR   t   errcodeR   t   errmsgt   getLoad(   R   R%   t   urit   tt   st   eR*   R1   (    (    s@   /usr/local/lib/python2.7/dist-packages/glances/client_browser.pyt   __update_stats^   s>    	

&
c         C   s  t  j d j | � � |  j j d j | d | d � d d �| d d k r� |  j j | d � } | d k s� |  j �  |  j j	 d d	 k r� |  j j d
 j | d � d t
 �} n  | d k	 r� |  j d |  j j | � � q� n  t  j
 � } | j �  s�|  j j d j | d t � � |  j d d � nm | j �  } y t  j d j | d
 r�n0 X| d k r�|  j d d � n |  j d d � d |  j _	 d S(   s6   
        Connect and display the given server
        s   Selected server: {}s   Connect to {}:{}R   R!   t   durationi   R   R   R   s   Password needed for {}: t   is_inputs'   Connect Glances client to the {} servert   keyR    R   R
See '{}' for more detailsR.   s,   Disconnect Glances client from the {} servert   snmpt   SNMPR/   N(   R   R>   R$   R   t
   IndexError(   R   R%   R&   t   args_serverRR   t   connection_type(    (    s@   /usr/local/lib/python2.7/dist-packages/glances/client_browser.pyt   __display_server�   s@    	!	"	
 d k r� |  j	 j |  j �  � q |  j
 � q Wd S(   s   Main client loop.s*   Iter through the following server list: {}t   targetR   N(   RO   R   R>   R$   R   t	   threadingt   Threadt#   _GlancesClientBrowser__update_statst   startR   RN   R   t   updatet%   _GlancesClientBrowser__display_server(   R   t   vt   thread(    (    s@   /usr/local/lib/python2.7/dist-packages/glances/client_browser.pyt   __serve_forever�   s    	c         C   s    z |  j  �  SWd |  j �  Xd S(   s�   Wrapper to the serve_forever function.

        This function will restore the terminal to a sane state
        before re-raising the exception and generating a traceback.
        N(   t$   _GlancesClientBrowser__serve_forevert   end(   R   (    (    s@   /usr/local/lib/python2.7/dist-packages/glances/client_browser.pyRT   �   s    c         C   ss   |  j  j t |  j j �  � k rS |  j j |  j  j t |  j j �  � | | � n |  j j |  j  j | | � d S(   s9   Set the (key, value) for the selected server in the list.N(   R   RN   t   lenR   R   R   t
   set_server(   R   RI   t   value(    (    s@   /usr/local/lib/python2.7/dist-packages/glances/client_browser.pyRP   �   s
    !	
   __module__t   __doc__R   R   R   R   R2   R\   R_   Rc   RT   RP   Rd   (    (    (    s@   /usr/local/lib/python2.7/dist-packages/glances/client_browser.pyR   #   s   				7	C			
(   Rj   R6   R;   RZ   t   glances.compatR    R   R   t   glances.autodiscoverR   t   glances.clientR   R   t   glances.loggerR   R   t   glances.password_listR   R   t   glances.static_listR	   t&   glances.outputs.glances_curses_browserR
   t   objectR   (    (    (    s@   /usr/local/lib/python2.7/dist-packages/glances/client_browser.pyt   <module>   s                                                                                                                                         ./usr/local/lib/python2.7/dist-packages/glances/compat.py                                           0000664 0000000 0000000 00000007243 13066703446 020333  0                                                                                                    ustar                                                                                                                                                                                                                                                          # -*- coding: utf-8 -*-
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

# flake8: noqa
# pylint: skip-file
"""Python 2/3 compatibility shims."""

import operator
import sys
import unicodedata
import types

PY3 = sys.version_info[0] == 3

if PY3:
    import queue
    from configparser import ConfigParser, NoOptionError, NoSectionError
    from xmlrpc.client import Fault, ProtocolError, ServerProxy, Transport, Server
    from xmlrpc.server import SimpleXMLRPCRequestHandler, SimpleXMLRPCServer
    from urllib.request import urlopen
    from urllib.error import HTTPError, URLError

    input = input
    range = range
    map = map

    text_type = str
    binary_type = bytes
    bool_type = bool

    viewkeys = operator.methodcaller('keys')
    viewvalues = operator.methodcaller('values')
    viewitems = operator.methodcaller('items')

    def to_ascii(s):
        """Convert the bytes string to a ASCII string
        Usefull to remove accent (diacritics)"""
        return str(s, 'utf-8')

    def listitems(d):
        return list(d.items())

    def listkeys(d):
        return list(d.keys())

    def listvalues(d):
        return list(d.values())

    def iteritems(d):
        return iter(d.items())

    def iterkeys(d):
        return iter(d.keys())

    def itervalues(d):
        return iter(d.values())

    def u(s):
        return s

    def b(s):
        if isinstance(s, binary_type):
            return s
        return s.encode('latin-1')

    def nativestr(s):
        if isinstance(s, text_type):
            return s
        return s.decode('utf-8', 'replace')
else:
    import Queue as queue
    from itertools import imap as map
    from ConfigParser import SafeConfigParser as ConfigParser, NoOptionError, NoSectionError
    from SimpleXMLRPCServer import SimpleXMLRPCRequestHandler, SimpleXMLRPCServer
    from xmlrpclib import Fault, ProtocolError, ServerProxy, Transport, Server
    from urllib2 import urlopen, HTTPError, URLError

    input = raw_input
    range = xrange
    ConfigParser.read_file = ConfigParser.readfp

    text_type = unicode
    binary_type = str
    bool_type = types.BooleanType

    viewkeys = operator.methodcaller('viewkeys')
    viewvalues = operator.methodcaller('viewvalues')
    viewitems = operator.methodcaller('viewitems')

    def to_ascii(s):
        """Convert the unicode 's' to a ASCII string
        Usefull to remove accent (diacritics)"""
        if isinstance(s, binary_type):
            return s
        return unicodedata.normalize('NFKD', s).encode('ASCII', 'ignore')

    def listitems(d):
        return d.items()

    def listkeys(d):
        return d.keys()

    def listvalues(d):
        return d.values()

    def iteritems(d):
        return d.iteritems()

    def iterkeys(d):
        return d.iterkeys()

    def itervalues(d):
        return d.itervalues()

    def u(s):
        return s.decode('utf-8')

    def b(s):
        return s

    def nativestr(s):
        if isinstance(s, binary_type):
            return s
        return s.encode('utf-8', 'replace')
                                                                                                                                                                                                                                                                                                                                                             ./usr/local/lib/python2.7/dist-packages/glances/client_browser.py                                   0000664 0000000 0000000 00000024403 13066703446 022066  0                                                                                                    ustar                                                                                                                                                                                                                                                          # -*- coding: utf-8 -*-
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""Manage the Glances client browser (list of Glances server)."""

import json
import socket
import threading

from glances.compat import Fault, ProtocolError, ServerProxy
from glances.autodiscover import GlancesAutoDiscoverServer
from glances.client import GlancesClient, GlancesClientTransport
from glances.logger import logger, LOG_FILENAME
from glances.password_list import GlancesPasswordList as GlancesPassword
from glances.static_list import GlancesStaticServer
from glances.outputs.glances_curses_browser import GlancesCursesBrowser


class GlancesClientBrowser(object):

    """This class creates and manages the TCP client browser (servers list)."""

    def __init__(self, config=None, args=None):
        # Store the arg/config
        self.args = args
        self.config = config
        self.static_server = None
        self.password = None

        # Load the configuration file
        self.load()

        # Start the autodiscover mode (Zeroconf listener)
        if not self.args.disable_autodiscover:
            self.autodiscover_server = GlancesAutoDiscoverServer()
        else:
            self.autodiscover_server = None

        # Init screen
        self.screen = GlancesCursesBrowser(args=self.args)

    def load(self):
        """Load server and password list from the confiuration file."""
        # Init the static server list (if defined)
        self.static_server = GlancesStaticServer(config=self.config)

        # Init the password list (if defined)
        self.password = GlancesPassword(config=self.config)

    def get_servers_list(self):
        """Return the current server list (list of dict).

        Merge of static + autodiscover servers list.
        """
        ret = []

        if self.args.browser:
            ret = self.static_server.get_servers_list()
            if self.autodiscover_server is not None:
                ret = self.static_server.get_servers_list() + self.autodiscover_server.get_servers_list()

        return ret

    def __get_uri(self, server):
        """Return the URI for the given server dict."""
        # Select the connection mode (with or without password)
        if server['password'] != "":
            if server['status'] == 'PROTECTED':
                # Try with the preconfigure password (only if status is PROTECTED)
                clear_password = self.password.get_password(server['name'])
                if clear_password is not None:
                    server['password'] = self.password.sha256_hash(clear_password)
            return 'http://{}:{}@{}:{}'.format(server['username'], server['password'],
                                               server['ip'], server['port'])
        else:
            return 'http://{}:{}'.format(server['ip'], server['port'])

    def __update_stats(self, server):
        """
        Update stats for the given server (picked from the server list)
        """
        # Get the server URI
        uri = self.__get_uri(server)

        # Try to connect to the server
        t = GlancesClientTransport()
        t.set_timeout(3)

        # Get common stats
        try:
            s = ServerProxy(uri, transport=t)
        except Exception as e:
            logger.warning(
                "Client browser couldn't create socket {}: {}".format(uri, e))
        else:
            # Mandatory stats
            try:
                # CPU%
                cpu_percent = 100 - json.loads(s.getCpu())['idle']
                server['cpu_percent'] = '{:.1f}'.format(cpu_percent)
                # MEM%
                server['mem_percent'] = json.loads(s.getMem())['percent']
                # OS (Human Readable name)
                server['hr_name'] = json.loads(s.getSystem())['hr_name']
            except (socket.error, Fault, KeyError) as e:
                logger.debug(
                    "Error while grabbing stats form {}: {}".format(uri, e))
                server['status'] = 'OFFLINE'
            except ProtocolError as e:
                if e.errcode == 401:
                    # Error 401 (Authentication failed)
                    # Password is not the good one...
                    server['password'] = None
                    server['status'] = 'PROTECTED'
                else:
                    server['status'] = 'OFFLINE'
                logger.debug("Cannot grab stats from {} ({} {})".format(uri, e.errcode, e.errmsg))
            else:
                # Status
                server['status'] = 'ONLINE'

                # Optional stats (load is not available on Windows OS)
                try:
                    # LOAD
                    load_min5 = json.loads(s.getLoad())['min5']
                    server['load_min5'] = '{:.2f}'.format(load_min5)
                except Exception as e:
                    logger.warning(
                        "Error while grabbing stats form {}: {}".format(uri, e))

        return server

    def __display_server(self, server):
        """
        Connect and display the given server
        """
        # Display the Glances client for the selected server
        logger.debug("Selected server: {}".format(server))

        # Connection can take time
        # Display a popup
        self.screen.display_popup(
            'Connect to {}:{}'.format(server['name'], server['port']), duration=1)

        # A password is needed to access to the server's stats
        if server['password'] is None:
            # First of all, check if a password is available in the [passwords] section
            clear_password = self.password.get_password(server['name'])
            if (clear_password is None or self.get_servers_list()
                    [self.screen.active_server]['status'] == 'PROTECTED'):
                # Else, the password should be enter by the user
                # Display a popup to enter password
                clear_password = self.screen.display_popup(
                    'Password needed for {}: '.format(server['name']), is_input=True)
            # Store the password for the selected server
            if clear_password is not None:
                self.set_in_selected('password', self.password.sha256_hash(clear_password))

        # Display the Glance client on the selected server
        logger.info("Connect Glances client to the {} server".format(server['key']))

        # Init the client
        args_server = self.args

        # Overwrite connection setting
        args_server.client = server['ip']
        args_server.port = server['port']
        args_server.username = server['username']
        args_server.password = server['password']
        client = GlancesClient(config=self.config, args=args_server, return_to_browser=True)

        # Test if client and server are in the same major version
        if not client.login():
            self.screen.display_popup(
                "Sorry, cannot connect to '{}'\n"
                "See '{}' for more details".format(server['name'], LOG_FILENAME))

            # Set the ONLINE status for the selected server
            self.set_in_selected('status', 'OFFLINE')
        else:
            # Start the client loop
            # Return connection type: 'glances' or 'snmp'
            connection_type = client.serve_forever()

            try:
                logger.debug("Disconnect Glances client from the {} server".format(server['key']))
            except IndexError:
                # Server did not exist anymore
                pass
            else:
                # Set the ONLINE status for the selected server
                if connection_type == 'snmp':
                    self.set_in_selected('status', 'SNMP')
                else:
                    self.set_in_selected('status', 'ONLINE')

        # Return to the browser (no server selected)
        self.screen.active_server = None

    def __serve_forever(self):
        """Main client loop."""
        # No need to update the server list
        # It's done by the GlancesAutoDiscoverListener class (autodiscover.py)
        # Or define staticaly in the configuration file (module static_list.py)
        # For each server in the list, grab elementary stats (CPU, LOAD, MEM, OS...)

        while True:
            logger.debug("Iter through the following server list: {}".format(self.get_servers_list()))
            for v in self.get_servers_list():
                thread = threading.Thread(target=self.__update_stats, args=[v])
                thread.start()

            # Update the screen (list or Glances client)
            if self.screen.active_server is None:
                #  Display the Glances browser
                self.screen.update(self.get_servers_list())
            else:
                # Display the active server
                self.__display_server(self.get_servers_list()[self.screen.active_server])

    def serve_forever(self):
        """Wrapper to the serve_forever function.

        This function will restore the terminal to a sane state
        before re-raising the exception and generating a traceback.
        """
        try:
            return self.__serve_forever()
        finally:
            self.end()

    def set_in_selected(self, key, value):
        """Set the (key, value) for the selected server in the list."""
        # Static list then dynamic one
        if self.screen.active_server >= len(self.static_server.get_servers_list()):
            self.autodiscover_server.set_server(
                self.screen.active_server - len(self.static_server.get_servers_list()),
                key, value)
        else:
            self.static_server.set_server(self.screen.active_server, key, value)

    def end(self):
        """End of the client browser session."""
        self.screen.end()
                                                                                                                                                                                                                                                             ./usr/local/lib/python2.7/dist-packages/glances/timer.py                                            0000664 0000000 0000000 00000004060 13066703446 020162  0                                                                                                    ustar                                                                                                                                                                                                                                                          # -*- coding: utf-8 -*-
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""The timer manager."""

from time import time
from datetime import datetime

# Global list to manage the elapsed time
last_update_times = {}


def getTimeSinceLastUpdate(IOType):
    """Return the elapsed time since last update."""
    global last_update_times
    # assert(IOType in ['net', 'disk', 'process_disk'])
    current_time = time()
    last_time = last_update_times.get(IOType)
    if not last_time:
        time_since_update = 1
    else:
        time_since_update = current_time - last_time
    last_update_times[IOType] = current_time
    return time_since_update


class Timer(object):

    """The timer class. A simple chronometer."""

    def __init__(self, duration):
        self.duration = duration
        self.start()

    def start(self):
        self.target = time() + self.duration

    def reset(self):
        self.start()

    def get(self):
        return self.duration - (self.target - time())

    def set(self, duration):
        self.duration = duration

    def finished(self):
        return time() > self.target


class Counter(object):

    """The counter class."""

    def __init__(self):
        self.start()

    def start(self):
        self.target = datetime.now()

    def reset(self):
        self.start()

    def get(self):
        return (datetime.now() - self.target).total_seconds()
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                ./usr/local/lib/python2.7/dist-packages/glances/webserver.py                                        0000664 0000000 0000000 00000003334 13066703446 021051  0                                                                                                    ustar                                                                                                                                                                                                                                                          # -*- coding: utf-8 -*-
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""Glances Web Interface (Bottle based)."""

from glances.globals import WINDOWS
from glances.processes import glances_processes
from glances.stats import GlancesStats
from glances.outputs.glances_bottle import GlancesBottle


class GlancesWebServer(object):

    """This class creates and manages the Glances Web server session."""

    def __init__(self, config=None, args=None):
        # Init stats
        self.stats = GlancesStats(config, args)

        if not WINDOWS and args.no_kernel_threads:
            # Ignore kernel threads in process list
            glances_processes.disable_kernel_threads()

        # Initial system informations update
        self.stats.update()

        # Init the Bottle Web server
        self.web = GlancesBottle(config=config, args=args)

    def serve_forever(self):
        """Main loop for the Web server."""
        self.web.start(self.stats)

    def end(self):
        """End of the Web server."""
        self.web.end()
        self.stats.end()
                                                                                                                                                                                                                                                                                                    ./usr/local/lib/python2.7/dist-packages/glances/snmp.pyc                                            0000664 0000000 0000000 00000007673 13070471670 020173  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   sx   d  d l  Z  d  d l m Z y d  d l m Z Wn+ e k
 r] e j d � e  j d � n Xd e f d �  �  YZ	 d S(   i����N(   t   logger(   t   cmdgens;   PySNMP library not found. To install it: pip install pysnmpi   t   GlancesSNMPClientc           B   sV   e  Z d  Z d d d d d d d � Z d �  Z d	 �  Z d
 �  Z d �  Z d �  Z RS(
 | |  _ d  S(   N(   t   superR   t   __init__R   t   CommandGeneratort   cmdGent   versiont   hostt   portt	   communityt   usert   auth(   t   selfR
   startswith(   R   t   varBindst   rett   namet   val(    (    s6   /usr/local/lib/python2.7/dist-packages/glances/snmp.pyt
   errorIndexR   R   (    (    s6   /usr/local/lib/python2.7/dist-packages/glances/snmp.pyt   __get_result__@   s    c         G   s�   |  j  d k r] |  j j t j |  j |  j � t j |  j |  j	 f � | � \ } } } } nE |  j j t j
 |  j � t j |  j |  j	 f � | � \ } } } } |  j | | | | � S(   s   SNMP simple request (list of OID).

        One request per OID list.

        * oid: oid list
        > Return a dict
        t   3(
   get_by_oidG   s    		c         C   sB   g  } | s | r> x' | D] } | j  |  j | � � q Wn  | S(   N(   t   appendR   (   R   R   R   R   t   varBindTableR   t   varBindTableRow(    (    s6   /usr/local/lib/python2.7/dist-packages/glances/snmp.pyt   __bulk_result__]   s
    
 f � | | | � \ } } } } n  |  j  j d � r� |  j j t j |  j
 f � | | | � \ } } } } n g  S|  j | | | | � S(   s�  SNMP getbulk request.

        In contrast to snmpwalk, this information will typically be gathered in
        a single transaction with the agent, rather than one transaction per
        variable found.

        * non_repeaters: This specifies the number of supplied variables that
          should not be iterated over.
        * max_repetitions: This specifies the maximum number of iterations over
          the repeating variables.
        * oid: oid list
        > Return a list of dicts
        R    t   2(   R   R   R   R!   R   R"   R   R   R#   R
   __module__t   __doc__R	   R   R   R&   R*   R/   (    (    (    s6   /usr/local/lib/python2.7/dist-packages/glances/snmp.pyR       s   		
   t   syst   glances.loggerR    t   pysnmp.entity.rfc3413.onelinerR   t   ImportErrort   criticalt   exitt   objectR   (    (    (    s6   /usr/local/lib/python2.7/dist-packages/glances/snmp.pyt   <module>   s   
&��Xc           @   s�   d  Z  d d l m Z d d l m Z d d l m Z e so y d d l Z e Z	 Wqu e
 k
 rk e Z	 qu Xn e Z	 d e f d �  �  YZ
 RS(	   s+   Manage the ports list for the ports plugin.t   portsi<   i   c         C   s   |  j  | � |  _ d  S(   N(   t   loadt   _ports_list(   t   selft   configt   args(    (    s<   /usr/local/lib/python2.7/dist-packages/glances/ports_list.pyt   __init__/   s    c   	   	   C   s  g  } | d k r" t j d � n�| j |  j � sK t j d |  j � n�t j d |  j � t | j |  j d d |  j �� } t | j |  j d d |  j �� } | j |  j d d d �} | j	 �  j
 d	 � r�t r�i  } y# t j
 | d <Wn t k
 r#d | d <n Xd
 | d <d
 � | d <| j |  j d | d d | d | d f �| d <d | d <| | d <t | j |  j d | d | �� | d <| j |  j d | d d �| d <| d d k	 r�t | d � d | d <n  t j d | d | d f � | j | � q�Wt j d | � | S(   s0   Load the ports list from the configuration file.s8   No configuration file available. Cannot load ports list.sB   No [%s] section in the configuration file. Cannot load ports list.s8   Start reading the [%s] section in the configuration filet   refresht   defaultt   timeoutt   port_default_gatewayt   Falset   truei    t   hostt   portt   DefaultGatewayt   descriptiont   statust   rtt_warnings)   Add default gateway %s to the static listi   i   s   port_%s_s   %s%ss
   startswitht
   ports_listR   R





#





   set_server�   s    N(   t   __name__t
   __module__t   __doc__R   R   R   R   R
   R   R-   R1   (    (    (    s<   /usr/local/lib/python2.7/dist-packages/glances/ports_list.pyR   '   s   	P	(   R4   t   glances.compatR    t   glances.loggerR   t   glances.globalsR   R"   t   TrueR!   t   ImportErrorR   t   objectR   (    (    (    s<   /usr/local/lib/python2.7/dist-packages/glances/ports_list.pyt   <module>   s   

&��Xc           @   s�   d  Z  d d l Z d d l Z d d l Z d d l Z d d l m Z m Z d d l m	 Z	 d d l
 m Z d d l m
   s   Glances main class.i����N(   t   __version__t   psutil_version(   t   input(   t   Config(   t   LINUXt   WINDOWS(   t   loggert   GlancesMainc           B   s�   e  Z d  Z d Z d Z e Z d Z d Z d Z	 d Z
 d Z d �  Z d	 �  Z
 �  Z d �  Z d �  Z d
Examples of use:
  Monitor local machine (standalone mode):
    $ glances

  Monitor local machine with the Web interface (Web UI):
    $ glances -w
    Glances web server started on http://0.0.0.0:61208/

  Monitor local machine and export stats to a CSV file (standalone mode):
    $ glances --export-csv /tmp/glances.csv

  Monitor local machine and export stats to a InfluxDB server with 5s refresh time (standalone mode):
    $ glances -t 5 --export-influxdb

  Start a Glances server (server mode):
    $ glances -s

  Connect Glances to a Glances server (client mode):
    $ glances -c <ip_server>

  Connect Glances to a Glances server and export stats to a StatsD server (client mode):
    $ glances -c <ip_server> --export-statsd

  Start the client browser (browser mode):
    $ glances --browser
c         C   s   |  j  �  |  _ d S(   s"   Manage the command line arguments.N(   t
   parse_argst   args(   t   self(    (    s6   /usr/local/lib/python2.7/dist-packages/glances/main.pyt   __init__Q   s    c         C   s  d t  d t } t j d d d d d t j d |  j � } | j d	 d
 d d d | �| j d
 �  d d� d d� j t	 j
 �  � �| j d� d dd d� d d� �| j d� d d d t d d� d d� �| j d� d d d t d d� d d� �| j d� d d d t d d� d d� �| j d� d d d t d d� d d� �| j d� d d d t d d� d d� �| j d� d d d t d d� d d� �| j d� d d d t d d� d d� �| j d� d d d t d d� d d� �| j d� d d d t d d� d d� �| j d� d d d t d d� d d� �| j d� d d d t d d� d d� �| j d� d� d d� d d� �| j d� d� d d d t d d� d d� �| j d� d d d t d d� d d� �| j d� d d d t d d� d d� �| j d� d� d dd� t d d� d d� j |  j
| j d� d d d t d d� d d� �n  t r| j d� d d d t d d� d d �n  | j ddd d d t d dd d�| j dd d d t d dd d�| j dd d d t d d	d d
�| j dd d d t d dd d
   store_truet   defaultt   destt   debugt   helps   enable debug modes   -Cs   --configt	   conf_files   path to the configuration files   --disable-alertt
   disable_fss   disable filesystem modules
   disable_ips   disable IP modules   --disable-loadt   disable_loads   disable load modules
   disable_bgs)   disable background colors in the terminals   --enable-irqt
   enable_irqs   enable IRQ modules   --enable-process-extendedt   enable_process_extendeds$   enable extended stats on top processs   --export-grapht   export_graphs   export stats to graphss   --path-grapht
   path_graphs.   set the export path for graphs (default is {})s   --export-csvt
   export_csvs   export stats to a CSV files   --export-cassandrat   export_cassandrasC   export stats to a Cassandra or Scylla server (cassandra lib needed)s   --export-couchdbt   export_couchdbs3   export stats to a CouchDB server (couch lib needed)s   --export-elasticsearcht   export_elasticsearchsB   export stats to an ElasticSearch server (elasticsearch lib needed)s   --export-influxdbt   export_influxdbs8   export stats to an InfluxDB server (influxdb lib needed)s   --export-kafkat   export_kafkas8   export stats to a Kafka server (kafka-python lib needed)s   --export-opentsdbt   export_opentsdbs6   export stats to an OpenTSDB server (potsdb lib needed)s   --export-prometheust   export_prometheussD   export stats to a Prometheus exporter (prometheus_client lib needed)s   --export-rabbitmqt   export_rabbitmqs1   export stats to rabbitmq broker (pika lib needed)s   --export-riemannt   export_riemanns4   export stats to riemann broker (bernhard lib needed)s   --export-statsdt
   --usernamet   username_prompts   define a client/server usernames
   --passwordt   password_prompts   define a client/server passwords   --snmp-communityt   publict   snmp_communitys   SNMP communitys   --snmp-porti�   t	   snmp_ports	   SNMP ports   --snmp-versiont   2ct   snmp_versions   SNMP version (1, 2c or 3)s   --snmp-usert   privatet	   snmp_users   SNMP username (only for SNMPv3)s   --snmp-autht   passwordt	   snmp_auths)   SNMP authentication key (only for SNMPv3)s   --snmp-forcet
   snmp_forces   force SNMP modes   -ts   --timet   times-   set refresh time in seconds [default: {} sec]s   -ws   --webservert	   webservers.   run Glances in web server mode (bottle needed)s
   fahrenheits6   display temperature in Fahrenheit (default is Celsius)s   --fs-free-spacet
   gettempdirt   formatt   intt   server_portt   refresh_timet   floatR_   t   strR   R   (   R   R   t   parser(    (    s6   /usr/local/lib/python2.7/dist-packages/glances/main.pyt	   init_argsV   sV   		
 d k r� | j rt |  j
 q� |  j | _
 n  | j d k	 r� d �  t | j j d � d d d � | j | j
 f � D� \ | _ | _
 n  | j r� t j d � n  t r
t | _ n  | j rt | _ n  | j r�t | _ | j rR|  j d d	 � | _ q�| j rs|  j d d
 � | _ q�| j r�|  j d d � | _ q�n |  j | _ | j rc| j r�|  j d d j | j � d
   R   R   t   configR   t   loggingR~   R   t   setLevelRO   Rs   R^   t   web_server_portRx   RJ   t   zipt	   partitionRM   t   infoR   t   TrueRc   RQ   RR   RK   t   _GlancesMain__get_usernameR�   t   _GlancesMain__get_passwordRv   RZ   Rr   t   help_tagt   network_sumt
   startswitht   getattrRa   t
   export_tag(    (    s6   /usr/local/lib/python2.7/dist-packages/glances/main.pyR
   	  s�    		M																					
   get_config�  s    c         C   s   |  j  S(   s   Return the arguments.(   R   (   R   (    (    s6   /usr/local/lib/python2.7/dist-packages/glances/main.pyt   get_args�  s    c         C   s   |  j  S(   s   Return the mode.(   t   mode(   R   (    (    s6   /usr/local/lib/python2.7/dist-packages/glances/main.pyt   get_mode�  s    c         C   s
   t  | � S(   s0   Read an username from the command line.
        (   R   (   R   R�   (    (    s6   /usr/local/lib/python2.7/dist-packages/glances/main.pyt   __get_username�  s    c         C   s2   d d l  m } | d | � } | j | | | � S(   s�   Read a password from the command line.

        - if confirm = True, with confirmation
        - if clear = True, plain (clear password)
        i����(   t   GlancesPasswordR�   (   t   glances.passwordR�   t   get_password(   R   R�   R�   R�   R�   R�   RZ   (    (    s6   /usr/local/lib/python2.7/dist-packages/glances/main.pyt   __get_password�  s    (   t   __name__t
   __module__t   __doc__Ry   R_   Rr   t
   client_tagRx   R�   R�   RZ   Rp   R
   R�   R�   R�   R�   R�   R�   R�   R�   R�   R�   (    (    (    s6   /usr/local/lib/python2.7/dist-packages/glances/main.pyR   "   s,   		�	�								(   R�   Rm   R�   R�   Rt   R   R    R   t   glances.compatR   t   glances.configR   t   glances.globalsR   R   t   glances.loggerR   t   objectR   (    (    (    s6   /usr/local/lib/python2.7/dist-packages/glances/main.pyt   <module>   s                                                                                                                                                                                                                                                                                                                             ./usr/local/lib/python2.7/dist-packages/glances/stats_client.pyc                                    0000664 0000000 0000000 00000003500 13070471670 021673  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   s\   d  Z  d d l Z d d l m Z d d l m Z d d l m Z d e f d �  �  YZ d S(   s   The stats server manager.i����N(   t   GlancesStats(   t   sys_path(   t   loggert   GlancesStatsClientc           B   s/   e  Z d  Z d d d � Z d �  Z d �  Z RS(   s:   This class stores, updates and gives stats for the client.c         C   s5   t  t |  � j d | d | � | |  _ | |  _ d S(   s"   Init the GlancesStatsClient class.t   configt   argsN(   t   superR   t   __init__R   R   (   t   selfR   R   (    (    s>   /usr/local/lib/python2.7/dist-packages/glances/stats_client.pyR   !   s    	c         C   sf   d } xP | D]H } t  | | � } t j d j | � � | j d |  j � |  j | <q
   t
   __import__R   t   debugt   formatt   PluginR   t   _pluginsR   t   syst   path(   R   t
   __module__t   __doc__t   NoneR   R   R   (    (    (    s>   /usr/local/lib/python2.7/dist-packages/glances/stats_client.pyR      s   
	(	   R   R   t
                                                                                                                                                                                                   ./usr/local/lib/python2.7/dist-packages/glances/snmp.py                                             0000664 0000000 0000000 00000011345 13066703446 020023  0                                                                                                    ustar                                                                                                                                                                                                                                                          # -*- coding: utf-8 -*-
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

import sys

from glances.logger import logger

# Import mandatory PySNMP lib
try:
    from pysnmp.entity.rfc3413.oneliner import cmdgen
except ImportError:
    logger.critical("PySNMP library not found. To install it: pip install pysnmp")
    sys.exit(2)


class GlancesSNMPClient(object):

    """SNMP client class (based on pysnmp library)."""

    def __init__(self, host='localhost', port=161, version='2c',
                 community='public', user='private', auth=''):

        super(GlancesSNMPClient, self).__init__()
        self.cmdGen = cmdgen.CommandGenerator()

        self.version = version

        self.host = host
        self.port = port

        self.community = community
        self.user = user
        self.auth = auth

    def __buid_result(self, varBinds):
        """Build the results."""
        ret = {}
        for name, val in varBinds:
            if str(val) == '':
                ret[name.prettyPrint()] = ''
            else:
                ret[name.prettyPrint()] = val.prettyPrint()
                # In Python 3, prettyPrint() return 'b'linux'' instead of 'linux'
                if ret[name.prettyPrint()].startswith('b\''):
                    ret[name.prettyPrint()] = ret[name.prettyPrint()][2:-1]
        return ret

    def __get_result__(self, errorIndication, errorStatus, errorIndex, varBinds):
        """Put results in table."""
        ret = {}
        if not errorIndication or not errorStatus:
            ret = self.__buid_result(varBinds)
        return ret

    def get_by_oid(self, *oid):
        """SNMP simple request (list of OID).

        One request per OID list.

        * oid: oid list
        > Return a dict
        """
        if self.version == '3':
            errorIndication, errorStatus, errorIndex, varBinds = self.cmdGen.getCmd(
                cmdgen.UsmUserData(self.user, self.auth),
                cmdgen.UdpTransportTarget((self.host, self.port)),
                *oid
            )
        else:
            errorIndication, errorStatus, errorIndex, varBinds = self.cmdGen.getCmd(
                cmdgen.CommunityData(self.community),
                cmdgen.UdpTransportTarget((self.host, self.port)),
                *oid
            )
        return self.__get_result__(errorIndication, errorStatus, errorIndex, varBinds)

    def __bulk_result__(self, errorIndication, errorStatus, errorIndex, varBindTable):
        ret = []
        if not errorIndication or not errorStatus:
            for varBindTableRow in varBindTable:
                ret.append(self.__buid_result(varBindTableRow))
        return ret

    def getbulk_by_oid(self, non_repeaters, max_repetitions, *oid):
        """SNMP getbulk request.

        In contrast to snmpwalk, this information will typically be gathered in
        a single transaction with the agent, rather than one transaction per
        variable found.

        * non_repeaters: This specifies the number of supplied variables that
          should not be iterated over.
        * max_repetitions: This specifies the maximum number of iterations over
          the repeating variables.
        * oid: oid list
        > Return a list of dicts
        """
        if self.version.startswith('3'):
            errorIndication, errorStatus, errorIndex, varBinds = self.cmdGen.getCmd(
                cmdgen.UsmUserData(self.user, self.auth),
                cmdgen.UdpTransportTarget((self.host, self.port)),
                non_repeaters,
                max_repetitions,
                *oid
            )
        if self.version.startswith('2'):
            errorIndication, errorStatus, errorIndex, varBindTable = self.cmdGen.bulkCmd(
                cmdgen.CommunityData(self.community),
                cmdgen.UdpTransportTarget((self.host, self.port)),
                non_repeaters,
                max_repetitions,
                *oid
            )
        else:
            # Bulk request are not available with SNMP version 1
            return []
        return self.__bulk_result__(errorIndication, errorStatus, errorIndex, varBindTable)
                                                                                                                                                                                                                                                                                           ./usr/local/lib/python2.7/dist-packages/glances/logs.py                                             0000664 0000000 0000000 00000017356 13066703446 020022  0                                                                                                    ustar                                                                                                                                                                                                                                                          # -*- coding: utf-8 -*-
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""Manage logs."""

import time
from datetime import datetime

from glances.compat import range
from glances.processes import glances_processes, sort_stats


class GlancesLogs(object):

    """This class manages logs inside the Glances software.

    Logs is a list of list (stored in the self.logs_list var)
    item_state = "OK|CAREFUL|WARNING|CRITICAL"
    item_type = "CPU*|LOAD|MEM|MON"
    item_value = value

    Item is defined by:
      ["begin",
       "end",
       "WARNING|CRITICAL",
       "CPU|LOAD|MEM",
       MAX, AVG, MIN, SUM, COUNT,
       [top3 process list],
       "Processes description",
       "top sort key"]
    """

    def __init__(self):
        """Init the logs class."""
        # Maximum size of the logs list
        self.logs_max = 10

        # Init the logs list
        self.logs_list = []

    def get(self):
        """Return the raw logs list."""
        return self.logs_list

    def len(self):
        """Return the number of item in the logs list."""
        return self.logs_list.__len__()

    def __itemexist__(self, item_type):
        """Return the item position, if it exists.

        An item exist in the list if:
        * end is < 0
        * item_type is matching
        Return -1 if the item is not found.
        """
        for i in range(self.len()):
            if self.logs_list[i][1] < 0 and self.logs_list[i][3] == item_type:
                return i
        return -1

    def get_process_sort_key(self, item_type):
        """Return the process sort key"""
        # Process sort depending on alert type
        if item_type.startswith("MEM"):
            # Sort TOP process by memory_percent
            ret = 'memory_percent'
        elif item_type.startswith("CPU_IOWAIT"):
            # Sort TOP process by io_counters (only for Linux OS)
            ret = 'io_counters'
        else:
            # Default sort is...
            ret = 'cpu_percent'
        return ret

    def set_process_sort(self, item_type):
        """Define the process auto sort key from the alert type."""
        glances_processes.auto_sort = True
        glances_processes.sort_key = self.get_process_sort_key(item_type)

    def reset_process_sort(self):
        """Reset the process auto sort key."""
        # Default sort is...
        glances_processes.auto_sort = True
        glances_processes.sort_key = 'cpu_percent'

    def add(self, item_state, item_type, item_value,
            proc_list=None, proc_desc="", peak_time=6):
        """Add a new item to the logs list.

        If 'item' is a 'new one', add the new item at the beginning of
        the logs list.
        If 'item' is not a 'new one', update the existing item.
        If event < peak_time the the alert is not setoff.
        """
        proc_list = proc_list or glances_processes.getalllist()

        # Add or update the log
        item_index = self.__itemexist__(item_type)
        if item_index < 0:
            # Item did not exist, add if WARNING or CRITICAL
            self._create_item(item_state, item_type, item_value,
                              proc_list, proc_desc, peak_time)
        else:
            # Item exist, update
            self._update_item(item_index, item_state, item_type, item_value,
                              proc_list, proc_desc, peak_time)

        return self.len()

    def _create_item(self, item_state, item_type, item_value,
                     proc_list, proc_desc, peak_time):
        """Create a new item in the log list"""
        if item_state == "WARNING" or item_state == "CRITICAL":
            # Define the automatic process sort key
            self.set_process_sort(item_type)

            # Create the new log item
            # Time is stored in Epoch format
            # Epoch -> DMYHMS = datetime.fromtimestamp(epoch)
            item = [
                time.mktime(datetime.now().timetuple()),  # START DATE
                -1,  # END DATE
                item_state,  # STATE: WARNING|CRITICAL
                item_type,  # TYPE: CPU, LOAD, MEM...
                item_value,  # MAX
                item_value,  # AVG
                item_value,  # MIN
                item_value,  # SUM
                1,  # COUNT
                [],  # TOP 3 PROCESS LIST
                proc_desc,  # MONITORED PROCESSES DESC
                glances_processes.sort_key]  # TOP PROCESS SORTKEY

            # Add the item to the list
            self.logs_list.insert(0, item)
            if self.len() > self.logs_max:
                self.logs_list.pop()

            return True
        else:
            return False

    def _update_item(self, item_index, item_state, item_type, item_value,
                     proc_list, proc_desc, peak_time):
        """Update a item in the log list"""
        if item_state == "OK" or item_state == "CAREFUL":
            # Reset the automatic process sort key
            self.reset_process_sort()

            endtime = time.mktime(datetime.now().timetuple())
            if endtime - self.logs_list[item_index][0] > peak_time:
                # If event is > peak_time seconds
                self.logs_list[item_index][1] = endtime
            else:
                # If event <= peak_time seconds, ignore
                self.logs_list.remove(self.logs_list[item_index])
        else:
            # Update the item

            # State
            if item_state == "CRITICAL":
                self.logs_list[item_index][2] = item_state

            # Value
            if item_value > self.logs_list[item_index][4]:
                # MAX
                self.logs_list[item_index][4] = item_value
            elif item_value < self.logs_list[item_index][6]:
                # MIN
                self.logs_list[item_index][6] = item_value
            # AVG (compute average value)
            self.logs_list[item_index][7] += item_value
            self.logs_list[item_index][8] += 1
            self.logs_list[item_index][5] = (self.logs_list[item_index][7] /
                                             self.logs_list[item_index][8])

            # TOP PROCESS LIST (only for CRITICAL ALERT)
            if item_state == "CRITICAL":
                # Sort the current process list to retreive the TOP 3 processes
                self.logs_list[item_index][9] = sort_stats(proc_list, glances_processes.sort_key)[0:3]
                self.logs_list[item_index][11] = glances_processes.sort_key

            # MONITORED PROCESSES DESC
            self.logs_list[item_index][10] = proc_desc

        return True

    def clean(self, critical=False):
        """Clean the logs list by deleting finished items.

        By default, only delete WARNING message.
        If critical = True, also delete CRITICAL message.
        """
        # Create a new clean list
        clean_logs_list = []
        while self.len() > 0:
            item = self.logs_list.pop()
            if item[1] < 0 or (not critical and item[2].startswith("CRITICAL")):
                clean_logs_list.insert(0, item)
        # The list is now the clean one
        self.logs_list = clean_logs_list
        return self.len()


glances_logs = GlancesLogs()
                                                                                                                                                                                                                                                                                  ./usr/local/lib/python2.7/dist-packages/glances/amps_list.pyc                                       0000664 0000000 0000000 00000011510 13070471670 021172  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   s�   d  Z  d d l Z d d l Z d d l Z d d l m Z m Z d d l m Z d d l	 m
 Z
 d d l m Z d e
 d �  Z d	 �  Z d
 �  Z

    The AMP list is a list of processes with a specific monitoring action.

    The list (Python list) is composed of items (Python dict).
    An item is defined (dict keys):
    *...
    c         C   s    | |  _  | |  _ |  j �  d S(   s   Init the AMPs list.N(   t   argst   configt   load_configs(   t   selfR   R   (    (    s;   /usr/local/lib/python2.7/dist-packages/glances/amps_list.pyt   __init__.   s    		c         C   s�  |  j  d k r t Sd |  j  j �  k r8 t j d � n  d } xI|  j  j �  D]8} | j d � rN | d } t j j	 t
 | | d d � } t j j | � s� t j j	 t
 d � } n  y  t t j j
 r} t j d	 j t j j
 rI} t j d
 j t j j
   startswitht   ost   patht   joinR   t   existst
   __import__t   basenamet   ImportErrort   formatt	   Exceptiont   AmpR   t   _AmpsList__amps_dictt   load_configt   debugt   getListt   True(   R	   t   headert   st
   amp_scriptt   ampt   e(    (    s;   /usr/local/lib/python2.7/dist-packages/glances/amps_list.pyR   6   s*    
! ()"c         C   s
 r� q n Xt
 | � d k r� t j d j
   getalllistR   t   gett   enablet   ret   searcht   regexR   t	   TypeErrorR.   R   R    R   t	   threadingt   Threadt   update_wrappert   startt	   set_countt	   count_mint
   set_resultR   (   R	   t   processlistt   kt   vt   pt   ct	   amps_listt   thread(    (    s;   /usr/local/lib/python2.7/dist-packages/glances/amps_list.pyt   updatei   s     L
   __module__t   __doc__R   R
   R   R*   R+   R-   R/   RH   R!   R4   RJ   (    (    (    s;   /usr/local/lib/python2.7/dist-packages/glances/amps_list.pyR       s   			'							(   RM   R   R6   R:   t   glances.compatR    R   t   glances.loggerR   t   glances.globalsR   t   glances.processesR   t   objectR   (    (    (    s;   /usr/local/lib/python2.7/dist-packages/glances/amps_list.pyt   <module>   s                                                                                                                                                                                           ./usr/local/lib/python2.7/dist-packages/glances/stats.pyc                                           0000664 0000000 0000000 00000023216 13070471670 020343  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   s�   d  Z  d d l Z d d l Z d d l Z d d l Z d d l Z d d l m Z m Z m	 Z	 d d l
 m Z d e f d �  �  YZ
 e d � Z d	 �  Z
 � Z d �  Z d d � Z d

        The goal is to dynamically generate the following methods:
        - getPlugname(): return Plugname stat in JSON format
        t   gett	   get_statsN(   t
   startswitht   lent   lowert   _pluginst   hasattrt   getattrt   AttributeError(   R
   t   itemt   plugnamet   plugin(    (    s7   /usr/local/lib/python2.7/dist-packages/glances/stats.pyt   __getattr__4   s    
   t   collectionst   defaultdictt   dictR   t   load_pluginst   _exportst   load_exportsR   t   syst   path(   R
   R   (    (    s7   /usr/local/lib/python2.7/dist-packages/glances/stats.pyR   J   s
    c         C   s�   | t  |  j � d !j �  } y[ t | d  � } | d	 k r] | j d | d | � |  j | <n | j d | � |  j | <Wn? t k
 r� } t j d j	 | | � � t j
 t j �  � n Xd S(
   s=   Load the plugin (script), init it and add to the _plugin dicti����t   helpt   ampst   portsR   R   s+   Error while initializing the {} plugin ({})N(   s   helpR"   R#   (
   __import__t   PluginR   t	   ExceptionR   t   criticalt   formatt   errort	   tracebackt
   format_exc(   R
   t
 j d j |  j
   R   R   (    (    s7   /usr/local/lib/python2.7/dist-packages/glances/stats.pyR   p   s    c         C   s/  | d
 k r t Sd } t t �  d � } x� t j t � D]� } t j j | � t	 | � d !j
 �  } | j | � r9 | j d � r9 | | d k r9 | | d k r9 | d | d
 k	 r9 | d | t k	 r9 t
   history.pyt   export_R   s"   Available exports modules list: {}N(   t   Nonet   Falset   varst   localsR1   R2   R    R    R4   R   R   R   R3   R%   t   ExportR   R   R   R5   R)   t
   R   R$   t   args_varR   t   export_namet
        if enable is False, return the list of all the pluginsN(   R   t	   is_enable(   R
   t   enablet   p(    (    s7   /usr/local/lib/python2.7/dist-packages/glances/stats.pyR6   �   s    -c         C   s   g  |  j  D] } | ^ q
 S(   s    Return the exports modules list.(   R   (   R
   R/   (    (    s7   /usr/local/lib/python2.7/dist-packages/glances/stats.pyR=   �   s    c         C   s,   x% |  j  D] } |  j  | j | � q
 Wd S(   s;   Load the stats limits (except the one in the exclude list).N(   R   R	   (   R
   R   RD   (    (    s7   /usr/local/lib/python2.7/dist-packages/glances/stats.pyR	   �   s    c         C   sd   x] |  j  D]R } |  j  | j �  r) q
 n  |  j  | j �  |  j  | j �  |  j  | j �  q
 Wd S(   s#   Wrapper method to update the stats.N(   R   t
   is_disablet   updatet   update_stats_historyt   update_views(   R
   RD   (    (    s7   /usr/local/lib/python2.7/dist-packages/glances/stats.pyRF   �   s    c         C   sd   | p	 i  } xQ |  j  D]F } t j d | � t j d |  j  | j d | f � } | j �  q Wd S(   sX   Export all the stats.

        Each export module is ran in a dedicated thread.
        s    Export stats using the %s modulet   targetR   N(   R   R   R5   t	   threadingt   ThreadRF   t   start(   R
   t   input_statsR/   t   thread(    (    s7   /usr/local/lib/python2.7/dist-packages/glances/stats.pyt   export�   s    c         C   s'   g  |  j  D] } |  j  | j �  ^ q
 S(   s   Return all the stats (list).(   R   t   get_raw(   R
   RD   (    (    s7   /usr/local/lib/python2.7/dist-packages/glances/stats.pyt   getAll�   s    c            s   �  f d �  �  j  D� S(   s   Return all the stats (dict).c            s&   i  |  ] } �  j  | j �  | � q S(    (   R   RP   (   t   .0RD   (   R
   (    s7   /usr/local/lib/python2.7/dist-packages/glances/stats.pys
   <dictcomp>�   s   	 (   R   (   R
   (    (   R
   s7   /usr/local/lib/python2.7/dist-packages/glances/stats.pyt   getAllAsDict�   s    c         C   s'   g  |  j  D] } |  j  | j �  ^ q
 S(   so   
        Return all the stats to be exported (list).
        Default behavor is to export all the stat
        (   R   t
   get_export(   R
   RD   (    (    s7   /usr/local/lib/python2.7/dist-packages/glances/stats.pyt
        Return all the stats to be exported (list).
        Default behavor is to export all the stat
        if plugin_list is provided, only export stats of given plugin (list)
        c            s&   i  |  ] } �  j  | j �  | � q S(    (   R   RT   (   RR   RD   (   R
   (    s7   /usr/local/lib/python2.7/dist-packages/glances/stats.pys
   <dictcomp>�   s   	 N(   R8   R   (   R
   t   plugin_list(    (   R
   s7   /usr/local/lib/python2.7/dist-packages/glances/stats.pyt   getAllExportsAsDict�   s    c         C   s$   g  |  j  D] } |  j  | j ^ q
 S(   s   Return the plugins limits list.(   R   t   limits(   R
   RD   (    (    s7   /usr/local/lib/python2.7/dist-packages/glances/stats.pyt   getAllLimits�   s    c            s,   | d k r �  j } n  �  f d �  | D� S(   s�   
        Return all the stats limits (dict).
        Default behavor is to export all the limits
        if plugin_list is provided, only export limits of given plugin (list)
        c            s#   i  |  ] } �  j  | j | � q S(    (   R   RX   (   RR   RD   (   R
   (    s7   /usr/local/lib/python2.7/dist-packages/glances/stats.pys
   <dictcomp>�   s   	 N(   R8   R   (   R
   RV   (    (   R
   s7   /usr/local/lib/python2.7/dist-packages/glances/stats.pyt   getAllLimitsAsDict�   s    c         C   s'   g  |  j  D] } |  j  | j �  ^ q
 S(   s   Return the plugins views.(   R   t	   get_views(   R
   RD   (    (    s7   /usr/local/lib/python2.7/dist-packages/glances/stats.pyt   getAllViews�   s    c            s   �  f d �  �  j  D� S(   s"   Return all the stats views (dict).c            s&   i  |  ] } �  j  | j �  | � q S(    (   R   R[   (   RR   RD   (   R
   (    s7   /usr/local/lib/python2.7/dist-packages/glances/stats.pys
   <dictcomp>�   s   	 (   R   (   R
   (    (   R
   s7   /usr/local/lib/python2.7/dist-packages/glances/stats.pyt   getAllViewsAsDict�   s    c         C   s   |  j  S(   s   Return the plugin list.(   R   (   R
   (    (    s7   /usr/local/lib/python2.7/dist-packages/glances/stats.pyt   get_plugin_list�   s    c         C   s"   | |  j  k r |  j  | Sd Sd S(   s   Return the plugin name.N(   R   R8   (   R
   t   plugin_name(    (    s7   /usr/local/lib/python2.7/dist-packages/glances/stats.pyt
   get_plugin�   s    c         C   sN   x" |  j  D] } |  j  | j �  q
 Wx" |  j D] } |  j | j �  q/ Wd S(   s   End of the Glances stats.N(   R   t   exitR   (   R
   R/   RD   (    (    s7   /usr/local/lib/python2.7/dist-packages/glances/stats.pyt   end  s    N(   t   __name__t
   __module__t   __doc__R$   R8   R   R   R   R0   R   R   R>   R6   R=   R	   RF   RO   RQ   RS   RU   RW   RY   RZ   R\   R]   R^   R`   Rb   (    (    (    s7   /usr/local/lib/python2.7/dist-packages/glances/stats.pyR       s0   
&��Xc           @   s  d  Z  d d l Z d d l Z d d l Z d d l m Z d d l m Z d d l m	 Z	 m
 Z
 m Z d d l m
 e	 e f d �  �  YZ d e
 e f d
c         C   s   |  j  d d � d  S(   Ns   Access-Control-Allow-Origint   *(   t   send_header(   R
   /   s    c   
      C   s�   y% | j  d � j d � \ } } } Wn t k
 r@ |  j j SX| j  d � j d � \ } } } | d k sz t d � � | j �  } t | � } | j �  } | j d � \ } } }	 |  j	 | |	 � Sd  S(   Nt
   t   gett	   partitiont	   Exceptiont   servert   isAutht   AssertionErrort   encodeR    t   decodet
   check_user(
   R
    	c         C   s<   t  j |  � r8 |  j |  j � r% t S|  j d d � n  t S(   Ni�  s   Authentication failed(   R   t
   send_errorR+   (   R
    c         G   s   d  S(   N(    (   R
   log_formatt   args(    (    s8   /usr/local/lib/python2.7/dist-packages/glances/server.pyt   log_message^   s    (   s   /RPC2(
   t   __name__t
   __module__t   __doc__t	   rpc_pathsR   R
   R&   R   R-   R2   (    (    (    s8   /usr/local/lib/python2.7/dist-packages/glances/server.pyR	   #   s   						
t   GlancesXMLRPCServerc           B   s5   e  Z d  Z e Z d e d � Z d �  Z d �  Z RS(   s0   Init a SimpleXMLRPCServer instance (IPv6-ready).i�  c         C   s�   | |  _  | |  _ y! t j | | � d d |  _ Wn9 t j k
 rn } t j d j | � � t j	 d � n Xt
 t |  � j | | f | � d  S(   Ni    s   Couldn't open socket: {}i   (
c         C   s.   x' |  j  s) |  j �  t j |  j  � q Wd S(   s	   Main loopN(   RE   t   handle_requestR   t   info(   R
(	   R3   R4   R5   R+   RE   R	   RA   RF   RI   (    (    (    s8   /usr/local/lib/python2.7/dist-packages/glances/server.pyR7   c   s   	t   GlancesInstancec           B   s\   e  Z d  Z d	 d	 d � Z d �  Z d �  Z d �  Z d �  Z d �  Z	 d �  Z
 d �  Z RS(
   s?   All the methods of this class are published as XML-RPC methods.c         C   sD   t  d | d | � |  _ |  j j �  t d � |  _ | j |  _ d  S(   Nt   configR1   i    (   R   t   statst   updateR   t   timert   cached_time(   R
   __update__�   s    
c         C   s   t  j |  j j �  � S(   N(   RR   RS   RL   t
 rR t | � � qb Xn t | � � d S(   s�   Overwrite the getattr method in case of attribute is not found.

        The goal is to dynamically generate the API get'Stats'() methods.
        R   N(   t
   startswithRP   t   getattrRL   R   t   AttributeError(   R

 r` } t j d j | � � t	 j
 d � n Xd j | j | j � GHi  |  j _ t |  j _
# -*- coding: utf-8 -*-
#
# Glances - An eye on your system
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""Allow user to run Glances as a module."""

# Execute with:
# $ python -m glances (2.7+)

import glances

if __name__ == '__main__':
    glances.main()
                                                                                     ./usr/local/lib/python2.7/dist-packages/glances/processes.py                                        0000664 0000000 0000000 00000053220 13066703446 021052  0                                                                                                    ustar                                                                                                                                                                                                                                                          # -*- coding: utf-8 -*-
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

import operator
import os

from glances.compat import iteritems, itervalues, listitems
from glances.globals import BSD, LINUX, MACOS, WINDOWS
from glances.timer import Timer, getTimeSinceLastUpdate
from glances.processes_tree import ProcessTreeNode
from glances.filter import GlancesFilter
from glances.logger import logger

import psutil


def is_kernel_thread(proc):
    """Return True if proc is a kernel thread, False instead."""
    try:
        return os.getpgid(proc.pid) == 0
    # Python >= 3.3 raises ProcessLookupError, which inherits OSError
    except OSError:
        # return False is process is dead
        return False


class GlancesProcesses(object):

    """Get processed stats using the psutil library."""

    def __init__(self, cache_timeout=60):
        """Init the class to collect stats about processes."""
        # Add internals caches because PSUtil do not cache all the stats
        # See: https://code.google.com/p/psutil/issues/detail?id=462
        self.username_cache = {}
        self.cmdline_cache = {}

        # The internals caches will be cleaned each 'cache_timeout' seconds
        self.cache_timeout = cache_timeout
        self.cache_timer = Timer(self.cache_timeout)

        # Init the io dict
        # key = pid
        # value = [ read_bytes_old, write_bytes_old ]
        self.io_old = {}

        # Wether or not to enable process tree
        self._enable_tree = False
        self.process_tree = None

        # Init stats
        self.auto_sort = True
        self._sort_key = 'cpu_percent'
        self.allprocesslist = []
        self.processlist = []
        self.reset_processcount()

        # Tag to enable/disable the processes stats (to reduce the Glances CPU consumption)
        # Default is to enable the processes stats
        self.disable_tag = False

        # Extended stats for top process is enable by default
        self.disable_extended_tag = False

        # Maximum number of processes showed in the UI (None if no limit)
        self._max_processes = None

        # Process filter is a regular expression
        self._filter = GlancesFilter()

        # Whether or not to hide kernel threads
        self.no_kernel_threads = False

        # Store maximums values in a dict
        # Used in the UI to highlight the maximum value
        self._max_values_list = ('cpu_percent', 'memory_percent')
        # { 'cpu_percent': 0.0, 'memory_percent': 0.0 }
        self._max_values = {}
        self.reset_max_values()

    def reset_processcount(self):
        self.processcount = {'total': 0,
                             'running': 0,
                             'sleeping': 0,
                             'thread': 0,
                             'pid_max': None}

    def enable(self):
        """Enable process stats."""
        self.disable_tag = False
        self.update()

    def disable(self):
        """Disable process stats."""
        self.disable_tag = True

    def enable_extended(self):
        """Enable extended process stats."""
        self.disable_extended_tag = False
        self.update()

    def disable_extended(self):
        """Disable extended process stats."""
        self.disable_extended_tag = True

    @property
    def pid_max(self):
        """
        Get the maximum PID value.

        On Linux, the value is read from the `/proc/sys/kernel/pid_max` file.

        From `man 5 proc`:
        The default value for this file, 32768, results in the same range of
        PIDs as on earlier kernels. On 32-bit platfroms, 32768 is the maximum
        value for pid_max. On 64-bit systems, pid_max can be set to any value
        up to 2^22 (PID_MAX_LIMIT, approximately 4 million).

        If the file is unreadable or not available for whatever reason,
        returns None.

        Some other OSes:
        - On FreeBSD and macOS the maximum is 99999.
        - On OpenBSD >= 6.0 the maximum is 99999 (was 32766).
        - On NetBSD the maximum is 30000.

        :returns: int or None
        """
        if LINUX:
            # XXX: waiting for https://github.com/giampaolo/psutil/issues/720
            try:
                with open('/proc/sys/kernel/pid_max', 'rb') as f:
                    return int(f.read())
            except (OSError, IOError):
                return None

    @property
    def max_processes(self):
        """Get the maximum number of processes showed in the UI."""
        return self._max_processes

    @max_processes.setter
    def max_processes(self, value):
        """Set the maximum number of processes showed in the UI."""
        self._max_processes = value

    @property
    def process_filter_input(self):
        """Get the process filter (given by the user)."""
        return self._filter.filter_input

    @property
    def process_filter(self):
        """Get the process filter (current apply filter)."""
        return self._filter.filter

    @process_filter.setter
    def process_filter(self, value):
        """Set the process filter."""
        self._filter.filter = value

    @property
    def process_filter_key(self):
        """Get the process filter key."""
        return self._filter.filter_key

    @property
    def process_filter_re(self):
        """Get the process regular expression compiled."""
        return self._filter.filter_re

    def disable_kernel_threads(self):
        """Ignore kernel threads in process list."""
        self.no_kernel_threads = True

    def enable_tree(self):
        """Enable process tree."""
        self._enable_tree = True

    def is_tree_enabled(self):
        """Return True if process tree is enabled, False instead."""
        return self._enable_tree

    @property
    def sort_reverse(self):
        """Return True to sort processes in reverse 'key' order, False instead."""
        if self.sort_key == 'name' or self.sort_key == 'username':
            return False

        return True

    def max_values(self):
        """Return the max values dict."""
        return self._max_values

    def get_max_values(self, key):
        """Get the maximum values of the given stat (key)."""
        return self._max_values[key]

    def set_max_values(self, key, value):
        """Set the maximum value for a specific stat (key)."""
        self._max_values[key] = value

    def reset_max_values(self):
        """Reset the maximum values dict."""
        self._max_values = {}
        for k in self._max_values_list:
            self._max_values[k] = 0.0

    def __get_mandatory_stats(self, proc, procstat):
        """
        Get mandatory_stats: for all processes.
        Needed for the sorting/filter step.

        Stats grabbed inside this method:
        * 'name', 'cpu_times', 'status', 'ppid'
        * 'username', 'cpu_percent', 'memory_percent'
        """
        procstat['mandatory_stats'] = True

        # Name, cpu_times, status and ppid stats are in the same /proc file
        # Optimisation fir issue #958
        try:
            procstat.update(proc.as_dict(
                attrs=['name', 'cpu_times', 'status', 'ppid'],
                ad_value=''))
        except psutil.NoSuchProcess:
            # Try/catch for issue #432 (process no longer exist)
            return None
        else:
            procstat['status'] = str(procstat['status'])[:1].upper()

        try:
            procstat.update(proc.as_dict(
                attrs=['username', 'cpu_percent', 'memory_percent'],
                ad_value=''))
        except psutil.NoSuchProcess:
            # Try/catch for issue #432 (process no longer exist)
            return None

        if procstat['cpu_percent'] == '' or procstat['memory_percent'] == '':
            # Do not display process if we cannot get the basic
            # cpu_percent or memory_percent stats
            return None

        # Compute the maximum value for cpu_percent and memory_percent
        for k in self._max_values_list:
            if procstat[k] > self.get_max_values(k):
                self.set_max_values(k, procstat[k])

        # Process command line (cached with internal cache)
        if procstat['pid'] not in self.cmdline_cache:
            # Patch for issue #391
            try:
                self.cmdline_cache[procstat['pid']] = proc.cmdline()
            except (AttributeError, EnvironmentError, UnicodeDecodeError,
                    psutil.AccessDenied, psutil.NoSuchProcess):
                self.cmdline_cache[procstat['pid']] = ""
        procstat['cmdline'] = self.cmdline_cache[procstat['pid']]

        # Process IO
        # procstat['io_counters'] is a list:
        # [read_bytes, write_bytes, read_bytes_old, write_bytes_old, io_tag]
        # If io_tag = 0 > Access denied (display "?")
        # If io_tag = 1 > No access denied (display the IO rate)
        # Availability: all platforms except macOS and Illumos/Solaris
        try:
            # Get the process IO counters
            proc_io = proc.io_counters()
            io_new = [proc_io.read_bytes, proc_io.write_bytes]
        except (psutil.AccessDenied, psutil.NoSuchProcess, NotImplementedError):
            # Access denied to process IO (no root account)
            # NoSuchProcess (process die between first and second grab)
            # Put 0 in all values (for sort) and io_tag = 0 (for display)
            procstat['io_counters'] = [0, 0] + [0, 0]
            io_tag = 0
        except AttributeError:
            return procstat
        else:
            # For IO rate computation
            # Append saved IO r/w bytes
            try:
                procstat['io_counters'] = io_new + self.io_old[procstat['pid']]
            except KeyError:
                procstat['io_counters'] = io_new + [0, 0]
            # then save the IO r/w bytes
            self.io_old[procstat['pid']] = io_new
            io_tag = 1

        # Append the IO tag (for display)
        procstat['io_counters'] += [io_tag]

        return procstat

    def __get_standard_stats(self, proc, procstat):
        """
        Get standard_stats: only for displayed processes.

        Stats grabbed inside this method:
        * nice and memory_info
        """
        procstat['standard_stats'] = True

        # Process nice and memory_info (issue #926)
        try:
            procstat.update(
                proc.as_dict(attrs=['nice', 'memory_info']))
        except psutil.NoSuchProcess:
            pass

        return procstat

    def __get_extended_stats(self, proc, procstat):
        """
        Get extended stats, only for top processes (see issue #403).

        - cpu_affinity (Linux, Windows, FreeBSD)
        - ionice (Linux and Windows > Vista)
        - memory_full_info (Linux)
        - num_ctx_switches (not available on Illumos/Solaris)
        - num_fds (Unix-like)
        - num_handles (Windows)
        - num_threads (not available on *BSD)
        - memory_maps (only swap, Linux)
          https://www.cyberciti.biz/faq/linux-which-process-is-using-swap/
        - connections (TCP and UDP)
        """
        procstat['extended_stats'] = True

        for stat in ['cpu_affinity', 'ionice', 'memory_full_info',
                     'num_ctx_switches', 'num_fds', 'num_handles',
                     'num_threads']:
            try:
                procstat.update(proc.as_dict(attrs=[stat]))
            except psutil.NoSuchProcess:
                pass
            # XXX: psutil>=4.3.1 raises ValueError while <4.3.1 raises AttributeError
            except (ValueError, AttributeError):
                procstat[stat] = None

        if LINUX:
            try:
                procstat['memory_swap'] = sum([v.swap for v in proc.memory_maps()])
            except psutil.NoSuchProcess:
                pass
            except (psutil.AccessDenied, TypeError, NotImplementedError):
                # NotImplementedError: /proc/${PID}/smaps file doesn't exist
                # on kernel < 2.6.14 or CONFIG_MMU kernel configuration option
                # is not enabled (see psutil #533/glances #413).
                # XXX: Remove TypeError once we'll drop psutil < 3.0.0.
                procstat['memory_swap'] = None

        try:
            procstat['tcp'] = len(proc.connections(kind="tcp"))
            procstat['udp'] = len(proc.connections(kind="udp"))
        except psutil.AccessDenied:
            procstat['tcp'] = None
            procstat['udp'] = None

        return procstat

    def __get_process_stats(self, proc,
                            mandatory_stats=True,
                            standard_stats=True,
                            extended_stats=False):
        """Get stats of a running processes."""
        # Process ID (always)
        procstat = proc.as_dict(attrs=['pid'])

        if mandatory_stats:
            procstat = self.__get_mandatory_stats(proc, procstat)

        if procstat is not None and standard_stats:
            procstat = self.__get_standard_stats(proc, procstat)

        if procstat is not None and extended_stats and not self.disable_extended_tag:
            procstat = self.__get_extended_stats(proc, procstat)

        return procstat

    def update(self):
        """Update the processes stats."""
        # Reset the stats
        self.processlist = []
        self.reset_processcount()

        # Do not process if disable tag is set
        if self.disable_tag:
            return

        # Get the time since last update
        time_since_update = getTimeSinceLastUpdate('process_disk')

        # Reset the max dict
        self.reset_max_values()

        # Update the maximum process ID (pid) number
        self.processcount['pid_max'] = self.pid_max

        # Build an internal dict with only mandatories stats (sort keys)
        processdict = {}
        excluded_processes = set()
        for proc in psutil.process_iter():
            # Ignore kernel threads if needed
            if self.no_kernel_threads and not WINDOWS and is_kernel_thread(proc):
                continue

            # If self.max_processes is None: Only retrieve mandatory stats
            # Else: retrieve mandatory and standard stats
            s = self.__get_process_stats(proc,
                                         mandatory_stats=True,
                                         standard_stats=self.max_processes is None)
            # Check if s is note None (issue #879)
            # ignore the 'idle' process on Windows and *BSD
            # ignore the 'kernel_task' process on macOS
            # waiting for upstream patch from psutil
            if (s is None or
                    BSD and s['name'] == 'idle' or
                    WINDOWS and s['name'] == 'System Idle Process' or
                    MACOS and s['name'] == 'kernel_task'):
                continue
            # Continue to the next process if it has to be filtered
            if self._filter.is_filtered(s):
                excluded_processes.add(proc)
                continue

            # Ok add the process to the list
            processdict[proc] = s
            # Update processcount (global statistics)
            try:
                self.processcount[str(proc.status())] += 1
            except KeyError:
                # Key did not exist, create it
                try:
                    self.processcount[str(proc.status())] = 1
                except psutil.NoSuchProcess:
                    pass
            except psutil.NoSuchProcess:
                pass
            else:
                self.processcount['total'] += 1
            # Update thread number (global statistics)
            try:
                self.processcount['thread'] += proc.num_threads()
            except Exception:
                pass

        if self._enable_tree:
            self.process_tree = ProcessTreeNode.build_tree(processdict,
                                                           self.sort_key,
                                                           self.sort_reverse,
                                                           self.no_kernel_threads,
                                                           excluded_processes)

            for i, node in enumerate(self.process_tree):
                # Only retreive stats for visible processes (max_processes)
                if self.max_processes is not None and i >= self.max_processes:
                    break

                # add standard stats
                new_stats = self.__get_process_stats(node.process,
                                                     mandatory_stats=False,
                                                     standard_stats=True,
                                                     extended_stats=False)
                if new_stats is not None:
                    node.stats.update(new_stats)

                # Add a specific time_since_update stats for bitrate
                node.stats['time_since_update'] = time_since_update

        else:
            # Process optimization
            # Only retreive stats for visible processes (max_processes)
            if self.max_processes is not None:
                # Sort the internal dict and cut the top N (Return a list of tuple)
                # tuple=key (proc), dict (returned by __get_process_stats)
                try:
                    processiter = sorted(iteritems(processdict),
                                         key=lambda x: x[1][self.sort_key],
                                         reverse=self.sort_reverse)
                except (KeyError, TypeError) as e:
                    logger.error("Cannot sort process list by {}: {}".format(self.sort_key, e))
                    logger.error('{}'.format(listitems(processdict)[0]))
                    # Fallback to all process (issue #423)
                    processloop = iteritems(processdict)
                    first = False
                else:
                    processloop = processiter[0:self.max_processes]
                    first = True
            else:
                # Get all processes stats
                processloop = iteritems(processdict)
                first = False

            for i in processloop:
                # Already existing mandatory stats
                procstat = i[1]
                if self.max_processes is not None:
                    # Update with standard stats
                    # and extended stats but only for TOP (first) process
                    s = self.__get_process_stats(i[0],
                                                 mandatory_stats=False,
                                                 standard_stats=True,
                                                 extended_stats=first)
                    if s is None:
                        continue
                    procstat.update(s)
                # Add a specific time_since_update stats for bitrate
                procstat['time_since_update'] = time_since_update
                # Update process list
                self.processlist.append(procstat)
                # Next...
                first = False

        # Build the all processes list used by the AMPs
        self.allprocesslist = [p for p in itervalues(processdict)]

        # Clean internals caches if timeout is reached
        if self.cache_timer.finished():
            self.username_cache = {}
            self.cmdline_cache = {}
            # Restart the timer
            self.cache_timer.reset()

    def getcount(self):
        """Get the number of processes."""
        return self.processcount

    def getalllist(self):
        """Get the allprocesslist."""
        return self.allprocesslist

    def getlist(self, sortedby=None):
        """Get the processlist."""
        return self.processlist

    def gettree(self):
        """Get the process tree."""
        return self.process_tree

    @property
    def sort_key(self):
        """Get the current sort key."""
        return self._sort_key

    @sort_key.setter
    def sort_key(self, key):
        """Set the current sort key."""
        self._sort_key = key


# TODO: move this global function (also used in glances_processlist
#       and logs) inside the GlancesProcesses class
def sort_stats(stats, sortedby=None, tree=False, reverse=True):
    """Return the stats (dict) sorted by (sortedby)
    Reverse the sort if reverse is True."""
    if sortedby is None:
        # No need to sort...
        return stats

    if sortedby == 'io_counters' and not tree:
        # Specific case for io_counters
        # Sum of io_r + io_w
        try:
            # Sort process by IO rate (sum IO read + IO write)
            stats.sort(key=lambda process: process[sortedby][0] -
                       process[sortedby][2] + process[sortedby][1] -
                       process[sortedby][3],
                       reverse=reverse)
        except Exception:
            stats.sort(key=operator.itemgetter('cpu_percent'),
                       reverse=reverse)
    else:
        # Others sorts
        if tree:
            stats.set_sorting(sortedby, reverse)
        else:
            try:
                stats.sort(key=operator.itemgetter(sortedby),
                           reverse=reverse)
            except (KeyError, TypeError):
                stats.sort(key=operator.itemgetter('name'),
                           reverse=False)

    return stats


glances_processes = GlancesProcesses()
                                                                                                                                                                                                                                                                                                                                                                                ./usr/local/lib/python2.7/dist-packages/glances/exports/                                            0000775 0000000 0000000 00000000000 13070471670 020170  5                                                                                                    ustar                                                                                                                                                                                                                                                          ./usr/local/lib/python2.7/dist-packages/glances/exports/glances_statsd.py                           0000664 0000000 0000000 00000005465 13066703446 023556  0                                                                                                    ustar                                                                                                                                                                                                                                                          # -*- coding: utf-8 -*-
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""Statsd interface class."""

import sys
from numbers import Number

from glances.compat import range
from glances.logger import logger
from glances.exports.glances_export import GlancesExport

from statsd import StatsClient


class Export(GlancesExport):

    """This class manages the Statsd export module."""

    def __init__(self, config=None, args=None):
        """Init the Statsd export IF."""
        super(Export, self).__init__(config=config, args=args)

        # Mandatories configuration keys (additional to host and port)
        # N/A

        # Optionals configuration keys
        self.prefix = None

        # Load the InfluxDB configuration file
        self.export_enable = self.load_conf('statsd',
                                            mandatories=['host', 'port'],
                                            options=['prefix'])
        if not self.export_enable:
            sys.exit(2)

        # Default prefix for stats is 'glances'
        if self.prefix is None:
            self.prefix = 'glances'

        # Init the Statsd client
        self.client = self.init()

    def init(self, prefix='glances'):
        """Init the connection to the Statsd server."""
        if not self.export_enable:
            return None
        logger.info(
            "Stats will be exported to StatsD server: {}:{}".format(self.host,
                                                                    self.port))
        return StatsClient(self.host,
                           int(self.port),
                           prefix=prefix)

    def export(self, name, columns, points):
        """Export the stats to the Statsd server."""
        for i in range(len(columns)):
            if not isinstance(points[i], Number):
                continue
            stat_name = '{}.{}'.format(name, columns[i])
            stat_value = points[i]
            try:
                self.client.gauge(stat_name, stat_value)
            except Exception as e:
                logger.error("Can not export stats to Statsd (%s)" % e)
        logger.debug("Export {} stats to Statsd".format(name))
                                                                                                                                                                                                           ./usr/local/lib/python2.7/dist-packages/glances/exports/glances_couchdb.pyc                         0000664 0000000 0000000 00000006015 13070471670 024012  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   st   d  Z  d d l Z d d l m Z d d l m Z d d l m Z d d l Z d d l Z d e f d �  �  YZ	 d S(   s   CouchDB interface class.i����N(   t   datetime(   t   logger(   t
 g �|  _ |  j s� t	 j
 d � n  |  j �  |  _ d S(
   R   R
 r� } t
 j d | | f � t j
 j d | � y | |  j Wn# t	 k
 r� } | j |  j � n Xt
 j d |  j � | S(   s*   Init the connection to the CouchDB server.s
   t   create(   R   t
   server_urit   st   e(    (    sI   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_couchdb.pyR   9   s*    	c         C   s   |  j  |  j S(   s"   Return the CouchDB database object(   R   R
   (   R   (    (    sI   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_couchdb.pyt   databaseZ   s    c         C   s�   t  j d j | � � t t | | � � } | | d <t j j �  j t	 j
 �  � | d <y |  j |  j j
 r� } t  j d j | | � � n Xd S(   s'   Write the points to the CouchDB server.s   Export {} stats to CouchDBt   typet   times&   Cannot export {} stats to CouchDB ({})N(   R   t   debugR   t   dictt   zipR   t   mappingt
   t   saveR   t   error(   R   t   namet   columnst   pointst   dataR    (    (    sI   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_couchdb.pyt   export^   s    
"N(   t   __name__t
   __module__t   __doc__R   R   R   R!   R1   (    (    (    sI   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_couchdb.pyR       s
   	!	(
   R4   R   R    t   glances.loggerR   t   glances.exports.glances_exportR   R   t   couchdb.mappingR   (    (    (    sI   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_couchdb.pyt   <module>   s                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      ./usr/local/lib/python2.7/dist-packages/glances/exports/graph.py                                    0000664 0000000 0000000 00000015725 13066703446 021661  0                                                                                                    ustar                                                                                                                                                                                                                                                          # -*- coding: utf-8 -*-
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""Graph generation class."""

import os

from glances.compat import iterkeys
from glances.logger import logger

try:
    from matplotlib import __version__ as matplotlib_version
    import matplotlib.pyplot as plt
except ImportError:
    matplotlib_check = False
    logger.warning('Cannot load Matplotlib library. Please install it using "pip install matplotlib"')
else:
    matplotlib_check = True
    logger.info('Load Matplotlib version %s' % matplotlib_version)


class GlancesGraph(object):

    """Thanks to this class, Glances can export history to graphs."""

    def __init__(self, output_folder):
        self.output_folder = output_folder

    def get_output_folder(self):
        """Return the output folder where the graph are generated."""
        return self.output_folder

    def graph_enabled(self):
        """Return True if Glances can generate history graphs."""
        return matplotlib_check

    def reset(self, stats):
        """Reset all the history."""
        if not self.graph_enabled():
            return False
        for p in stats.getAllPlugins():
            h = stats.get_plugin(p).get_stats_history()
            if h is not None:
                stats.get_plugin(p).reset_stats_history()
        return True

    def get_graph_color(self, item):
        """Get the item's color."""
        try:
            ret = item['color']
        except KeyError:
            return '#FFFFFF'
        else:
            return ret

    def get_graph_legend(self, item):
        """Get the item's legend."""
        return item['description']

    def get_graph_yunit(self, item, pre_label=''):
        """Get the item's Y unit."""
        try:
            unit = " (%s)" % item['y_unit']
        except KeyError:
            unit = ''
        if pre_label == '':
            label = ''
        else:
            label = pre_label.split('_')[0]
        return "%s%s" % (label, unit)

    def generate_graph(self, stats):
        """Generate graphs from plugins history.

        Return the number of output files generated by the function.
        """
        if not self.graph_enabled():
            return 0

        index_all = 0
        for p in stats.getAllPlugins():
            # History
            h = stats.get_plugin(p).get_export_history()
            # Current plugin item history list
            ih = stats.get_plugin(p).get_items_history_list()
            # Check if we must process history
            if h is None or ih is None:
                # History (h) not available for plugin (p)
                continue
            # Init graph
            plt.clf()
            index_graph = 0
            handles = []
            labels = []
            for i in ih:
                if i['name'] in iterkeys(h):
                    # The key exist
                    # Add the curves in the current chart
                    logger.debug("Generate graph: %s %s" % (p, i['name']))
                    index_graph += 1
                    # Labels
                    handles.append(plt.Rectangle((0, 0), 1, 1, fc=self.get_graph_color(i), ec=self.get_graph_color(i), linewidth=2))
                    labels.append(self.get_graph_legend(i))
                    # Legend
                    plt.ylabel(self.get_graph_yunit(i, pre_label=''))
                    # Curves
                    plt.grid(True)
                    # Points are stored as tuple (date, value)
                    x, y = zip(*h[i['name']])
                    plt.plot_date(x, y,
                                  fmt='', drawstyle='default', linestyle='-',
                                  color=self.get_graph_color(i),
                                  xdate=True, ydate=False)
                    if index_graph == 1:
                        # Title only on top of the first graph
                        plt.title(p.capitalize())
                else:
                    # The key did not exist
                    # Find if anothers key ends with the key
                    # Ex: key='tx' => 'ethernet_tx'
                    # Add one curve per chart
                    stats_history_filtered = sorted([key for key in iterkeys(h) if key.endswith('_' + i['name'])])
                    logger.debug("Generate graphs: %s %s" %
                                 (p, stats_history_filtered))
                    if len(stats_history_filtered) > 0:
                        # Create 'n' graph
                        # Each graph iter through the stats
                        plt.clf()
                        index_item = 0
                        for k in stats_history_filtered:
                            index_item += 1
                            plt.subplot(
                                len(stats_history_filtered), 1, index_item)
                            # Legend
                            plt.ylabel(self.get_graph_yunit(i, pre_label=k))
                            # Curves
                            plt.grid(True)
                            # Points are stored as tuple (date, value)
                            x, y = zip(*h[k])
                            plt.plot_date(x, y,
                                          fmt='', drawstyle='default', linestyle='-',
                                          color=self.get_graph_color(i),
                                          xdate=True, ydate=False)
                            if index_item == 1:
                                # Title only on top of the first graph
                                plt.title(p.capitalize() + ' ' + i['name'])
                        # Save the graph to output file
                        fig = plt.gcf()
                        fig.set_size_inches(20, 5 * index_item)
                        plt.xlabel('Date')
                        plt.savefig(
                            os.path.join(self.output_folder, 'glances_%s_%s.png' % (p, i['name'])), dpi=72)
                        index_all += 1

            if index_graph > 0:
                # Save the graph to output file
                fig = plt.gcf()
                fig.set_size_inches(20, 10)
                plt.legend(handles, labels, loc=1, prop={'size': 9})
                plt.xlabel('Date')
                plt.savefig(os.path.join(self.output_folder, 'glances_%s.png' % p), dpi=72)
                index_all += 1

            plt.close()

        return index_all
                                           ./usr/local/lib/python2.7/dist-packages/glances/exports/glances_zeromq.py                           0000664 0000000 0000000 00000007002 13066703446 023556  0                                                                                                    ustar                                                                                                                                                                                                                                                          # -*- coding: utf-8 -*-
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""ZeroMQ interface class."""

import sys
import json

from glances.compat import b
from glances.logger import logger
from glances.exports.glances_export import GlancesExport

import zmq
from zmq.utils.strtypes import asbytes


class Export(GlancesExport):

    """This class manages the ZeroMQ export module."""

    def __init__(self, config=None, args=None):
        """Init the ZeroMQ export IF."""
        super(Export, self).__init__(config=config, args=args)

        # Mandatories configuration keys (additional to host and port)
        self.prefix = None

        # Optionals configuration keys
        # N/A

        # Load the ZeroMQ configuration file section ([export_zeromq])
        self.export_enable = self.load_conf('zeromq',
                                            mandatories=['host', 'port', 'prefix'],
                                            options=[])
        if not self.export_enable:
            sys.exit(2)

        # Init the ZeroMQ context
        self.context = None
        self.client = self.init()

    def init(self):
        """Init the connection to the CouchDB server."""
        if not self.export_enable:
            return None

        server_uri = 'tcp://{}:{}'.format(self.host, self.port)

        try:
            self.context = zmq.Context()
            publisher = self.context.socket(zmq.PUB)
            publisher.bind(server_uri)
        except Exception as e:
            logger.critical("Cannot connect to ZeroMQ server %s (%s)" % (server_uri, e))
            sys.exit(2)
        else:
            logger.info("Connected to the ZeroMQ server %s" % server_uri)

        return publisher

    def exit(self):
        """Close the socket and context"""
        if self.client is not None:
            self.client.close()
        if self.context is not None:
            self.context.destroy()

    def export(self, name, columns, points):
        """Write the points to the ZeroMQ server."""
        logger.debug("Export {} stats to ZeroMQ".format(name))

        # Create DB input
        data = dict(zip(columns, points))

        # Do not publish empty stats
        if data == {}:
            return False

        # Glances envelopes the stats in a publish message with two frames:
        # - First frame containing the following prefix (STRING)
        # - Second frame with the Glances plugin name (STRING)
        # - Third frame with the Glances plugin stats (JSON)
        message = [b(self.prefix),
                   b(name),
                   asbytes(json.dumps(data))]

        # Write data to the ZeroMQ bus
        # Result can be view: tcp://host:port
        try:
            self.client.send_multipart(message)
        except Exception as e:
            logger.error("Cannot export {} stats to ZeroMQ ({})".format(name, e))

        return True
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              ./usr/local/lib/python2.7/dist-packages/glances/exports/glances_export.py                           0000664 0000000 0000000 00000015564 13066703446 023576  0                                                                                                    ustar                                                                                                                                                                                                                                                          # -*- coding: utf-8 -*-
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""
I am your father...

...for all Glances exports IF.
"""

from glances.compat import NoOptionError, NoSectionError, iteritems, iterkeys
from glances.logger import logger


class GlancesExport(object):

    """Main class for Glances export IF."""

    def __init__(self, config=None, args=None):
        """Init the export class."""
        # Export name (= module name without glances_)
        self.export_name = self.__class__.__module__[len('glances_'):]
        logger.debug("Init export module %s" % self.export_name)

        # Init the config & args
        self.config = config
        self.args = args

        # By default export is disable
        # Had to be set to True in the __init__ class of child
        self.export_enable = False

        # Mandatory for (most of) the export module
        self.host = None
        self.port = None

    def exit(self):
        """Close the export module."""
        logger.debug("Finalise export interface %s" % self.export_name)

    def plugins_to_export(self):
        """Return the list of plugins to export."""
        return ['cpu',
                'percpu',
                'load',
                'mem',
                'memswap',
                'network',
                'diskio',
                'fs',
                'processcount',
                'ip',
                'system',
                'uptime',
                'sensors',
                'docker',
                'uptime']

    def load_conf(self, section, mandatories=['host', 'port'], options=None):
        """Load the export <section> configuration in the Glances configuration file.

        :param section: name of the export section to load
        :param mandatories: a list of mandatories parameters to load
        :param options: a list of optionnals parameters to load

        :returns: Boolean -- True if section is found
        """
        options = options or []

        if self.config is None:
            return False

        # By default read the mandatory host:port items
        try:
            for opt in mandatories:
                setattr(self, opt, self.config.get_value(section, opt))
        except NoSectionError:
            logger.critical("No {} configuration found".format(section))
            return False
        except NoOptionError as e:
            logger.critical("Error in the {} configuration ({})".format(section, e))
            return False

        # Load options
        for opt in options:
            try:
                setattr(self, opt, self.config.get_value(section, opt))
            except NoOptionError:
                pass

        logger.debug("Load {} from the Glances configuration file".format(section))
        logger.debug("{} parameters: {}".format(section, {opt: getattr(self, opt) for opt in mandatories + options}))

        return True

    def get_item_key(self, item):
        """Return the value of the item 'key'."""
        try:
            ret = item[item['key']]
        except KeyError:
            logger.error("No 'key' available in {}".format(item))
        if isinstance(ret, list):
            return ret[0]
        else:
            return ret

    def parse_tags(self, tags):
        """Parse tags into a dict.

        tags: a comma separated list of 'key:value' pairs.
            Example: foo:bar,spam:eggs
        dtags: a dict of tags.
            Example: {'foo': 'bar', 'spam': 'eggs'}
        """
        dtags = {}
        if tags:
            try:
                dtags = dict([x.split(':') for x in tags.split(',')])
            except ValueError:
                # one of the 'key:value' pairs was missing
                logger.info('Invalid tags passed: %s', tags)
                dtags = {}

        return dtags

    def update(self, stats):
        """Update stats to a server.

        The method builds two lists: names and values
        and calls the export method to export the stats.

        Be aware that CSV export overwrite this class and use a specific one.
        """
        if not self.export_enable:
            return False

        # Get all the stats & limits
        all_stats = stats.getAllExportsAsDict(plugin_list=self.plugins_to_export())
        all_limits = stats.getAllLimitsAsDict(plugin_list=self.plugins_to_export())

        # Loop over plugins to export
        for plugin in self.plugins_to_export():
            if isinstance(all_stats[plugin], dict):
                all_stats[plugin].update(all_limits[plugin])
            elif isinstance(all_stats[plugin], list):
                all_stats[plugin] += all_limits[plugin]
            else:
                continue
            export_names, export_values = self.__build_export(all_stats[plugin])
            self.export(plugin, export_names, export_values)

        return True

    def __build_export(self, stats):
        """Build the export lists."""
        export_names = []
        export_values = []

        if isinstance(stats, dict):
            # Stats is a dict
            # Is there a key ?
            if 'key' in iterkeys(stats) and stats['key'] in iterkeys(stats):
                pre_key = '{}.'.format(stats[stats['key']])
            else:
                pre_key = ''
            # Walk through the dict
            for key, value in iteritems(stats):
                if isinstance(value, list):
                    try:
                        value = value[0]
                    except IndexError:
                        value = ''
                if isinstance(value, dict):
                    item_names, item_values = self.__build_export(value)
                    item_names = [pre_key + key.lower() + str(i) for i in item_names]
                    export_names += item_names
                    export_values += item_values
                else:
                    export_names.append(pre_key + key.lower())
                    export_values.append(value)
        elif isinstance(stats, list):
            # Stats is a list (of dict)
            # Recursive loop through the list
            for item in stats:
                item_names, item_values = self.__build_export(item)
                export_names += item_names
                export_values += item_values
        return export_names, export_values
                                                                                                                                            ./usr/local/lib/python2.7/dist-packages/glances/exports/glances_riemann.pyc                         0000664 0000000 0000000 00000004604 13070471670 024036  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   s�   d  Z  d d l Z d d l Z d d l m Z d d l m Z d d l m Z d d l	 m
 Z
 d d l Z d e
 f d �  �  YZ d S(	   s   Riemann interface class.i����N(   t   Number(   t   range(   t   logger(   t
 �  |  _ d	 S(
   s   Init the Riemann export IF.t   configt   argst   riemannt   mandatoriest   hostt   portt   optionsi   N(   t   superR   t   __init__t	   load_conft
 rZ } t j d | � d SXd S(   s*   Init the connection to the Riemann server.R	   R
   s"   Connection to Riemann failed : %s N(	   R   t   Nonet   bernhardt   ClientR	   R
   t	   ExceptionR   t   critical(   R   R   t   e(    (    sI   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_riemann.pyR   =   s    	c         C   s�   x� t  t | � � D]� } t | | t � s2 q q i |  j d 6| d | | d 6| | d 6} t j | � y |  j j | � Wq t	 k
 r� } t j
 d | � q Xq Wd S(   s   Write the points in Riemann.R	   t    t   servicet   metrics#   Cannot export stats to Riemann (%s)N(   R   t   lent
   isinstanceR    R   R   t   debugR   t   sendR   t   error(   R   t   namet   columnst   pointst   it   dataR   (    (    sI   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_riemann.pyt   exportH   s    .
   __module__t   __doc__R   R
&��Xc           @   sx   d  Z  d d l Z d d l m Z d d l m Z d d l m Z d d l m	 Z	 d d l
 Z
 d e	 f d �  �  YZ d S(	   s   OpenTSDB interface class.i����N(   t   Number(   t   range(   t   logger(   t
 � n  |  j d k r� d |  _ n  |  j
 �  |  _ d S(
 rz } t	 j
 d |  j |  j | f � t j d � n X| S(   s+   Init the connection to the OpenTSDB server.R
   t
   check_hosts,   Cannot connect to OpenTSDB server %s:%s (%s)i   N(
   t   Truet	   ExceptionR   t   criticalR   R   (   R   t   dbt   e(    (    sJ   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_opentsdb.pyR   =   s    	
 k
 r� } t j d | | f � q Xq Wt j
   isinstanceR    t   formatR   t
   parse_tagsR
   stat_valueR
c         C   s$   |  j  j �  t t |  � j �  d S(   s!   Close the OpenTSDB export module.N(   R   t   waitR   R   R   (   R   (    (    sJ   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_opentsdb.pyR   Z   s    
   __module__t   __doc__R   R   R   R/   R   (    (    (    sJ   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_opentsdb.pyR       s
   		(   R3   R   t   numbersR    t   glances.compatR   t   glances.loggerR   t   glances.exports.glances_exportR   R   R   (    (    (    sJ   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_opentsdb.pyt   <module>   s                                                                                                                             ./usr/local/lib/python2.7/dist-packages/glances/exports/glances_zeromq.pyc                          0000664 0000000 0000000 00000005720 13070471670 023722  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   s�   d  Z  d d l Z d d l Z d d l m Z d d l m Z d d l m Z d d l	 Z	 d d l
 m Z d e f d �  �  YZ d S(	   s   ZeroMQ interface class.i����N(   t   b(   t   logger(   t
 |  _ |  j d d d d d g d g  �|  _ |  j sh t j d	 � n  d
 |  _	 |  j
 �  |  _ d
 S(   s   Init the ZeroMQ export IF.t   configt   argst   zeromqt   mandatoriest   hostt   portt   prefixt   optionsi   N(   t   superR   t   __init__t   NoneR   t	   load_conft
 | � Wn7 t k
 r� } t j
   t   zmqt   ContextR   t   sockett   PUBt   bindt	   ExceptionR   t   criticalR   R   t   info(   R   t
   server_urit	   publishert   e(    (    sH   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_zeromq.pyR   :   s    	c         C   sB   |  j  d k	 r |  j  j �  n  |  j d k	 r> |  j j �  n  d S(   s   Close the socket and contextN(   R   R   t   closeR   t   destroy(   R   (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_zeromq.pyR   M   s    c         C   s�   t  j d j | � � t t | | � � } | i  k r; t St |  j � t | � t t	 j
 | � � g } y |  j j | � Wn, t
 r� } t  j d j | | � � n Xt S(   s&   Write the points to the ZeroMQ server.s   Export {} stats to ZeroMQs%   Cannot export {} stats to ZeroMQ ({})(   R   t   debugR   t   dictt   zipt   FalseR    R   R   t   jsont   dumpsR   t   send_multipartR   t   errort   True(   R   t   namet   columnst   pointst   datat   messageR#   (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_zeromq.pyt   exportT   s    	N(   t   __name__t
   __module__t   __doc__R   R   R   R   R4   (    (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_zeromq.pyR   !   s
   		(
&��Xc           @   sr   d  Z  d d l Z d d l m Z d d l m Z d d l m Z d d l m Z m	 Z	 d e f d �  �  YZ
 d S(	   s   ElasticSearch interface class.i����N(   t   datetime(   t   logger(   t
 |  _ |  j d d d d d g d g  �|  _ |  j sh t j d	 � n  |  j	 �  |  _
 d
 S(   s   Init the ES export IF.t   configt   argst
 rw } t j d |  j |  j | f � t	 j
 d � n Xt j d |  j |  j f � y | j d |  j
 r� } | j j |  j
   s%   Init the connection to the ES server.t   hostss   {}:{}s1   Cannot connect to ElasticSearch server %s:%s (%s)i   s+   Connected to the ElasticSearch server %s:%sR   t   counts9   There is already %s entries in the ElasticSearch %s indexN(   R   R   R   t   formatR
   R   t	   ExceptionR   t   criticalR   R   t   infoR   R   t   indicest   create(   R   t   est   et   index_count(    (    sO   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_elasticsearch.pyR   7   s    	( c   	      C   s�   t  j d j | � � g  } xi t | | � D]X \ } } i |  j d 6| d 6| d 6i t | � d 6t j �  d 6d 6} | j | � q, Wy t	 j
 |  j | � Wn, t k
 r� } t  j
   s"   Write the points to the ES server.s    Export {} stats to ElasticSearcht   _indext   _typet   _idt   valuet	   timestampt   _sources,   Cannot export {} stats to ElasticSearch ({})N(   R   t   debugR   t   zipR   t   strR    t   nowt   appendR   t   bulkR   R   t   error(	   R   t   namet   columnst   pointst   actionst   ct   pt   actionR!   (    (    sO   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_elasticsearch.pyt   exportO   s    

   __module__t   __doc__R   R   R   R7   (    (    (    sO   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_elasticsearch.pyR      s   	(   R:   R   R    t   glances.loggerR   t   glances.exports.glances_exportR   R   R   R   R   (    (    (    sO   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_elasticsearch.pyt   <module>   s                                                                                                     ./usr/local/lib/python2.7/dist-packages/glances/exports/graph.pyc                                   0000664 0000000 0000000 00000012442 13070471670 022011  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   s�   d  Z  d d l Z d d l m Z d d l m Z y# d d l m Z d d l	 j
 Z Wn$ e k
 r{ e
   s   Graph generation class.i����N(   t   iterkeys(   t   logger(   t   __version__sP   Cannot load Matplotlib library. Please install it using "pip install matplotlib"s   Load Matplotlib version %st   GlancesGraphc           B   sY   e  Z d  Z d �  Z d �  Z d �  Z d �  Z d �  Z d �  Z d d � Z	 d	 �  Z
 RS(
   s;   Thanks to this class, Glances can export history to graphs.c         C   s
   get_plugint   get_stats_historyt   Nonet   reset_stats_historyt   True(   R   t   statst   pt   h(    (    s?   /usr/local/lib/python2.7/dist-packages/glances/exports/graph.pyt   reset5   s    c         C   s+   y | d } Wn t  k
 r" d SX| Sd S(   s   Get the item's color.t   colors   #FFFFFFN(   t   KeyError(   R   t   itemt   ret(    (    s?   /usr/local/lib/python2.7/dist-packages/glances/exports/graph.pyt   get_graph_color?   s
    
 r+ d } n X| d k rA d } n | j d � d } d | | f S(   s   Get the item's Y unit.s    (%s)t   y_unitR   t   _i    s   %s%s(   R   t   split(   R   R   t	   pre_labelt   unitt   label(    (    s?   /usr/local/lib/python2.7/dist-packages/glances/exports/graph.pyt   get_graph_yunitL   s    
	c         C   s4  |  j  �  s d Sd } x| j �  D]	} | j | � j �  } | j | � j �  } | d" k s# | d" k rq q# n  t j �  d } g  } g  } x| D]�}	 |	 d t | � k r�t	 j
 d | |	 d f � | d 7} | j t j d# d d d |  j
 �� t j t � t | |	 d �  \ }
 } t j |
 | d d
 d d
 d | |
 } t j |
 | d d
 d d

        Return the number of output files generated by the function.
        i    t   names   Generate graph: %s %si   t   fct   ect	   linewidthi   R    R   t   fmtt	   drawstylet   defaultt	   linestylet   -R   t   xdatet   ydateR   s   Generate graphs: %s %st    i   i   t   Dates   glances_%s_%s.pngt   dpiiH   i
   t   loct   propi	   t   sizes   glances_%s.pngN(   i    i    (&   R	   R   R   t   get_export_historyt   get_items_history_listR   t   pltt   clfR    R   t   debugt   appendt	   RectangleR   R   t   ylabelR#   t   gridR   t   zipt	   plot_dateR
   t   titlet
   capitalizet   sortedt   endswitht   lent   subplott   gcft   set_size_inchest   xlabelt   savefigt   ost   patht   joinR   t   legendt   close(   R   R   t	   index_allR   R   t   iht   index_grapht   handlest   labelst   it   xt   yt   keyt   stats_history_filteredt
   index_itemt   kt   fig(    (    s?   /usr/local/lib/python2.7/dist-packages/glances/exports/graph.pyt   generate_graphX   sz    

@


   __module__t   __doc__R   R   R	   R   R   R   R#   R\   (    (    (    s?   /usr/local/lib/python2.7/dist-packages/glances/exports/graph.pyR   &   s   				
			(   R_   RJ   t   glances.compatR    t   glances.loggerR   t
   matplotlibR   t   matplotlib_versiont   matplotlib.pyplott   pyplotR7   t   ImportErrorR
   R   t   warningR   t   infot   objectR   (    (    (    s?   /usr/local/lib/python2.7/dist-packages/glances/exports/graph.pyt   <module>   s   
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""Prometheus interface class."""

import sys
from datetime import datetime
from numbers import Number

from glances.logger import logger
from glances.exports.glances_export import GlancesExport
from glances.compat import iteritems

from prometheus_client import start_http_server, Gauge


class Export(GlancesExport):

    """This class manages the Prometheus export module."""

    METRIC_SEPARATOR = '_'

    def __init__(self, config=None, args=None):
        """Init the Prometheus export IF."""
        super(Export, self).__init__(config=config, args=args)

        # Optionals configuration keys
        self.prefix = 'glances'

        # Load the Prometheus configuration file section
        self.export_enable = self.load_conf('prometheus',
                                            mandatories=['host', 'port'],
                                            options=['prefix'])
        if not self.export_enable:
            sys.exit(2)

        # Init the metric dict
        # Perhaps a better method is possible...
        self._metric_dict = {}

        # Init the Prometheus Exporter
        self.init()

    def init(self):
        """Init the Prometheus Exporter"""
        try:
            start_http_server(port=int(self.port), addr=self.host)
        except Exception as e:
            logger.critical("Can not start Prometheus exporter on {}:{} ({})".format(self.host, self.port, e))
            sys.exit(2)
        else:
            logger.info("Start Prometheus exporter on {}:{}".format(self.host, self.port))

    def export(self, name, columns, points):
        """Write the points to the Prometheus exporter using Gauge."""
        logger.debug("Export {} stats to Prometheus exporter".format(name))

        # Remove non number stats and convert all to float (for Boolean)
        data = {k: float(v) for (k, v) in iteritems(dict(zip(columns, points))) if isinstance(v, Number)}

        # Write metrics to the Prometheus exporter
        for k, v in iteritems(data):
            # Prometheus metric name: prefix_<glances stats name>
            metric_name = self.prefix + self.METRIC_SEPARATOR + name + self.METRIC_SEPARATOR + k
            # Prometheus is very sensible to the metric name
            # See: https://prometheus.io/docs/practices/naming/
            for c in ['.', '-', '/', ' ']:
                metric_name = metric_name.replace(c, self.METRIC_SEPARATOR)
            # Manage an internal dict between metric name and Gauge
            if metric_name not in self._metric_dict:
                self._metric_dict[metric_name] = Gauge(metric_name, k)
            # Write the value
            self._metric_dict[metric_name].set(v)
                                                                                                                                                  ./usr/local/lib/python2.7/dist-packages/glances/exports/__init__.pyc                                0000664 0000000 0000000 00000000231 13070471670 022440  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   s   d  S(   N(    (    (    (    sB   /usr/local/lib/python2.7/dist-packages/glances/exports/__init__.pyt   <module>   s                                                                                                                                                                                                                                                                                                                                                                           ./usr/local/lib/python2.7/dist-packages/glances/exports/glances_statsd.pyc                          0000664 0000000 0000000 00000004654 13070471670 023714  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   s|   d  Z  d d l Z d d l m Z d d l m Z d d l m Z d d l m	 Z	 d d l
 m Z d e	 f d	 �  �  YZ d S(
   s   Statsd interface class.i����N(   t   Number(   t   range(   t   logger(   t
 |  _ n  |  j	 �  |  _
 d S(   s   Init the Statsd export IF.t   configt   argst   statsdt   mandatoriest   hostt   portt   optionst   prefixi   t   glancesN(   t   superR   t   __init__t   NoneR
   R   R   t   int(   R   R
 r� } t j	 d | � q Xq Wt j
 d j | � � d S(   s&   Export the stats to the Statsd server.s   {}.{}s#   Can not export stats to Statsd (%s)s   Export {} stats to StatsdN(   R   t   lent
   isinstanceR    R   R   t   gauget	   ExceptionR   t   errort   debug(   R   t   namet   columnst   pointst   it	   stat_namet
   stat_valuet   e(    (    sH   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_statsd.pyt   exportG   s    
N(   t   __name__t
   __module__t   __doc__R   R   R   R)   (    (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_statsd.pyR       s   (
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""Cassandra/Scylla interface class."""

import sys
from datetime import datetime
from numbers import Number

from glances.logger import logger
from glances.exports.glances_export import GlancesExport
from glances.compat import iteritems

from cassandra.cluster import Cluster
from cassandra.util import uuid_from_time
from cassandra import InvalidRequest


class Export(GlancesExport):

    """This class manages the Cassandra/Scylla export module."""

    def __init__(self, config=None, args=None):
        """Init the Cassandra export IF."""
        super(Export, self).__init__(config=config, args=args)

        # Mandatories configuration keys (additional to host and port)
        self.keyspace = None

        # Optionals configuration keys
        self.protocol_version = 3
        self.replication_factor = 2
        self.table = None

        # Load the Cassandra configuration file section
        self.export_enable = self.load_conf('cassandra',
                                            mandatories=['host', 'port', 'keyspace'],
                                            options=['protocol_version',
                                                     'replication_factor',
                                                     'table'])
        if not self.export_enable:
            sys.exit(2)

        # Init the Cassandra client
        self.cluster, self.session = self.init()

    def init(self):
        """Init the connection to the InfluxDB server."""
        if not self.export_enable:
            return None

        # Cluster
        try:
            cluster = Cluster([self.host],
                              port=int(self.port),
                              protocol_version=int(self.protocol_version))
            session = cluster.connect()
        except Exception as e:
            logger.critical("Cannot connect to Cassandra cluster '%s:%s' (%s)" % (self.host, self.port, e))
            sys.exit(2)

        # Keyspace
        try:
            session.set_keyspace(self.keyspace)
        except InvalidRequest as e:
            logger.info("Create keyspace {} on the Cassandra cluster".format(self.keyspace))
            c = "CREATE KEYSPACE %s WITH replication = { 'class': 'SimpleStrategy', 'replication_factor': '%s' }" % (self.keyspace, self.replication_factor)
            session.execute(c)
            session.set_keyspace(self.keyspace)

        logger.info(
            "Stats will be exported to Cassandra cluster {} ({}) in keyspace {}".format(
                cluster.metadata.cluster_name, cluster.metadata.all_hosts(), self.keyspace))

        # Table
        try:
            session.execute("CREATE TABLE %s (plugin text, time timeuuid, stat map<text,float>, PRIMARY KEY (plugin, time)) WITH CLUSTERING ORDER BY (time DESC)" % self.table)
        except Exception:
            logger.debug("Cassandra table %s already exist" % self.table)

        return cluster, session

    def export(self, name, columns, points):
        """Write the points to the Cassandra cluster."""
        logger.debug("Export {} stats to Cassandra".format(name))

        # Remove non number stats and convert all to float (for Boolean)
        data = {k: float(v) for (k, v) in dict(zip(columns, points)).iteritems() if isinstance(v, Number)}

        # Write input to the Cassandra table
        try:
            self.session.execute(
                """
                INSERT INTO localhost (plugin, time, stat)
                VALUES (%s, %s, %s)
                """,
                (name, uuid_from_time(datetime.now()), data)
            )
        except Exception as e:
            logger.error("Cannot export {} stats to Cassandra ({})".format(name, e))

    def exit(self):
        """Close the Cassandra export module."""
        # To ensure all connections are properly closed
        self.session.shutdown()
        self.cluster.shutdown()
        # Call the father method
        super(Export, self).exit()
                                                                                                                                                                                                                                                                                                                                                                                                              ./usr/local/lib/python2.7/dist-packages/glances/exports/glances_csv.pyc                             0000664 0000000 0000000 00000006406 13070471670 023202  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   s�   d  Z  d d l Z d d l Z d d l Z d d l m Z m Z m Z d d l m	 Z	 d d l
 m Z d e f d �  �  YZ d S(   s   CSV interface class.i����N(   t   PY3t   iterkeyst
   itervalues(   t   logger(   t
 k
 r� } t j d j
 S(   s   Init the CSV export IF.t   configt   argst   wt   newlinet    t   wbs   Cannot create the CSV file: {}i   s   Stats exported to CSV file: {}N(   t   superR   t   __init__t
   export_csvt   csv_filenameR    t   opent   csv_filet   csvt   writert   IOErrorR   t   criticalt   formatt   syst   exitt   infot   Truet
   first_line(   t   selfR   R   t   e(    (    sE   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_csv.pyR
 � r4� j rt | | � } | �  f d �  | D� 7} n  | t	 | | � 7} q4qL qL W� j r]� j j
   isinstancet   listR   t   dictR   R   t   writerowt   FalseR   t   flush(   R   t   statst	   all_statst   pluginst
   csv_headert   csv_datat   it
   fieldnames(    (   R&   R   R'   sE   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_csv.pyt   update@   s0    				N(   t   __name__t
   __module__t   __doc__t   NoneR
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""JMS interface class."""

import datetime
import socket
import sys
from numbers import Number

from glances.compat import range
from glances.logger import logger
from glances.exports.glances_export import GlancesExport

# Import pika for RabbitMQ
import pika


class Export(GlancesExport):

    """This class manages the rabbitMQ export module."""

    def __init__(self, config=None, args=None):
        """Init the RabbitMQ export IF."""
        super(Export, self).__init__(config=config, args=args)

        # Mandatories configuration keys (additional to host and port)
        self.user = None
        self.password = None
        self.queue = None

        # Optionals configuration keys
        # N/A

        # Load the rabbitMQ configuration file
        self.export_enable = self.load_conf('rabbitmq',
                                            mandatories=['host', 'port',
                                                         'user', 'password',
                                                         'queue'],
                                            options=[])
        if not self.export_enable:
            sys.exit(2)

        # Get the current hostname
        self.hostname = socket.gethostname()

        # Init the rabbitmq client
        self.client = self.init()

    def init(self):
        """Init the connection to the rabbitmq server."""
        if not self.export_enable:
            return None
        try:
            parameters = pika.URLParameters(
                'amqp://' + self.user +
                ':' + self.password +
                '@' + self.host +
                ':' + self.port + '/')
            connection = pika.BlockingConnection(parameters)
            channel = connection.channel()
            return channel
        except Exception as e:
            logger.critical("Connection to rabbitMQ failed : %s " % e)
            return None

    def export(self, name, columns, points):
        """Write the points in RabbitMQ."""
        data = ('hostname=' + self.hostname + ', name=' + name +
                ', dateinfo=' + datetime.datetime.utcnow().isoformat())
        for i in range(len(columns)):
            if not isinstance(points[i], Number):
                continue
            else:
                data += ", " + columns[i] + "=" + str(points[i])
        logger.debug(data)
        try:
            self.client.basic_publish(exchange='', routing_key=self.queue, body=data)
        except Exception as e:
            logger.error("Can not export stats to RabbitMQ (%s)" % e)
                                                                                                                                                                                                                                                                               ./usr/local/lib/python2.7/dist-packages/glances/exports/glances_rabbitmq.pyc                        0000664 0000000 0000000 00000005524 13070471670 024210  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   s�   d  Z  d d l Z d d l Z d d l Z d d l m Z d d l m Z d d l m	 Z	 d d l
 m Z d d l Z d e f d �  �  YZ
 g  �|  _ |  j s� t	 j
 d � n  t j �  |  _
 k
 r� } t j d | � d SXd S(   s+   Init the connection to the rabbitmq server.s   amqp://t   :t   @t   /s#   Connection to rabbitMQ failed : %s N(
   t   BlockingConnectiont   channelt	   ExceptionR   t   critical(   R   t
   parameterst
   connectionR"   t   e(    (    sJ   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_rabbitmq.pyR   B   s    	5c         C   s�   d |  j  d | d t j j �  j �  } xW t t | � � D]C } t | | t � s^ q? q? | d | | d t | | � 7} q? Wt	 j
 | � y& |  j j d d d |  j
 r� } t	 j d
 | � n Xd S(   s   Write the points in RabbitMQ.s	   hostname=s   , name=s   , dateinfo=s   , t   =t   exchanget    t   routing_keyt   bodys%   Can not export stats to RabbitMQ (%s)N(   R   t   datetimet   utcnowt	   isoformatR   t   lent
   isinstanceR    t   strR   t   debugR   t
   __module__t   __doc__R   R   R   R;   (    (    (    sJ   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_rabbitmq.pyR   #   s   	(   R>   R-   R   R   t   numbersR    t   glances.compatR   t   glances.loggerR   t   glances.exports.glances_exportR   R   R   (    (    (    sJ   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_rabbitmq.pyt   <module>   s                                                                                                                                                                               ./usr/local/lib/python2.7/dist-packages/glances/exports/glances_influxdb.pyc                        0000664 0000000 0000000 00000007270 13070471670 024222  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   s�   d  Z  d d l Z d d l m Z d d l m Z d d l m Z d d l m	 Z	 d d l
 m Z d d l m	 Z
 �  �  YZ d S(   s   InfluxDB interface class.i����N(   t   logger(   t
 d d g �|  _
 |  j
 s� t j d
 Wn� t k
 r� t j
 n: t k
 r.} t j d |  j | f � t j d	 � n X|  j | k rZt j
 j | j � � n! t j d |  j � t j d	 � | S(
   t   usernameR   t   databaset   names    Trying fallback to InfluxDB v0.8s-   Cannot connect to InfluxDB database '%s' (%s)i   s-   Stats will be exported to InfluxDB server: {}s6   InfluxDB database '%s' did not exist. Please create itN(   R   R   R   R	   R
   R   R   R
   get_all_dbt   e(    (    sJ   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_influxdb.pyR   B   s8    				#
 f k
 r� } t  j d | | | | | f � qy Xqy Wi | d 6|  j |  j � d 6t
 rZ} t  j d
 j | | � � n Xd S(   s(   Write the points to the InfluxDB server.s   Export {} stats to InfluxDBt   .R   t   columnst   pointss0   InfluxDB error during stat convertion %s=%s (%s)t   measurementR   t   fieldss'   Cannot export {} stats to InfluxDB ({})N(   R    t   debugR&   R   R   R    R#   t	   enumeratet   floatt	   TypeErrort
   ValueErrort
   parse_tagsR   t   dictt   zipR   t   write_pointst	   Exceptiont   error(   R   R   R,   R-   t   dataR(   t   _R*   (    (    sJ   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_influxdb.pyt   exportf   s"    $*
N(   t   __name__t
   __module__t   __doc__R   R   R   R=   (    (    (    sJ   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_influxdb.pyR   %   s   	$(   R@   R   t   glances.loggerR    t   glances.exports.glances_exportR   R   R   t   influxdb.clientR   t   influxdb.influxdb08R"   t   influxdb.influxdb08.clientR$   R#   R   R   (    (    (    sJ   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_influxdb.pyt   <module>   s                                                                                                                                                                                                                                                                                                                                           ./usr/local/lib/python2.7/dist-packages/glances/exports/glances_elasticsearch.py                    0000664 0000000 0000000 00000006635 13066703446 025066  0                                                                                                    ustar                                                                                                                                                                                                                                                          # -*- coding: utf-8 -*-
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""ElasticSearch interface class."""

import sys
from datetime import datetime

from glances.logger import logger
from glances.exports.glances_export import GlancesExport

from elasticsearch import Elasticsearch, helpers


class Export(GlancesExport):

    """This class manages the ElasticSearch (ES) export module."""

    def __init__(self, config=None, args=None):
        """Init the ES export IF."""
        super(Export, self).__init__(config=config, args=args)

        # Mandatories configuration keys (additional to host and port)
        self.index = None

        # Optionals configuration keys
        # N/A

        # Load the ES configuration file
        self.export_enable = self.load_conf('elasticsearch',
                                            mandatories=['host', 'port', 'index'],
                                            options=[])
        if not self.export_enable:
            sys.exit(2)

        # Init the ES client
        self.client = self.init()

    def init(self):
        """Init the connection to the ES server."""
        if not self.export_enable:
            return None

        try:
            es = Elasticsearch(hosts=['{}:{}'.format(self.host, self.port)])
        except Exception as e:
            logger.critical("Cannot connect to ElasticSearch server %s:%s (%s)" % (self.host, self.port, e))
            sys.exit(2)
        else:
            logger.info("Connected to the ElasticSearch server %s:%s" % (self.host, self.port))

        try:
            index_count = es.count(index=self.index)['count']
        except Exception as e:
            # Index did not exist, it will be created at the first write
            # Create it...
            es.indices.create(self.index)
        else:
            logger.info("There is already %s entries in the ElasticSearch %s index" % (index_count, self.index))

        return es

    def export(self, name, columns, points):
        """Write the points to the ES server."""
        logger.debug("Export {} stats to ElasticSearch".format(name))

        # Create DB input
        # https://elasticsearch-py.readthedocs.io/en/master/helpers.html
        actions = []
        for c, p in zip(columns, points):
            action = {
                "_index": self.index,
                "_type": name,
                "_id": c,
                "_source": {
                    "value": str(p),
                    "timestamp": datetime.now()
                }
            }
            actions.append(action)

        # Write input to the ES index
        try:
            helpers.bulk(self.client, actions)
        except Exception as e:
            logger.error("Cannot export {} stats to ElasticSearch ({})".format(name, e))
                                                                                                   ./usr/local/lib/python2.7/dist-packages/glances/exports/glances_cassandra.pyc                       0000664 0000000 0000000 00000010330 13070471670 024335  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   s�   d  Z  d d l Z d d l m Z d d l m Z d d l m Z d d l m Z d d l	 m
 Z
 d d l m Z d d	 l
 l m Z d e f d �  �  YZ d S(
 d d d
 j d � n  |  j �  \ |  _
   (    (    sK   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_cassandra.pyR   '   s    					c         C   s~  |  j  s
 Sy@ t |  j g d t |  j � d t |  j � �} | j �  } Wn@ t k
 r� } t	 j
 d |  j |  j | f � t j d � n Xy | j
 r} t	 j d j |  j � � d |  j |  j f } | j | � | j
 rst	 j d	 |  j � n X| | f S(   s+   Init the connection to the InfluxDB server.R   R   s0   Cannot connect to Cassandra cluster '%s:%s' (%s)i   s+   Create keyspace {} on the Cassandra clusters_   CREATE KEYSPACE %s WITH replication = { 'class': 'SimpleStrategy', 'replication_factor': '%s' }sB   Stats will be exported to Cassandra cluster {} ({}) in keyspace {}s�   CREATE TABLE %s (plugin text, time timeuuid, stat map<text,float>, PRIMARY KEY (plugin, time)) WITH CLUSTERING ORDER BY (time DESC)s    Cassandra table %s already existN(   R   R   R   R
 �  � | f � Wn, t k
 r� } t  j d j | | � � n Xd S(   s*   Write the points to the Cassandra cluster.s   Export {} stats to Cassandrac         S   s4   i  |  ]* \ } } t  | t � r t | � | � q S(    (   t
   isinstanceR   t   float(   t   .0t   kt   v(    (    sK   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_cassandra.pys
   <dictcomp>h   s   	 sp   
                INSERT INTO localhost (plugin, time, stat)
                VALUES (%s, %s, %s)
                s(   Cannot export {} stats to Cassandra ({})N(
   __module__t   __doc__R   R   R   R:   R   (    (    (    sK   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_cassandra.pyR   #   s
   	$	(   R>   R   R    t   numbersR   t   glances.loggerR   t   glances.exports.glances_exportR   t   glances.compatR   t   cassandra.clusterR   t   cassandra.utilR   R   R   R   (    (    (    sK   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_cassandra.pyt   <module>   s                                                                                                                                                                                                                                                                                                           ./usr/local/lib/python2.7/dist-packages/glances/exports/glances_opentsdb.py                         0000664 0000000 0000000 00000006252 13066703446 024065  0                                                                                                    ustar                                                                                                                                                                                                                                                          # -*- coding: utf-8 -*-
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""OpenTSDB interface class."""

import sys
from numbers import Number

from glances.compat import range
from glances.logger import logger
from glances.exports.glances_export import GlancesExport

import potsdb


class Export(GlancesExport):

    """This class manages the OpenTSDB export module."""

    def __init__(self, config=None, args=None):
        """Init the OpenTSDB export IF."""
        super(Export, self).__init__(config=config, args=args)

        # Mandatories configuration keys (additional to host and port)
        # N/A

        # Optionals configuration keys
        self.prefix = None
        self.tags = None

        # Load the InfluxDB configuration file
        self.export_enable = self.load_conf('opentsdb',
                                            mandatories=['host', 'port'],
                                            options=['prefix', 'tags'])
        if not self.export_enable:
            sys.exit(2)

        # Default prefix for stats is 'glances'
        if self.prefix is None:
            self.prefix = 'glances'

        # Init the OpenTSDB client
        self.client = self.init()

    def init(self):
        """Init the connection to the OpenTSDB server."""
        if not self.export_enable:
            return None

        try:
            db = potsdb.Client(self.host,
                               port=int(self.port),
                               check_host=True)
        except Exception as e:
            logger.critical("Cannot connect to OpenTSDB server %s:%s (%s)" % (self.host, self.port, e))
            sys.exit(2)

        return db

    def export(self, name, columns, points):
        """Export the stats to the Statsd server."""
        for i in range(len(columns)):
            if not isinstance(points[i], Number):
                continue
            stat_name = '{}.{}.{}'.format(self.prefix, name, columns[i])
            stat_value = points[i]
            tags = self.parse_tags(self.tags)
            try:
                self.client.send(stat_name, stat_value, **tags)
            except Exception as e:
                logger.error("Can not export stats %s to OpenTSDB (%s)" % (name, e))
        logger.debug("Export {} stats to OpenTSDB".format(name))

    def exit(self):
        """Close the OpenTSDB export module."""
        # Waits for all outstanding metrics to be sent and background thread closes
        self.client.wait()
        # Call the father method
        super(Export, self).exit()
                                                                                                                                                                                                                                                                                                                                                      ./usr/local/lib/python2.7/dist-packages/glances/exports/glances_export.pyc                          0000664 0000000 0000000 00000013737 13070471670 023735  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   sR   d  Z  d d l m Z m Z m Z m Z d d l m Z d e f d �  �  YZ	 d S(   s5   
I am your father...

...for all Glances exports IF.
i����(   t
 d
 �  Z RS(   s!   Main class for Glances export IF.c         C   s^   |  j  j t d � |  _ t j d |  j � | |  _ | |  _ t |  _	 d |  _ d |  _ d S(   s   Init the export class.t   glances_s   Init export module %sN(
   __module__t   lent   export_nameR   t   debugt   configt   argst   Falset
   (   R   (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_export.pyt   exit4   s    c         C   s1   d d d d d d d d d	 d
 d d d
 r} t j d j | � � t St	 k
 r� } t j d j | | � � t SXxE | D]= } y# t �  | �  j  j | | � � Wq� t	 k
 r� q� Xq� Wt j
 d j | � � t j
 d j | �  f d �  | | D� � � t S(   sK  Load the export <section> configuration in the Glances configuration file.

        :param section: name of the export section to load
        :param mandatories: a list of mandatories parameters to load
        :param options: a list of optionnals parameters to load

        :returns: Boolean -- True if section is found
        s   No {} configuration founds"   Error in the {} configuration ({})s+   Load {} from the Glances configuration files   {} parameters: {}c            s"   i  |  ] } t  �  | � | � q S(    (   t   getattr(   t   .0t   opt(   R   (    sH   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_export.pys
   <dictcomp>k   s   	 N(   R   R   R   t   setattrt	   get_valueR   R   t   criticalt   formatR    R   t   True(   R   t   sectiont   mandatoriest   optionsR'   t   e(    (   R   sH   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_export.pyt	   load_confJ   s(    	
 r; t j d j | � � n Xt | t � rS | d S| Sd S(   s#   Return the value of the item 'key'.t   keys   No 'key' available in {}i    N(   t   KeyErrorR   t   errorR+   t
   isinstancet   list(   R   t   itemt   ret(    (    sH   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_export.pyt   get_item_keyo   s    
 rj t j d | � i  } qn Xn  | S(   s�   Parse tags into a dict.

        tags: a comma separated list of 'key:value' pairs.
            Example: foo:bar,spam:eggs
        dtags: a dict of tags.
            Example: {'foo': 'bar', 'spam': 'eggs'}
        t   ,t   :s   Invalid tags passed: %s(   t   dictt   splitt
   ValueErrorR   t   info(   R   t   tagst   dtagst   x(    (    sH   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_export.pyt
   parse_tagsz   s    5
 | | | � qJ Wt S(   s�   Update stats to a server.

        The method builds two lists: names and values
        and calls the export method to export the stats.

        Be aware that CSV export overwrite this class and use a specific one.
        t   plugin_list(   R   R   t   getAllExportsAsDictR$   t   getAllLimitsAsDictR5   R<   t   updateR6   t   _GlancesExport__build_exportt   exportR,   (   R   t   statst	   all_statst
   all_limitst   plugint   export_namest
 r� d } q� Xn  t  | t � r|  j | � \ } } g  | D]  }	 | | j �  t	 |	 � ^ q� } | | 7} | | 7} qp | j
 | | j �  � | j
 | � qp WnL t  | t � r�x: | D]/ }
 |  j |
 � \ } } | | 7} | | 7} q_Wn  | | f S(   s   Build the export lists.R2   s   {}.t    i    (   R5   R<   R   R+   R   R6   t
   IndexErrorRH   t   lowert   strt   append(   R   RJ   RN   RO   t   pre_keyR2   t   valuet
   item_namest   item_valuest   iR7   (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_export.pyt   __build_export�   s2    (

N(   t   __name__R   t   __doc__R   R   R   R$   R1   R9   RC   RG   RH   (    (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_export.pyR      s   		%			N(
   R\   t   glances.compatR    R   R   R   t   glances.loggerR   t   objectR   (    (    (    sH   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_export.pyt   <module>   s   "                                 ./usr/local/lib/python2.7/dist-packages/glances/exports/glances_riemann.py                          0000664 0000000 0000000 00000005267 13066703446 023705  0                                                                                                    ustar                                                                                                                                                                                                                                                          # -*- coding: utf-8 -*-
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""Riemann interface class."""

import socket
import sys
from numbers import Number

from glances.compat import range
from glances.logger import logger
from glances.exports.glances_export import GlancesExport

# Import bernhard for Riemann
import bernhard


class Export(GlancesExport):

    """This class manages the Riemann export module."""

    def __init__(self, config=None, args=None):
        """Init the Riemann export IF."""
        super(Export, self).__init__(config=config, args=args)

        # Mandatories configuration keys (additional to host and port)
        # N/A

        # Optionals configuration keys
        # N/A

        # Load the Riemann configuration
        self.export_enable = self.load_conf('riemann',
                                            mandatories=['host', 'port'],
                                            options=[])
        if not self.export_enable:
            sys.exit(2)

        # Get the current hostname
        self.hostname = socket.gethostname()

        # Init the Riemann client
        self.client = self.init()

    def init(self):
        """Init the connection to the Riemann server."""
        if not self.export_enable:
            return None
        try:
            client = bernhard.Client(host=self.host, port=self.port)
            return client
        except Exception as e:
            logger.critical("Connection to Riemann failed : %s " % e)
            return None

    def export(self, name, columns, points):
        """Write the points in Riemann."""
        for i in range(len(columns)):
            if not isinstance(points[i], Number):
                continue
            else:
                data = {'host': self.hostname, 'service': name + " " + columns[i], 'metric': points[i]}
                logger.debug(data)
                try:
                    self.client.send(data)
                except Exception as e:
                    logger.error("Cannot export stats to Riemann (%s)" % e)
                                                                                                                                                                                                                                                                                                                                         ./usr/local/lib/python2.7/dist-packages/glances/exports/glances_couchdb.py                          0000664 0000000 0000000 00000007144 13066703446 023657  0                                                                                                    ustar                                                                                                                                                                                                                                                          # -*- coding: utf-8 -*-
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""CouchDB interface class."""

import sys
from datetime import datetime

from glances.logger import logger
from glances.exports.glances_export import GlancesExport

import couchdb
import couchdb.mapping


class Export(GlancesExport):

    """This class manages the CouchDB export module."""

    def __init__(self, config=None, args=None):
        """Init the CouchDB export IF."""
        super(Export, self).__init__(config=config, args=args)

        # Mandatories configuration keys (additional to host and port)
        self.db = None

        # Optionals configuration keys
        self.user = None
        self.password = None

        # Load the Cassandra configuration file section
        self.export_enable = self.load_conf('couchdb',
                                            mandatories=['host', 'port', 'db'],
                                            options=['user', 'password'])
        if not self.export_enable:
            sys.exit(2)

        # Init the CouchDB client
        self.client = self.init()

    def init(self):
        """Init the connection to the CouchDB server."""
        if not self.export_enable:
            return None

        if self.user is None:
            server_uri = 'http://{}:{}/'.format(self.host,
                                                self.port)
        else:
            server_uri = 'http://{}:{}@{}:{}/'.format(self.user,
                                                      self.password,
                                                      self.host,
                                                      self.port)

        try:
            s = couchdb.Server(server_uri)
        except Exception as e:
            logger.critical("Cannot connect to CouchDB server %s (%s)" % (server_uri, e))
            sys.exit(2)
        else:
            logger.info("Connected to the CouchDB server %s" % server_uri)

        try:
            s[self.db]
        except Exception as e:
            # Database did not exist
            # Create it...
            s.create(self.db)
        else:
            logger.info("There is already a %s database" % self.db)

        return s

    def database(self):
        """Return the CouchDB database object"""
        return self.client[self.db]

    def export(self, name, columns, points):
        """Write the points to the CouchDB server."""
        logger.debug("Export {} stats to CouchDB".format(name))

        # Create DB input
        data = dict(zip(columns, points))

        # Set the type to the current stat name
        data['type'] = name
        data['time'] = couchdb.mapping.DateTimeField()._to_json(datetime.now())

        # Write input to the CouchDB database
        # Result can be view: http://127.0.0.1:5984/_utils
        try:
            self.client[self.db].save(data)
        except Exception as e:
            logger.error("Cannot export {} stats to CouchDB ({})".format(name, e))
                                                                                                                                                                                                                                                                                                                                                                                                                            ./usr/local/lib/python2.7/dist-packages/glances/exports/glances_kafka.py                            0000664 0000000 0000000 00000006353 13066703446 023326  0                                                                                                    ustar                                                                                                                                                                                                                                                          # -*- coding: utf-8 -*-
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""Kafka interface class."""

import sys

from glances.logger import logger
from glances.compat import iteritems
from glances.exports.glances_export import GlancesExport

from kafka import KafkaProducer
import json


class Export(GlancesExport):

    """This class manages the Kafka export module."""

    def __init__(self, config=None, args=None):
        """Init the Kafka export IF."""
        super(Export, self).__init__(config=config, args=args)

        # Mandatories configuration keys (additional to host and port)
        self.topic = None

        # Optionals configuration keys
        self.compression = None

        # Load the Cassandra configuration file section
        self.export_enable = self.load_conf('kafka',
                                            mandatories=['host', 'port', 'topic'],
                                            options=['compression'])
        if not self.export_enable:
            sys.exit(2)

        # Init the kafka client
        self.client = self.init()

    def init(self):
        """Init the connection to the Kafka server."""
        if not self.export_enable:
            return None

        # Build the server URI with host and port
        server_uri = '{}:{}'.format(self.host, self.port)

        try:
            s = KafkaProducer(bootstrap_servers=server_uri,
                              value_serializer=lambda v: json.dumps(v).encode('utf-8'),
                              compression_type=self.compression)
        except Exception as e:
            logger.critical("Cannot connect to Kafka server %s (%s)" % (server_uri, e))
            sys.exit(2)
        else:
            logger.info("Connected to the Kafka server %s" % server_uri)

        return s

    def export(self, name, columns, points):
        """Write the points to the kafka server."""
        logger.debug("Export {} stats to Kafka".format(name))

        # Create DB input
        data = dict(zip(columns, points))

        # Send stats to the kafka topic
        # key=<plugin name>
        # value=JSON dict
        try:
            self.client.send(self.topic,
                             key=name,
                             value=data)
        except Exception as e:
            logger.error("Cannot export {} stats to Kafka ({})".format(name, e))

    def exit(self):
        """Close the Kafka export module."""
        # To ensure all connections are properly closed
        self.client.flush()
        self.client.close()
        # Call the father method
        super(Export, self).exit()
                                                                                                                                                                                                                                                                                     ./usr/local/lib/python2.7/dist-packages/glances/exports/__init__.py                                 0000664 0000000 0000000 00000000000 13066703446 022273  0                                                                                                    ustar                                                                                                                                                                                                                                                          ./usr/local/lib/python2.7/dist-packages/glances/exports/glances_influxdb.py                         0000664 0000000 0000000 00000011512 13066703446 024055  0                                                                                                    ustar                                                                                                                                                                                                                                                          # -*- coding: utf-8 -*-
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""InfluxDB interface class."""

import sys

from glances.logger import logger
from glances.exports.glances_export import GlancesExport

from influxdb import InfluxDBClient
from influxdb.client import InfluxDBClientError
from influxdb.influxdb08 import InfluxDBClient as InfluxDBClient08
from influxdb.influxdb08.client import InfluxDBClientError as InfluxDBClientError08

# Constants for tracking specific behavior
INFLUXDB_08 = '0.8'
INFLUXDB_09PLUS = '0.9+'


class Export(GlancesExport):

    """This class manages the InfluxDB export module."""

    def __init__(self, config=None, args=None):
        """Init the InfluxDB export IF."""
        super(Export, self).__init__(config=config, args=args)

        # Mandatories configuration keys (additional to host and port)
        self.user = None
        self.password = None
        self.db = None

        # Optionals configuration keys
        self.prefix = None
        self.tags = None

        # Load the InfluxDB configuration file
        self.export_enable = self.load_conf('influxdb',
                                            mandatories=['host', 'port',
                                                         'user', 'password',
                                                         'db'],
                                            options=['prefix', 'tags'])
        if not self.export_enable:
            sys.exit(2)

        # Init the InfluxDB client
        self.client = self.init()

    def init(self):
        """Init the connection to the InfluxDB server."""
        if not self.export_enable:
            return None

        try:
            db = InfluxDBClient(host=self.host,
                                port=self.port,
                                username=self.user,
                                password=self.password,
                                database=self.db)
            get_all_db = [i['name'] for i in db.get_list_database()]
            self.version = INFLUXDB_09PLUS
        except InfluxDBClientError:
            # https://github.com/influxdb/influxdb-python/issues/138
            logger.info("Trying fallback to InfluxDB v0.8")
            db = InfluxDBClient08(host=self.host,
                                  port=self.port,
                                  username=self.user,
                                  password=self.password,
                                  database=self.db)
            get_all_db = [i['name'] for i in db.get_list_database()]
            self.version = INFLUXDB_08
        except InfluxDBClientError08 as e:
            logger.critical("Cannot connect to InfluxDB database '%s' (%s)" % (self.db, e))
            sys.exit(2)

        if self.db in get_all_db:
            logger.info(
                "Stats will be exported to InfluxDB server: {}".format(db._baseurl))
        else:
            logger.critical("InfluxDB database '%s' did not exist. Please create it" % self.db)
            sys.exit(2)

        return db

    def export(self, name, columns, points):
        """Write the points to the InfluxDB server."""
        logger.debug("Export {} stats to InfluxDB".format(name))
        # Manage prefix
        if self.prefix is not None:
            name = self.prefix + '.' + name
        # Create DB input
        if self.version == INFLUXDB_08:
            data = [{'name': name, 'columns': columns, 'points': [points]}]
        else:
            # Convert all int to float (mandatory for InfluxDB>0.9.2)
            # Correct issue#750 and issue#749
            for i, _ in enumerate(points):
                try:
                    points[i] = float(points[i])
                except (TypeError, ValueError) as e:
                    logger.debug("InfluxDB error during stat convertion %s=%s (%s)" % (columns[i], points[i], e))

            data = [{'measurement': name,
                     'tags': self.parse_tags(self.tags),
                     'fields': dict(zip(columns, points))}]
        # Write input to the InfluxDB database
        try:
            self.client.write_points(data)
        except Exception as e:
            logger.error("Cannot export {} stats to InfluxDB ({})".format(name, e))
                                                                                                                                                                                      ./usr/local/lib/python2.7/dist-packages/glances/exports/glances_prometheus.pyc                      0000664 0000000 0000000 00000005740 13070471670 024602  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   s�   d  Z  d d l Z d d l m Z d d l m Z d d l m Z d d l m Z d d l	 m
 Z
 d d l m Z m
 �  �  YZ d S(   s   Prometheus interface class.i����N(   t   datetime(   t   Number(   t   logger(   t
 � n  i  |  _ |  j	 �  d S(   s   Init the Prometheus export IF.t   configt   argst   glancest
   prometheust   mandatoriest   hostt   portt   optionst   prefixi   N(
   t   superR   t   __init__R   t	   load_conft
   (    (    sL   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_prometheus.pyR   '   s    			c         C   s�   y# t  d t |  j � d |  j � WnB t k
 rg } t j d j |  j |  j | � � t j	 d � n  Xt j
 d j |  j |  j � � d S(   s   Init the Prometheus ExporterR   t   addrs/   Can not start Prometheus exporter on {}:{} ({})i   s"   Start Prometheus exporter on {}:{}N(   R   t   intR   R   t	   ExceptionR   t   criticalt   formatR   R   t   info(   R   t   e(    (    sL   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_prometheus.pyR   <   s    #"c   	      C   s�   t  j d j | � � d �  t t t | | � � � D� } x� t | � D]� \ } } |  j |  j | |  j | } x/ d d d d g D] } | j | |  j � } q� W| |  j	 k r� t
 | | � |  j	 | <n  |  j	 | j | � qH Wd S(   s8   Write the points to the Prometheus exporter using Gauge.s&   Export {} stats to Prometheus exporterc         S   s4   i  |  ]* \ } } t  | t � r t | � | � q S(    (   t
   isinstanceR   t   float(   t   .0t   kt   v(    (    sL   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_prometheus.pys
   <dictcomp>K   s   	 t   .t   -t   /t    N(   R   t   debugR   R   t   dictt   zipR   t   METRIC_SEPARATORt   replaceR   R   t   set(	   R   t   namet   columnst   pointst   dataR%   R&   t   metric_namet   c(    (    sL   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_prometheus.pyt   exportF   s    %N(   t   __name__t
   __module__t   __doc__R.   t   NoneR   R   R7   (    (    (    sL   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_prometheus.pyR   !   s
   	
(   R:   R   R    t   numbersR   t   glances.loggerR   t   glances.exports.glances_exportR   t   glances.compatR   t   prometheus_clientR   R   R   (    (    (    sL   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_prometheus.pyt   <module>   s                                   ./usr/local/lib/python2.7/dist-packages/glances/exports/glances_kafka.pyc                           0000664 0000000 0000000 00000006011 13070471670 023454  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   sx   d  Z  d d l Z d d l m Z d d l m Z d d l m Z d d l m	 Z	 d d l
 Z
 d e f d �  �  YZ d S(	   s   Kafka interface class.i����N(   t   logger(   t	   iteritems(   t
 � n  |  j
 �  |  _ d S(   s   Init the Kafka export IF.t   configt   argst   kafkat   mandatoriest   hostt   portt   topict   optionst   compressioni   N(   t   superR   t   __init__t   NoneR   R
 r� } t j	 d | | f � t
 j d � n Xt j d | � | S(
   s(   Init the connection to the Kafka server.s   {}:{}t   bootstrap_serverst   value_serializerc         S   s   t  j |  � j d � S(   Ns   utf-8(   t   jsont   dumpst   encode(   t   v(    (    sG   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_kafka.pyt   <lambda>B   s    t   compression_types&   Cannot connect to Kafka server %s (%s)i   s    Connected to the Kafka server %sN(
   R   R
   server_urit   st   e(    (    sG   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_kafka.pyR   8   s    		c         C   s�   t  j d j | � � t t | | � � } y# |  j j |  j d | d | �Wn, t k
 r| } t  j	 d j | | � � n Xd S(   s%   Write the points to the kafka server.s   Export {} stats to Kafkat   keyt   values$   Cannot export {} stats to Kafka ({})N(
   R    t   debugR    t   dictt   zipR   t   sendR   R!   t   error(   R   t   namet   columnst   pointst   dataR&   (    (    sG   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_kafka.pyt   exportL   s    c         C   s1   |  j  j �  |  j  j �  t t |  � j �  d S(   s   Close the Kafka export module.N(   R   t   flusht   closeR   R   R   (   R   (    (    sG   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_kafka.pyR   ]   s    
   __module__t   __doc__R   R   R   R2   R   (    (    (    sG   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_kafka.pyR       s
   		(   R7   R   t   glances.loggerR    t   glances.compatR   t   glances.exports.glances_exportR   R   R   R   R   (    (    (    sG   /usr/local/lib/python2.7/dist-packages/glances/exports/glances_kafka.pyt   <module>   s                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          ./usr/local/lib/python2.7/dist-packages/glances/exports/glances_csv.py                              0000664 0000000 0000000 00000006723 13066703446 023045  0                                                                                                    ustar                                                                                                                                                                                                                                                          # -*- coding: utf-8 -*-
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""CSV interface class."""

import csv
import sys
import time

from glances.compat import PY3, iterkeys, itervalues
from glances.logger import logger
from glances.exports.glances_export import GlancesExport


class Export(GlancesExport):

    """This class manages the CSV export module."""

    def __init__(self, config=None, args=None):
        """Init the CSV export IF."""
        super(Export, self).__init__(config=config, args=args)

        # CSV file name
        self.csv_filename = args.export_csv

        # Set the CSV output file
        try:
            if PY3:
                self.csv_file = open(self.csv_filename, 'w', newline='')
            else:
                self.csv_file = open(self.csv_filename, 'wb')
            self.writer = csv.writer(self.csv_file)
        except IOError as e:
            logger.critical("Cannot create the CSV file: {}".format(e))
            sys.exit(2)

        logger.info("Stats exported to CSV file: {}".format(self.csv_filename))

        self.export_enable = True

        self.first_line = True

    def exit(self):
        """Close the CSV file."""
        logger.debug("Finalise export interface %s" % self.export_name)
        self.csv_file.close()

    def update(self, stats):
        """Update stats in the CSV output file."""
        # Get the stats
        all_stats = stats.getAllExports()
        plugins = stats.getAllPlugins()

        # Init data with timestamp (issue#708)
        if self.first_line:
            csv_header = ['timestamp']
        csv_data = [time.strftime('%Y-%m-%d %H:%M:%S')]

        # Loop over available plugin
        for i, plugin in enumerate(plugins):
            if plugin in self.plugins_to_export():
                if isinstance(all_stats[i], list):
                    for stat in all_stats[i]:
                        # First line: header
                        if self.first_line:
                            csv_header += ('{}_{}_{}'.format(
                                plugin, self.get_item_key(stat), item) for item in stat)
                        # Others lines: stats
                        csv_data += itervalues(stat)
                elif isinstance(all_stats[i], dict):
                    # First line: header
                    if self.first_line:
                        fieldnames = iterkeys(all_stats[i])
                        csv_header += ('{}_{}'.format(plugin, fieldname)
                                       for fieldname in fieldnames)
                    # Others lines: stats
                    csv_data += itervalues(all_stats[i])

        # Export to CSV
        if self.first_line:
            self.writer.writerow(csv_header)
            self.first_line = False
        self.writer.writerow(csv_data)
        self.csv_file.flush()
                                             ./usr/local/lib/python2.7/dist-packages/glances/attribute.pyc                                       0000664 0000000 0000000 00000012276 13070471670 021214  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   s0   d  Z  d d l m Z d e f d �  �  YZ d S(   s   Attribute class.i����(   t   datetimet   GlancesAttributec           B   s  e  Z d  d d � Z d �  Z d �  Z e d �  � Z e j d �  � Z e d �  � Z	 e	 j d �  � Z	 e d �  � Z
 e
 j d	 �  � Z
 e d
 �  � Z e j d �  � Z e j d �  � Z d
        name: Attribute name (string)
        description: Attribute human reading description (string)
        history_max_size: Maximum size of the history list (default is no limit)

        History is stored as a list for tuple: [(date, value), ...]
        N(   t   _namet   _descriptiont   Nonet   _valuet   _history_max_sizet   _history(   t   selft   namet   descriptiont   history_max_size(    (    s;   /usr/local/lib/python2.7/dist-packages/glances/attribute.pyt   __init__   s
    				c         C   s   |  j  S(   N(   t   value(   R	   (    (    s;   /usr/local/lib/python2.7/dist-packages/glances/attribute.pyt   __repr__)   s    c         C   s
   2   s    c         C   s
   6   s    c         C   s   |  j  S(   N(   R   (   R	   (    (    s;   /usr/local/lib/python2.7/dist-packages/glances/attribute.pyR   =   s    c         C   s
        Value is a tuple: (<timestamp>, <new_value>)
        N(   R    t   nowR   t   history_add(   R	   t	   new_value(    (    s;   /usr/local/lib/python2.7/dist-packages/glances/attribute.pyR   O   s    c         C   s   |  j  S(   N(   R   (   R	   (    (    s;   /usr/local/lib/python2.7/dist-packages/glances/attribute.pyt   historyZ   s    c         C   s
   |  `  d  S(   N(   R   (   R	   (    (    s;   /usr/local/lib/python2.7/dist-packages/glances/attribute.pyR   b   s    c         C   s
        i   N(   R   R   R   R   t   append(   R	   R   (    (    s;   /usr/local/lib/python2.7/dist-packages/glances/attribute.pyR   i   s    $c         C   s
        (   t   lenR   (   R	   (    (    s;   /usr/local/lib/python2.7/dist-packages/glances/attribute.pyt   history_sizeq   s    c         C   s
        (   R   R   (   R	   (    (    s;   /usr/local/lib/python2.7/dist-packages/glances/attribute.pyR   v   s    i   c         C   s   |  j  | S(   s}   Return the value in position pos in the history.
        Default is to return the latest value added to the history.
        (   R   (   R	   t   pos(    (    s;   /usr/local/lib/python2.7/dist-packages/glances/attribute.pyR   {   s    i    c         C   s3   g  |  j  | D]  } | d j �  | d f ^ q S(   sB   Return the history of last nb items (0 for all) In ISO JSON formati    i   (   R   t	   isoformat(   R	   t   nbt   i(    (    s;   /usr/local/lib/python2.7/dist-packages/glances/attribute.pyt   history_json�   s    i   c         C   s;   t  |  j �  \ } } t | | � t | d | | � S(   s;   Return the mean on the <nb> values in the history.
        i����(   t   zipR   t   sumt   float(   R	   R!   t   _t   v(    (    s;   /usr/local/lib/python2.7/dist-packages/glances/attribute.pyt   history_mean�   s    N(   t   __name__t
   __module__R   R
   t   setterR   R   R   t   deleterR   R   R   R   R   R#   R)   (    (    (    s;   /usr/local/lib/python2.7/dist-packages/glances/attribute.pyR      s&   						N(   t   __doc__R    t   objectR   (    (    (    s;   /usr/local/lib/python2.7/dist-packages/glances/attribute.pyt   <module>   s                                                                                                                                                                                                                                                                                                                                     ./usr/local/lib/python2.7/dist-packages/glances/autodiscover.pyc                                    0000664 0000000 0000000 00000021731 13070471670 021714  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   sb  d  Z  d d l Z d d l Z d d l m Z d d l m Z y, d d l m Z	 m
 Z
 m Z m Z e
 r� e Z n Xe r d Z e g  e	 j d � D] Z e e � ^ q� � Z e j d	 j e	 � � e e k  r e j d
 � e j d � q n  d Z d e f d �  �  YZ d e f d �  �  YZ d e f d �  �  YZ d e f d �  �  YZ  d S(   sB   Manage autodiscover Glances server (thk to the ZeroConf protocol).i����N(   t   BSD(   t   logger(   t   __version__t   ServiceBrowsert   ServiceInfot   Zeroconfi    i   t   .s   Zeroconf version {} detected.s'   Please install zeroconf 0.17 or higher.i   s   _%s._tcp.local.t   glancest   AutoDiscoveredc           B   s;   e  Z d  Z d �  Z d �  Z d �  Z d �  Z d �  Z RS(   s1   Class to manage the auto discovered servers dict.c         C   s
   (    (    s>   /usr/local/lib/python2.7/dist-packages/glances/autodiscover.pyt   get_servers_list?   s    c         C   s   | |  j  | | <d S(   sC   Set the key to the value for the server_pos (position in the list).N(   R	   (   R
   t
   server_post   keyt   value(    (    s>   /usr/local/lib/python2.7/dist-packages/glances/autodiscover.pyt
   set_serverC   s    c         C   s�   i | d 6| j  d � d d 6| d 6| d 6d d 6d	 d
 6d d 6d
   R   R   R   t
   new_server(    (    s>   /usr/local/lib/python2.7/dist-packages/glances/autodiscover.pyt
   add_serverG   s    
	c         C   s�   x� |  j  D]� } | d | k r
 yH |  j  j | � t j d | � t j d t |  j  � |  j  f � Wq� t k
 r� t j d | � q� Xq
 q
 Wd S(   s   Remove a server from the dict.R   s   Remove server %s from the lists%   Updated servers list (%s servers): %ss%   Cannot remove server %s from the listN(   R	   t   removeR   R   R   t
   ValueErrort   error(   R
   R   t   i(    (    s>   /usr/local/lib/python2.7/dist-packages/glances/autodiscover.pyt
   __module__t   __doc__R   R   R   R!   R&   (    (    (    s>   /usr/local/lib/python2.7/dist-packages/glances/autodiscover.pyR   6   s   				t   GlancesAutoDiscoverListenerc           B   s;   e  Z d  Z d �  Z d �  Z d �  Z d �  Z d �  Z RS(   s%   Zeroconf listener for Glances server.c         C   s   t  �  |  _ d  S(   N(   R   t   servers(   R
   (    (    s>   /usr/local/lib/python2.7/dist-packages/glances/autodiscover.pyR   h   s    c         C   s
   (    (    s>   /usr/local/lib/python2.7/dist-packages/glances/autodiscover.pyR   l   s    c         C   s   |  j  j | | | � d S(   sC   Set the key to the value for the server_pos (position in the list).N(   R+   R   (   R
   R
 | | | � t j d | | | f � n

        Return True if the zeroconf client is a Glances server
        Note: the return code will never be used
        s"   Check new Zeroconf server: %s / %ss+   New Glances server detected (%s from %s:%s)sC   New Glances server detected, but Zeroconf info failed to be grabbed(   t
   t   zeroconft   srv_typet   srv_nameR2   t
   R5   R6   R7   (    (    s>   /usr/local/lib/python2.7/dist-packages/glances/autodiscover.pyt   remove_service�   s    (   R'   R(   R)   R   R   R   R:   R;   (    (    (    s>   /usr/local/lib/python2.7/dist-packages/glances/autodiscover.pyR*   d   s   				t   GlancesAutoDiscoverServerc           B   s5   e  Z d  Z d d � Z d �  Z d �  Z d �  Z RS(   sM   Implementation of the Zeroconf protocol (server side for the Glances client).c         C   s�   t  r� t j d � y t �  |  _ Wn0 t j k
 rU } t j d | � t |  _ q� Xt	 �  |  _
 t |  j t |  j
 � |  _
   t   argst   e(    (    s>   /usr/local/lib/python2.7/dist-packages/glances/autodiscover.pyR   �   s    
   (    (    s>   /usr/local/lib/python2.7/dist-packages/glances/autodiscover.pyR   �   s    
   R
   (    (    s>   /usr/local/lib/python2.7/dist-packages/glances/autodiscover.pyRC   �   s    N(   R'   R(   R)   t   NoneR   R   R   RC   (    (    (    s>   /usr/local/lib/python2.7/dist-packages/glances/autodiscover.pyR<   �   s
   		t   GlancesAutoDiscoverClientc           B   s2   e  Z d  Z d d � Z e d �  � Z d �  Z RS(   sM   Implementation of the zeroconf protocol (client side for the Glances server).c         C   sf  t  rU| j } y t �  |  _ Wn, t j k
 rM } t j d j | � � n Xt s� y | d k rr |  j	 �  } n  Wq� t
 k
 r� q� Xn  t j | | j � d d } t
 | �|  _ y |  j j |  j � Wn, t j k
 rC} t j d j | � � qbXd j | � GHn
   propertiest   servers)   Error while announcing Glances server: {}s<   Announce the Glances server on the LAN (using {} IP address)sJ   Cannot announce Glances server on the network: zeroconf library not found.(   R=   t   bind_addressR   R5   R/   R$   R   t   formatR    t   find_active_ip_addresst   KeyErrort   getaddrinfoR   R   R,   t	   inet_ptonR2   t   register_service(   R
   t   hostnameRA   t   zeroconf_bind_addressRB   t   address_family(    (    s>   /usr/local/lib/python2.7/dist-packages/glances/autodiscover.pyR   �   s.    	
   (    (    s>   /usr/local/lib/python2.7/dist-packages/glances/autodiscover.pyRC   �   s    N(   R'   R(   R)   RD   R   t   staticmethodRL   RC   (    (    (    s>   /usr/local/lib/python2.7/dist-packages/glances/autodiscover.pyRE   �   s   $	(   i    i   i    s   _glances._tcp.local.(!   R)   R/   t   syst   glances.globalsR    t   glances.loggerR   R5   R   t   __zeroconf_versionR   R   R   R4   R=   t   ImportErrorR-   t   zeroconf_min_versiont   tupleR   t   numt   intt   zeroconf_versionR   RK   t   criticalt   exitR,   t   objectR   R*   R<   RE   (    (    (    s>   /usr/local/lib/python2.7/dist-packages/glances/autodiscover.pyt   <module>   s*   "

.
&��Xc           @   sP   d  Z  d d l m Z d d l m Z d d l m Z d e f d �  �  YZ d S(   sy  
I am your father...

...for all Glances Application Monitoring Processes (AMP).

AMP (Application Monitoring Process)
A Glances AMP is a Python script called (every *refresh* seconds) if:
- the AMP is *enabled* in the Glances configuration file
- a process is running (match the *regex* define in the configuration file)
The script should define a Amp (GlancesAmp) class with, at least, an update method.
The update method should call the set_result method to set the AMP return string.
The return string is a string with one or more line (
 between lines).
If the *one_line* var is true then the AMP will be displayed in one line.
i����(   t   u(   t   Timer(   t   loggert
   GlancesAmpc           B   s�   e  Z d  Z d Z d Z d Z d Z d Z d d d � Z	 d �  Z
 d �  Z d �  Z d �  Z
 �  Z d �  Z d �  Z d
 i  |  _ t d � |  _
   __module__t   lent   amp_namet   argst   configsR   t   timer(   t   selft   nameR   (    (    sB   /usr/local/lib/python2.7/dist-packages/glances/amps/glances_amp.pyt   __init__1   s    			c         C   s�  d |  j  } t | d � r| j | � rt j d j |  j � � x� | j | � D]� \ } } y | j | | � |  j	 | <Wng t
 k
 r� | j | | � j d � |  j	 | <t
 g D]G } | |  j	 k rPt j d j |  j | |  j  � � d |  j	 d
   ValueErrort	   get_valuet   splitR
   (   R   t   key(    (    sB   /usr/local/lib/python2.7/dist-packages/glances/amps/glances_amp.pyt   getu   s    c         C   s6   |  j  d � } | d k r t S| j �  j d � Sd S(   sV   Return True|False if the AMP is enabled in the configuration file (enable=true|false).R   t   trueN(   R,   R
   R#   t   lowert
   startswith(   R   t   ret(    (    sB   /usr/local/lib/python2.7/dist-packages/glances/amps/glances_amp.pyR   |   s    c         C   s
   R#   R.   R/   (   R   R0   (    (    sB   /usr/local/lib/python2.7/dist-packages/glances/amps/glances_amp.pyR1   �   s    c         C   s
        - AMP is enable
        - only update every 'refresh' seconds
        (   R   t   finishedt   setR   t   resetR   R#   (   R   (    (    sB   /usr/local/lib/python2.7/dist-packages/glances/amps/glances_amp.pyt
    
c         C   s   | |  j  d <d S(   s.   Set the number of processes matching the regexR   N(   R   (   R   R   (    (    sB   /usr/local/lib/python2.7/dist-packages/glances/amps/glances_amp.pyt	   set_count�   s    c         C   s
        if one_line is true then replace 
 by separator
        s   
t   resultN(   R1   t   strt   replaceR   (   R   R=   t	   separator(    (    sB   /usr/local/lib/python2.7/dist-packages/glances/amps/glances_amp.pyt
   set_result�   s    "c         C   s.   |  j  d � } | d k	 r* t | � } n  | S(   s+    Return the result of the AMP (as a string)R=   N(   R,   R
   R    (   R   R0   (    (    sB   /usr/local/lib/python2.7/dist-packages/glances/amps/glances_amp.pyR=   �   s    c         C   s:   |  j  t | � � |  j �  r, |  j | � S|  j �  Sd S(   s   Wrapper for the children updateN(   R7   R
   R   R*   R,   R   R   R   R1   R2   R6   R7   R   R9   R;   RA   R=   RD   (    (    (    sB   /usr/local/lib/python2.7/dist-packages/glances/amps/glances_amp.pyR   (   s,   	0													N(	   RF   t   glances.compatR    t
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""
SystemV AMP
===========

Monitor the state of the Syste V init system and service.

How to read the stats
---------------------

Running: Number of running services.
Stopped: Number of stopped services.
Upstart: Number of service managed by Upstart.

Source reference: http://askubuntu.com/questions/407075/how-to-read-service-status-all-results

Configuration file example
--------------------------

[amp_systemv]
# Systemv
enable=true
regex=\/sbin\/init
refresh=60
one_line=true
service_cmd=/usr/bin/service --status-all
"""

from subprocess import check_output, STDOUT

from glances.logger import logger
from glances.compat import iteritems
from glances.amps.glances_amp import GlancesAmp


class Amp(GlancesAmp):
    """Glances' Systemd AMP."""

    NAME = 'SystemV'
    VERSION = '1.0'
    DESCRIPTION = 'Get services list from service (initd)'
    AUTHOR = 'Nicolargo'
    EMAIL = 'contact@nicolargo.com'

    # def __init__(self, args=None):
    #     """Init the AMP."""
    #     super(Amp, self).__init__(args=args)

    def update(self, process_list):
        """Update the AMP"""
        # Get the systemctl status
        logger.debug('{}: Update stats using service {}'.format(self.NAME, self.get('service_cmd')))
        try:
            res = check_output(self.get('service_cmd').split(), stderr=STDOUT).decode('utf-8')
        except OSError as e:
            logger.debug('{}: Error while executing service ({})'.format(self.NAME, e))
        else:
            status = {'running': 0, 'stopped': 0, 'upstart': 0}
            # For each line
            for r in res.split('\n'):
                # Split per space .*
                l = r.split()
                if len(l) < 4:
                    continue
                if l[1] == '+':
                    status['running'] += 1
                elif l[1] == '-':
                    status['stopped'] += 1
                elif l[1] == '?':
                    status['upstart'] += 1
            # Build the output (string) message
            output = 'Services\n'
            for k, v in iteritems(status):
                output += '{}: {}\n'.format(k, v)
            self.set_result(output, separator=' ')

        return self.result()
                                                                                                 ./usr/local/lib/python2.7/dist-packages/glances/amps/glances_amp.py                                 0000664 0000000 0000000 00000015457 13066703446 022267  0                                                                                                    ustar                                                                                                                                                                                                                                                          # -*- coding: utf-8 -*-
#
# This file is part of Glances.
#
# Copyright (C) 2017 Nicolargo <nicolas@nicolargo.com>
#
# Glances is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Glances is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

"""
I am your father...

...for all Glances Application Monitoring Processes (AMP).

AMP (Application Monitoring Process)
A Glances AMP is a Python script called (every *refresh* seconds) if:
- the AMP is *enabled* in the Glances configuration file
- a process is running (match the *regex* define in the configuration file)
The script should define a Amp (GlancesAmp) class with, at least, an update method.
The update method should call the set_result method to set the AMP return string.
The return string is a string with one or more line (\n between lines).
If the *one_line* var is true then the AMP will be displayed in one line.
"""

from glances.compat import u
from glances.timer import Timer
from glances.logger import logger


class GlancesAmp(object):
    """Main class for Glances AMP."""

    NAME = '?'
    VERSION = '?'
    DESCRIPTION = '?'
    AUTHOR = '?'
    EMAIL = '?'

    def __init__(self, name=None, args=None):
        """Init AMP classe."""
        logger.debug("Init {} version {}".format(self.NAME, self.VERSION))

        # AMP name (= module name without glances_)
        if name is None:
            self.amp_name = self.__class__.__module__[len('glances_'):]
        else:
            self.amp_name = name

        # Init the args
        self.args = args

        # Init the configs
        self.configs = {}

        # A timer is needed to only update every refresh seconds
        # Init to 0 in order to update the AMP on startup
        self.timer = Timer(0)

    def load_config(self, config):
        """Load AMP parameters from the configuration file."""

        # Read AMP confifuration.
        # For ex, the AMP foo should have the following section:
        #
        # [foo]
        # enable=true
        # regex=\/usr\/bin\/nginx
        # refresh=60
        #
        # and optionnaly:
        #
        # one_line=false
        # option1=opt1
        # ...
        #
        amp_section = 'amp_' + self.amp_name
        if (hasattr(config, 'has_section') and
                config.has_section(amp_section)):
            logger.debug("{}: Load configuration".format(self.NAME))
            for param, _ in config.items(amp_section):
                try:
                    self.configs[param] = config.get_float_value(amp_section, param)
                except ValueError:
                    self.configs[param] = config.get_value(amp_section, param).split(',')
                    if len(self.configs[param]) == 1:
                        self.configs[param] = self.configs[param][0]
                logger.debug("{}: Load parameter: {} = {}".format(self.NAME, param, self.configs[param]))
        else:
            logger.debug("{}: Can not find section {} in the configuration file".format(self.NAME, self.amp_name))
            return False

        # enable, regex and refresh are mandatories
        # if not configured then AMP is disabled
        if self.enable():
            for k in ['regex', 'refresh']:
                if k not in self.configs:
                    logger.warning("{}: Can not find configuration key {} in section {}".format(self.NAME, k, self.amp_name))
                    self.configs['enable'] = 'false'
        else:
            logger.debug("{} is disabled".format(self.NAME))

        # Init the count to 0
        self.configs['count'] = 0

        return self.enable()

    def get(self, key):
        """Generic method to get the item in the AMP configuration"""
        if key in self.configs:
            return self.configs[key]
        else:
            return None

    def enable(self):
        """Return True|False if the AMP is enabled in the configuration file (enable=true|false)."""
        ret = self.get('enable')
        if ret is None:
            return False
        else:
            return ret.lower().startswith('true')

    def regex(self):
        """Return regular expression used to identified the current application."""
        return self.get('regex')

    def refresh(self):
        """Return refresh time in seconds for the current application monitoring process."""
        return self.get('refresh')

    def one_line(self):
        """Return True|False if the AMP shoukd be displayed in oneline (one_lineline=true|false)."""
        ret = self.get('one_line')
        if ret is None:
            return False
        else:
            return ret.lower().startswith('true')

    def time_until_refresh(self):
        """Return time in seconds until refresh."""
        return self.timer.get()

    def should_update(self):
        """Return True is the AMP should be updated:
        - AMP is enable
        - only update every 'refresh' seconds
        """
        if self.timer.finished():
            self.timer.set(self.refresh())
            self.timer.reset()
            return self.enable()
        return False

    def set_count(self, count):
        """Set the number of processes matching the regex"""
        self.configs['count'] = count

    def count(self):
        """Get the number of processes matching the regex"""
        return self.get('count')

    def count_min(self):
        """Get the minimum number of processes"""
        return self.get('countmin')

    def count_max(self):
        """Get the maximum number of processes"""
        return self.get('countmax')

    def set_result(self, result, separator=''):
        """Store the result (string) into the result key of the AMP
        if one_line is true then replace \n by separator
        """
        if self.one_line():
            self.configs['result'] = str(result).replace('\n', separator)
        else:
            self.configs['result'] = str(result)

    def result(self):
        """ Return the result of the AMP (as a string)"""
        ret = self.get('result')
        if ret is not None:
            ret = u(ret)
        return ret

    def update_wrapper(self, process_list):
        """Wrapper for the children update"""
        # Set the number of running process
        self.set_count(len(process_list))
        # Call the children update method
        if self.should_update():
            return self.update(process_list)
        else:
            return self.result()
                                                                                                                                                                                                                 ./usr/local/lib/python2.7/dist-packages/glances/amps/glances_default.pyc                            0000664 0000000 0000000 00000004555 13070471670 023272  0                                                                                                    ustar                                                                                                                                                                                                                                                          �
&��Xc           @   sr   d  Z  d d l m Z m Z m Z d d l m Z m Z d d l m	 Z	 d d l
 m Z d e f d �  �  YZ d S(	   s  
Default AMP
=========

Monitor a process by executing a command line. This is the default AMP's behavor
if no AMP script is found.

Configuration file example
--------------------------

[amp_foo]
enable=true