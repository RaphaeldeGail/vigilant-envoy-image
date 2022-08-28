#!/bin/bash

# Define global shortcuts and variables
## Environment variables for executables
export DEBIAN_FRONTEND=noninteractive

# Define functions
get () {
   apt-get install -y -qq --no-show-upgraded $@ 1>/dev/null
   return $?
}

info () {
   echo "[$(date -I'seconds')][$(hostname)][INFO] : $*"
   return 0
}

error () {
   echo "[$(date -I'seconds')][$(hostname)][ERROR] : $*" >&2
   echo "********** Build Failed. **********" >&2
   exit 1
   return 0
}

envoy_config () {
   info "Loading envoy default configuration file."
   mkdir -p $ENVOY_DIRECTORY
   echo -n "$ENVOY_CONFIGURATION" | base64 --decode >$ENVOY_CONFIGURATION_FILE
   if ! test -s $ENVOY_CONFIGURATION_FILE; then
      error "Envoy default configuration file was not correctly written to $ENVOY_CONFIGURATION_FILE."
      return 1
   fi
   info "Envoy default configuration file successfully written to $ENVOY_CONFIGURATION_FILE."
   return 0
}

ssl_config () {
   info "Adding server SSL private key."
   if [ -z "$SERVER_KEY" ]; then
      error "The environment variable SERVER_KEY is empty."
   fi
   echo -n "$SERVER_KEY" | base64 --decode >$SERVER_KEY_PATH
   chmod 400 $SERVER_KEY_PATH
   if ! test -s $SERVER_KEY_PATH; then
      error "The server SSL private key was not correctly written on file $SERVER_KEY_PATH."
   fi
   info "Server SSL private key successfully written on file $SERVER_KEY_PATH."

   info "Adding server SSL certificate."
   if [ -z "$SERVER_CERT" ]; then
      error "No public certificate SERVER_CERT found."
   fi
   echo -n "$SERVER_CERT" | base64 --decode >$SERVER_CERT_PATH
   chmod 600 $SERVER_CERT_PATH
   if ! test -s $SERVER_CERT_PATH; then
      error "The server SSL certificate was not correctly written on file $SERVER_CERT_PATH."
   fi
   info "Server SSL certificate successfully written on file $SERVER_CERT_PATH."

   info "Testing if public and private SSL keys of server match."
   if ! [ "$(openssl rsa -noout -modulus -in $SERVER_KEY_PATH | openssl md5)"=="$(openssl x509 -noout -modulus -in $SERVER_CERT_PATH | openssl md5)" ]; then
      error "Public and private SSL keys of server do not match."
   fi
   info "Public and private SSL keys of server match."

   info "SSL keys succesfully loaded."
   return 0
}

install_envoy () {
   info "Downloading Envoy binary."
   gsutil -q cp gs://main-lab-v1-executables/envoy-v1.21.0 $ENVOY_PATH
   chmod 555 $ENVOY_PATH
   if ! envoy --version; then
      error "Could not execute Envoy binary."
   fi
   info "Envoy binary succesfully download."

   info "Testing envoy configuration."
   if ! $ENVOY_PATH --mode validate -c $ENVOY_CONFIGURATION_FILE 2>&1; then
      error "Could not start Envoy with the default configuration."
   fi

   info "Envoy is correctly configured."
   return 0
}

start_envoy () {
   echo -n "$ENVOY_SERVICE" | base64 --decode >$ENVOY_SERVICE_FILE

   if ! test -s $ENVOY_SERVICE_FILE; then
      error "Service file $ENVOY_SERVICE_FILE was not correctly written."
   fi
   info "Service file $ENVOY_SERVICE_FILE successfully written."

   info "Reloading the systemd service."
   if ! systemctl daemon-reload; then
      error "Sytemd could not read the envoy service file."
   fi
   if ! systemctl enable envoy 2>&1; then
      error "Systemd could not enable the envoy service at boot."
   fi
   info "Envoy service was succesfully loaded into systemd."

   info "Starting envoy."
   if ! systemctl start envoy; then
      error "Envoy failed to start as a service."
   fi
   if ! systemctl is-active envoy > /dev/null; then
      error "Envoy service is not active."
   fi
   info "Envoy started."

   sleep 10

   info "Testing if Envoy HTTP proxy service is responding."
   if [ "$(curl -k -s -o /dev/null -w '%{http_code}' 'https://127.0.0.1:443/')" != "200" ]; then
      error "Envoy HTTP proxy service is not responding."
   fi
   info "Envoy HTTP proxy service is correctly responding."
   return 0
}

install_nginx () {
   info "Installing Nginx default backend."
   apt-get update -qq --no-show-upgraded 1>/dev/null
   get nginx

   if ! systemctl is-active nginx > /dev/null; then
      error "Nginx service is not active."
   fi
   info "Nginx service is active."

   if [ "$(curl -s -o /dev/null -w '%{http_code}' 'http://127.0.0.1:80/')" != "200" ]; then
      error "Nginx HTTP service is not responding."
   fi
   return 0
}

post_install () {
   # Disable APT sources
   info "Removing APT packages cache and lists."
   apt-get autoremove -qq -y >/dev/null
   apt-get clean -qq >/dev/null
   rm -rf /etc/apt/sources.list /etc/apt/sources.list.d/

   # Disable APT auto updates
   info "Loading APT configuration to halt auto-update."
   echo -ne "APT::Periodic::Update-Package-Lists \"0\";\nAPT::Periodic::Unattended-Upgrade \"0\";" > /etc/apt/apt.conf.d/20auto-upgrades
   if ! test -s /etc/apt/apt.conf.d/20auto-upgrades; then
      error "Configuration file /etc/apt/apt.conf.d/20auto-upgrades was not correctly written."
   fi
   info "APT auto-update succesfully disabled."
   return 0
}

main () {
   envoy_config

   ssl_config

   install_envoy

   install_nginx

   start_envoy

   post_install

   return 0
} 

# Set default umask for files created
umask 0022
# Main function
main

echo "********** Build was succesful. **********"
exit 0